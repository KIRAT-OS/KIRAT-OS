#!/bin/bash
###############################################################################
# KIRAT OS — encrypted disaster-recovery backups
###############################################################################
set -euo pipefail
umask 077

ACTION="backup"
BACKUP_DIR="${BACKUP_DIR:-/data/backups}"
REMOTE_TARGET="${REMOTE_TARGET:-}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
BACKUP_GPG_RECIPIENT="${BACKUP_GPG_RECIPIENT:-}"
BACKUP_FILE="${BACKUP_FILE:-}"
WORK_DIR=""

log_info()  { printf '\033[0;34m[DR]\033[0m    %s\n' "$1"; }
log_ok()    { printf '\033[0;32m[OK]\033[0m    %s\n' "$1"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; }
log_error() { printf '\033[0;31m[FAIL]\033[0m  %s\n' "$1" >&2; }
die() { log_error "$1"; exit 1; }

usage() {
    cat <<'EOF'
Usage: sudo bash backup-dr.sh --action <backup|verify|restore|dr-test>

Options:
  --backup-dir DIR    Local directory for encrypted artifacts
  --remote URL        Optional s3:// or rsync:// destination
  --retention N       Days to retain encrypted artifacts (default: 30)

BACKUP_GPG_RECIPIENT must identify an installed encryption-capable GPG key.
Only the encrypted .tar.gz.gpg artifact is retained or uploaded. Verification
requires the corresponding private key and performs an authenticated decrypt.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        [[ $# -ge 2 || "$1" == "--help" ]] || die "Missing value for $1"
        case "$1" in
            --action) ACTION="$2"; shift 2 ;;
            --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
            --remote) REMOTE_TARGET="$2"; shift 2 ;;
            --retention) RETENTION_DAYS="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) die "Unknown option: $1" ;;
        esac
    done
    [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] || die "Retention must be a non-negative integer"
    [[ -n "$BACKUP_DIR" && "$BACKUP_DIR" != "/" ]] || die "Unsafe backup directory"
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

prepare_dirs() {
    mkdir -p -- "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    WORK_DIR=$(mktemp -d "$BACKUP_DIR/.kirat-backup.XXXXXXXX")
    chmod 700 "$WORK_DIR"
}

require_encryption_key() {
    [[ -n "$BACKUP_GPG_RECIPIENT" ]] || \
        die "BACKUP_GPG_RECIPIENT is required; plaintext backups are disabled"
    command -v gpg >/dev/null 2>&1 || die "gpg is required"
    gpg --batch --list-keys "$BACKUP_GPG_RECIPIENT" >/dev/null 2>&1 || \
        die "No usable GPG public key for BACKUP_GPG_RECIPIENT"
}

validate_archive() {
    local archive="$1"
    [[ -s "$archive" ]] || die "Backup archive is empty"
    gzip -t "$archive" || die "Backup gzip validation failed"
    tar -tzf "$archive" >/dev/null 2>&1 || die "Backup tar validation failed"

    local listing="$WORK_DIR/archive-list.txt"
    tar -tzf "$archive" > "$listing"
    grep -q '^MANIFEST.json$' "$listing" || die "Backup manifest is missing"
    if grep -E '(^/|(^|/)\.\.(/|$))' "$listing" >/dev/null; then
        die "Unsafe path in backup archive"
    fi
    if grep -Ei '(^|/)(\.admin-ed25519-secret|id_(rsa|ed25519)(\.pub)?|ssh_host_.*|MOK\.(priv|key)|\.env(\..*)?|[^/]*(backup|signing)[^/]*(secret|pass|key)[^/]*)$|\.(priv|key)$' "$listing" >/dev/null; then
        die "Private key or backup secret detected in archive"
    fi
}

