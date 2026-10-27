#!/bin/bash
# KIRAT OS — exact-allowlist executor for canonical Ed25519 envelopes.
set -euo pipefail
umask 077

ALLOWED_CMDS=(
    "systemctl status nginx"
    "systemctl status ssh"
    "systemctl status postgresql"
    "systemctl status docker"
    "systemctl status fail2ban"
    "systemctl status apparmor"
    "systemctl restart nginx"
    "systemctl reload nginx"
    "systemctl restart ssh"
    "nginx -t"
    "docker ps"
    "docker images"
    "docker logs"
    "docker inspect"
    "docker network ls"
    "docker volume ls"
    "docker stats --no-stream"
    "tail -n 100 /var/log/nginx/error.log"
    "tail -n 100 /var/log/auth.log"
    "cat /var/log/nginx/error.log"
    "cat /var/log/auth.log"
    "journalctl -xe"
    "journalctl -u nginx"
    "journalctl -u ssh"
    "journalctl -u fail2ban"
    "df -h"
    "du -sh"
    "free -h"
    "uptime"
    "netstat -tulpn"
    "ss -tulpn"
    "kirat-admin instruction list"
    "apparmor_status"
    "aa-status"
    "ufw status verbose"
    "fail2ban-client status"
)

RBAC_DIR="${KIRAT_RBAC_DIR:-/opt/kirat-os/security/rbac}"
EXPECTED_TARGET="${KIRAT_EXECUTOR_TARGET:-}"
ALLOWED_TARGETS=(
    "kirat-ai-executor" "jitedasti-ai" "galinja-ai" "oysgja-ai"
    "suyarma-ai" "papa-ai" "aadhipati-ai"
)
EXPECTED_ISSUER="${KIRAT_EXECUTOR_ISSUER:-kirat-admin}"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SIGNER="$SCRIPT_DIR/ed25519-sign.py"
LOG_DIR="$RBAC_DIR/logs"
ID_DIR="$RBAC_DIR/executed-ids"
WORK_DIR=""
INSTRUCTION_ID="unknown"
ISSUER="unknown"
TARGET="unknown"
CMD=""

cleanup() {
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

audit() {
    local status="$1"
    python3 - "$LOG_DIR/executor-audit.jsonl" "$status" "$INSTRUCTION_ID" \
        "$ISSUER" "$TARGET" "$CMD" <<'PY'
import datetime, json, os, sys
path, status, instruction_id, issuer, target, command = sys.argv[1:]
entry = {"timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
         "instruction_id": instruction_id, "issuer": issuer, "target": target,
         "command": command, "status": status}
with open(path, "a", encoding="utf-8") as stream:
    stream.write(json.dumps(entry, sort_keys=True) + "\n")
os.chmod(path, 0o600)
PY
}

reject() {
    local message="$1" status="${2:-REJECTED}"
    printf 'ERROR: %s\n' "$message" >&2
    audit "$status"
    exit 1
}

json_field() {
    python3 - "$SNAPSHOT" "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    instruction = json.load(stream)
value = instruction[sys.argv[2]]
if not isinstance(value, str):
    raise SystemExit("field is not a string")
sys.stdout.write(value)
PY
}

[[ $# -eq 1 ]] || { echo "Usage: executor-run.sh <instruction.json>" >&2; exit 1; }
INSTRUCTION_FILE="$1"
[[ -f "$INSTRUCTION_FILE" && -f "$SIGNER" ]] || {
    echo "ERROR: Instruction or canonical verifier not found" >&2; exit 1; }

mkdir -p -- "$LOG_DIR" "$ID_DIR"
chmod 700 "$RBAC_DIR" "$LOG_DIR" "$ID_DIR"
WORK_DIR=$(mktemp -d "$RBAC_DIR/.executor.XXXXXXXX")
SNAPSHOT="$WORK_DIR/instruction.json"
# Verify and execute one immutable private snapshot, not a mutable queue file.
cp -- "$INSTRUCTION_FILE" "$SNAPSHOT"
chmod 600 "$SNAPSHOT"

if ! python3 "$SIGNER" verify "$SNAPSHOT"; then
    reject "Canonical Ed25519, envelope, or freshness verification failed" "SIGNATURE_REJECTED"
fi
INSTRUCTION_ID=$(json_field instruction_id)
ISSUER=$(json_field issuer)
TARGET=$(json_field target)
CMD=$(json_field command)

[[ "$ISSUER" == "$EXPECTED_ISSUER" ]] || reject "Unexpected issuer" "ISSUER_REJECTED"
if [[ -n "$EXPECTED_TARGET" ]]; then
    [[ "$TARGET" == "$EXPECTED_TARGET" ]] || reject "Unexpected target" "TARGET_REJECTED"
else
    TARGET_ALLOWED=0
    for allowed_target in "${ALLOWED_TARGETS[@]}"; do
        [[ "$TARGET" == "$allowed_target" ]] && TARGET_ALLOWED=1 && break
    done
    [[ "$TARGET_ALLOWED" -eq 1 ]] || reject "Unexpected target" "TARGET_REJECTED"
fi

ALLOWED=0
for allowed in "${ALLOWED_CMDS[@]}"; do
    if [[ "$CMD" == "$allowed" ]]; then
        ALLOWED=1
        break
    fi
done
[[ "$ALLOWED" -eq 1 ]] || reject "Command not in exact allowlist: $CMD" "WHITELIST_REJECTED"

# mkdir is the atomic compare-and-claim operation. A crash after this point
# fails closed: the same signed instruction can never be executed twice.
if ! mkdir -- "$ID_DIR/$INSTRUCTION_ID" 2>/dev/null; then
    reject "Duplicate instruction ID: $INSTRUCTION_ID" "REPLAY_REJECTED"
fi
chmod 700 "$ID_DIR/$INSTRUCTION_ID"
printf 'target=%s\nissuer=%s\ncommand=%s\n' "$TARGET" "$ISSUER" "$CMD" \
    > "$ID_DIR/$INSTRUCTION_ID/claim"
chmod 600 "$ID_DIR/$INSTRUCTION_ID/claim"

audit "ATTEMPTED"
read -r -a CMD_ARGS <<< "$CMD"
if "${CMD_ARGS[@]}"; then
    audit "EXECUTED"
else
    status=$?
    audit "COMMAND_FAILED"
    exit "$status"
fi
