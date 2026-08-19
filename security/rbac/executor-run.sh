#!/bin/bash
# KIRAT OS — AI Agent Command Executor (Whitelisted + Ed25519 Verified)
# Called by: executor-ai via sudo from orchestrator-ai validated instructions
# Requires: Ed25519 signature verification BEFORE execution

set -euo pipefail

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

INSTRUCTION_FILE="$1"
if [ ! -f "$INSTRUCTION_FILE" ]; then
    echo "ERROR: Instruction file not found" >&2
    exit 1
fi

# Validate JSON structure
if ! python3 -c "import json; json.load(open('$INSTRUCTION_FILE'))" 2>/dev/null; then
    echo "ERROR: Invalid JSON instruction" >&2
    exit 1
fi

CMD=$(python3 -c "import json; print(json.load(open('$INSTRUCTION_FILE')).get('command',''))")
AGENT=$(python3 -c "import json; print(json.load(open('$INSTRUCTION_FILE')).get('agent',''))")
SIG_B64=$(python3 -c "import json; print(json.load(open('$INSTRUCTION_FILE')).get('admin_signature',''))")
SIG_ALG=$(python3 -c "import json; print(json.load(open('$INSTRUCTION_FILE')).get('signature_alg',''))")

# Verify admin Ed25519 signature
if [ -z "$SIG_B64" ] || [ -z "$SIG_ALG" ]; then
    echo "ERROR: Missing admin signature or algorithm" >&2
    exit 1
fi

if [ "$SIG_ALG" != "Ed25519" ]; then
    echo "ERROR: Unsupported signature algorithm: $SIG_ALG (required: Ed25519)" >&2
    exit 1
fi

PUB_KEY_PATH="/opt/kirat-os/security/rbac/admin-ed25519.pub"
if [ ! -f "$PUB_KEY_PATH" ]; then
    echo "ERROR: Ed25519 public key not found: $PUB_KEY_PATH" >&2
    exit 1
fi

# Verify using Python (PyNaCl)
VERIFY_RESULT=$(python3 << PYEOF
import json, base64, sys
try:
    import nacl.signing
except ImportError:
    print("PYNACL_MISSING")
    sys.exit(0)

with open("$INSTRUCTION_FILE", "r") as f:
    instruction = json.load(f)

sig_b64 = instruction.pop("admin_signature", None)
instruction.pop("signature_alg", None)
instruction.pop("signed_at", None)

if not sig_b64:
    print("NO_SIG")
    sys.exit(0)

with open("$PUB_KEY_PATH", "rb") as f:
    verify_key = nacl.signing.VerifyKey(f.read())

payload = json.dumps(instruction, sort_keys=True, separators=(",", ":")).encode("utf-8")
signature = base64.b64decode(sig_b64)

try:
    verify_key.verify(payload, signature)
    print("VALID")
except nacl.exceptions.BadSignatureError:
    print("INVALID")
PYEOF
)

if [ "$VERIFY_RESULT" = "PYNACL_MISSING" ]; then
    echo "ERROR: PyNaCl not installed. Cannot verify Ed25519 signature." >&2
    exit 1
fi

if [ "$VERIFY_RESULT" = "NO_SIG" ]; then
    echo "ERROR: No signature found in instruction" >&2
    exit 1
fi

if [ "$VERIFY_RESULT" != "VALID" ]; then
    echo "ERROR: Ed25519 signature verification FAILED" >&2
    # Log the failed attempt
    LOG_ENTRY="{\"timestamp\":\"$(date -Iseconds)\",\"agent\":\"$AGENT\",\"command\":\"$CMD\",\"status\":\"SIGNATURE_REJECTED\"}"
    echo "$LOG_ENTRY" >> /opt/kirat-os/security/rbac/logs/executor-audit.jsonl
    exit 1
fi

# Whitelist check — must match EXACTLY (no wildcards)
ALLOWED=0
for prefix in "${ALLOWED_CMDS[@]}"; do
    if [ "$CMD" = "$prefix" ]; then
        ALLOWED=1
        break
    fi
done

if [ "$ALLOWED" -ne 1 ]; then
    echo "ERROR: Command not in whitelist: $CMD" >&2
    LOG_ENTRY="{\"timestamp\":\"$(date -Iseconds)\",\"agent\":\"$AGENT\",\"command\":\"$CMD\",\"status\":\"WHITELIST_REJECTED\"}"
    echo "$LOG_ENTRY" >> /opt/kirat-os/security/rbac/logs/executor-audit.jsonl
    exit 1
fi

# Log to auditor
LOG_ENTRY="{\"timestamp\":\"$(date -Iseconds)\",\"agent\":\"$AGENT\",\"command\":\"$CMD\",\"signature_alg\":\"$SIG_ALG\",\"status\":\"EXECUTED\"}"
echo "$LOG_ENTRY" >> /opt/kirat-os/security/rbac/logs/executor-audit.jsonl

# Execute
$CMD