latest_artifact() {
    if [[ -n "$BACKUP_FILE" ]]; then
        [[ -f "$BACKUP_FILE" ]] || die "Backup not found: $BACKUP_FILE"
        printf '%s\n' "$BACKUP_FILE"
        return
    fi
    local latest
    latest=$(find "$BACKUP_DIR" -maxdepth 1 -type f \
        -name 'kirat-backup-*.tar.gz.gpg' -printf '%T@ %p\n' | \
        sort -nr | head -n 1 | cut -d' ' -f2-)
    [[ -n "$latest" ]] || die "No encrypted backups found in $BACKUP_DIR"
    printf '%s\n' "$latest"
}

decrypt_artifact() {
    local artifact="$1"
    local archive="$WORK_DIR/plaintext.tar.gz"
    # GPG verifies the encrypted message's integrity/MDC before returning data.
    # A listing-only check is deliberately not accepted as DR verification.
    gpg --batch --yes --output "$archive" --decrypt "$artifact" >/dev/null 2>&1 || \
        die "Authenticated decryption failed (private key required or artifact corrupt)"
    validate_archive "$archive"
    printf '%s\n' "$archive"
}

action_backup() {
    require_encryption_key
    prepare_dirs
    local timestamp payload archive artifact
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    payload="$WORK_DIR/payload"
    archive="$WORK_DIR/kirat-backup-${timestamp}.tar.gz"
    artifact="$BACKUP_DIR/kirat-backup-${timestamp}.tar.gz.gpg"
    mkdir -p "$payload/database"
    chmod 700 "$payload" "$payload/database"

    local sources=()
    local source
    for source in /etc/ssh /etc/nginx /etc/postgresql /etc/fail2ban /etc/ufw \
        /opt/kirat-os/security /data/business /data/www \
        /opt/kirat-os/ai-agents /var/lib/kirat-os; do
        if [[ -e "$source" ]]; then
            sources+=("${source#/}")
        else
            log_warn "Optional source absent: $source"
        fi
    done

    if command -v pg_dumpall >/dev/null 2>&1; then
        if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
            log_info "Dumping PostgreSQL (failure is fatal)..."
            runuser -u postgres -- pg_dumpall > "$payload/database/postgresql-all.sql"
            chmod 600 "$payload/database/postgresql-all.sql"
        elif pg_isready -q 2>/dev/null; then
            log_info "Dumping PostgreSQL as current user (non-root)..."
            pg_dumpall > "$payload/database/postgresql-all.sql"
            chmod 600 "$payload/database/postgresql-all.sql"
        else
            log_warn "PostgreSQL not reachable as non-root; no dump included"
        fi
    else
        log_warn "pg_dumpall unavailable; no PostgreSQL dump included"
    fi
    if [[ -f /var/lib/redis/dump.rdb ]]; then
        cp -- /var/lib/redis/dump.rdb "$payload/database/redis-dump.rdb"
        chmod 600 "$payload/database/redis-dump.rdb"
    fi

    python3 - "$payload/MANIFEST.json" "$timestamp" "${sources[@]}" <<'PY'
import json, socket, sys
path, timestamp, *sources = sys.argv[1:]
with open(path, "w", encoding="utf-8") as stream:
    json.dump({"format": 1, "timestamp": timestamp,
               "hostname": socket.gethostname(), "sources": sources},
              stream, sort_keys=True, indent=2)
    stream.write("\n")
PY
    chmod 600 "$payload/MANIFEST.json"

    log_info "Creating one validated archive with secret exclusions..."
    local -a tar_read_flags=()
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        log_warn "Non-root run: unreadable root-owned files will be skipped"
        tar_read_flags+=(--ignore-failed-read)
    fi
    local -a tar_cmd=(
        tar -czf "$archive" "${tar_read_flags[@]}"
        --exclude='etc/ssh/ssh_host_*'
        --exclude='*/id_rsa*' --exclude='*/id_ed25519*'
        --exclude='*.priv' --exclude='*.key' --exclude='*.pem'
        --exclude='*/.admin-ed25519-secret'
        --exclude='*/MOK.priv' --exclude='*/MOK.key'
        --exclude='*/.env' --exclude='*/.env.*'
        --exclude='*backup*secret*' --exclude='*backup*pass*'
        --exclude='*backup*key*' --exclude='*signing*secret*'
        --exclude='*signing*key*'
        -C "$payload" MANIFEST.json database
    )
    if [[ ${#sources[@]} -gt 0 ]]; then
        tar_cmd+=(-C / "${sources[@]}")
    fi
    "${tar_cmd[@]}"
    validate_archive "$archive"

    log_info "Encrypting backup with authenticated OpenPGP integrity protection..."
    gpg --batch --yes --trust-model always --force-mdc --cipher-algo AES256 \
        --recipient "$BACKUP_GPG_RECIPIENT" --encrypt \
        --output "$WORK_DIR/artifact.gpg" "$archive"
    [[ -s "$WORK_DIR/artifact.gpg" ]] || die "Encryption produced no artifact"
    chmod 600 "$WORK_DIR/artifact.gpg"
    mv -- "$WORK_DIR/artifact.gpg" "$artifact"
    chmod 600 "$artifact"

    if [[ -n "$REMOTE_TARGET" ]]; then
        log_info "Uploading only the encrypted artifact..."
        case "$REMOTE_TARGET" in
            s3://*) aws s3 cp "$artifact" "${REMOTE_TARGET%/}/" ;;
            rsync://*) rsync -a --chmod=F600 "$artifact" "${REMOTE_TARGET%/}/" ;;
            *) die "Unsupported remote protocol; refusing to upload" ;;
        esac
    fi

    log_info "Applying retention to encrypted KIRAT artifacts only..."
    find "$BACKUP_DIR" -maxdepth 1 -type f \
        -name 'kirat-backup-*.tar.gz.gpg' -mtime "+$RETENTION_DAYS" -delete
    log_ok "Encrypted backup complete: $artifact"
    log_warn "Creation validated the plaintext archive; run --action verify with the private key to prove recoverability."
}

action_verify() {
    prepare_dirs
    local artifact archive
    artifact=$(latest_artifact)
    log_info "Authenticated decrypt and archive validation: $artifact"
    archive=$(decrypt_artifact "$artifact")
    [[ -s "$archive" ]] || die "Decryption did not produce an archive"
    log_ok "Backup decryption and archive validation passed: $artifact"
}

copy_tree() {
    local source="$1" destination="$2"
    [[ -d "$source" ]] || return 0
    mkdir -p -- "$destination"
    cp -a -- "$source/." "$destination/"
}

action_restore() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Restore must run as root"
    prepare_dirs
    local artifact archive restored confirm
    artifact=$(latest_artifact)
    archive=$(decrypt_artifact "$artifact")
    restored="$WORK_DIR/restored"
    mkdir -p "$restored"
    tar -xzf "$archive" -C "$restored" --no-overwrite-dir

    log_warn "This will overwrite backed-up configuration and data from $artifact"
    read -r -p "Type RESTORE to confirm: " confirm
    [[ "$confirm" == "RESTORE" ]] || die "Restore aborted"

    local path
    for path in etc/ssh etc/nginx etc/postgresql etc/fail2ban etc/ufw \
        opt/kirat-os/security data/business data/www opt/kirat-os/ai-agents \
        var/lib/kirat-os; do
        copy_tree "$restored/$path" "/$path"
    done
    if [[ -s "$restored/database/postgresql-all.sql" ]]; then
        runuser -u postgres -- psql -f "$restored/database/postgresql-all.sql"
    fi
    if [[ -f "$restored/database/redis-dump.rdb" ]]; then
        install -o redis -g redis -m 660 "$restored/database/redis-dump.rdb" /var/lib/redis/dump.rdb
        systemctl restart redis-server
    fi
    log_ok "Restore completed without ignored errors from: $artifact"
}

action_dr_test() {
    action_verify
    log_warn "Only backup decryption/archive checks passed. No failover VM was booted; full DR recoverability is NOT proven."
}

main() {
    parse_args "$@"
    case "$ACTION" in
        backup) action_backup ;;
        verify) action_verify ;;
        restore) action_restore ;;
        dr-test) action_dr_test ;;
        *) die "Unknown action: $ACTION" ;;
    esac
}

main "$@"
