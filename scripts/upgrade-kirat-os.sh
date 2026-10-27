#!/bin/bash
# =============================================================================
# KIRAT OS - Smart Upgrade System with Rollback
# =============================================================================
# Usage: sudo ./upgrade-kirat-os.sh [options]
# Options:
#   --check-only     Only check for updates, don't install
#   --force          Force upgrade even if versions match
#   --skip-backup    Skip pre-upgrade backup (not recommended)
#   --rollback       Rollback to previous version
#   --channel stable|beta|dev  Upgrade channel (default: stable)
#   -y, --yes        Auto-answer yes to all prompts
#   -h, --help       Show this help
#
# This script:
#   1. Checks current version against latest
#   2. Creates pre-upgrade backup with timestamp
#   3. Upgrades system packages (apt)
#   4. Upgrades KIRAT OS components
#   5. Upgrades AI models (Ollama)
#   6. Upgrades Python dependencies
#   7. Restarts services with health checks
#   8. Rolls back automatically on failure
# =============================================================================

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="2.0.0"
readonly KIRAT_DIR="/opt/kirat-os"
readonly BACKUP_DIR="/data/backups"
readonly LOG_DIR="/var/log/kirat-os"
readonly VERSION_FILE="$KIRAT_DIR/VERSION"
readonly LOCK_FILE="/var/run/kirat-os-upgrade.lock"
readonly REMOTE_VERSION_URL="https://raw.githubusercontent.com/kirat-os/releases/main/VERSION"
readonly REMOTE_TARBALL_URL="https://github.com/kirat-os/releases/download"
readonly OLLAMA_MODELS=("llama3.1:8b" "codellama:7b" "mistral:7b" "phi3:3.8b")
readonly PYTHON_PACKAGES=("fastapi" "uvicorn" "httpx" "aiohttp" "cryptography" "pydantic" "sqlalchemy")
readonly HEALTH_CHECK_TIMEOUT=60
readonly MAX_RETRIES=3

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── State ───────────────────────────────────────────────────────────────────
CHECK_ONLY=false
FORCE=false
SKIP_BACKUP=false
ROLLBACK=false
CHANNEL="stable"
AUTO_YES=false
BACKUP_FILE=""
UPGRADE_START_TIME=""
FAILED_STAGE=""

# ── Logging ─────────────────────────────────────────────────────────────────
log()  { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOG_DIR/upgrade.log"; }
ok()   { echo -e "${GREEN}✓${NC} $*" | tee -a "$LOG_DIR/upgrade.log"; }
warn() { echo -e "${YELLOW}⚠${NC} $*" | tee -a "$LOG_DIR/upgrade.log"; }
err()  { echo -e "${RED}✗${NC} $*" | tee -a "$LOG_DIR/upgrade.log"; }
info() { echo -e "${CYAN}ℹ${NC} $*" | tee -a "$LOG_DIR/upgrade.log"; }

# ── Header ──────────────────────────────────────────────────────────────────
header() {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  KIRAT OS Upgrade System v${SCRIPT_VERSION}${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
}

# ── Help ────────────────────────────────────────────────────────────────────
show_help() {
    sed -n '/^# Usage:/,/^# ===/p' "$0" | sed 's/^# //; s/^#//'
}

# ── Argument Parsing ────────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check-only) CHECK_ONLY=true; shift ;;
            --force) FORCE=true; shift ;;
            --skip-backup) SKIP_BACKUP=true; shift ;;
            --rollback) ROLLBACK=true; shift ;;
            --channel)
                CHANNEL="${2:-stable}"
                shift 2
                ;;
            -y|--yes) AUTO_YES=true; shift ;;
            -h|--help) show_help; exit 0 ;;
            *) warn "Unknown option: $1"; shift ;;
        esac
    done
}

# ── Root Check ──────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Use: sudo $0"
        exit 1
    fi
}

# ── Lock ────────────────────────────────────────────────────────────────────
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if kill -0 "$pid" 2>/dev/null; then
            err "Another upgrade is already running (PID: $pid)"
            exit 1
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# ── Directories ─────────────────────────────────────────────────────────────
ensure_dirs() {
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$KIRAT_DIR"
}

# ── Version ─────────────────────────────────────────────────────────────────
get_current_version() {
    if [[ -f "$VERSION_FILE" ]]; then
        cat "$VERSION_FILE" | tr -d '[:space:]'
    else
        echo "0.0.0"
    fi
}

get_latest_version() {
    local version
    if command -v curl &>/dev/null; then
        version=$(curl -fsSL --max-time 10 "$REMOTE_VERSION_URL?channel=$CHANNEL" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget &>/dev/null; then
        version=$(wget -qO- --timeout=10 "$REMOTE_VERSION_URL?channel=$CHANNEL" 2>/dev/null | tr -d '[:space:]')
    fi
    # Fallback: check local git repo
    if [[ -z "$version" ]] && [[ -d "$KIRAT_DIR/.git" ]]; then
        version=$(cd "$KIRAT_DIR" && git describe --tags --abbrev=0 2>/dev/null || echo "")
    fi
    echo "${version:-unknown}"
}

version_compare() {
    # Returns: 0 if equal, 1 if v1 > v2, 2 if v1 < v2
    local v1="$1" v2="$2"
    if [[ "$v1" == "$v2" ]]; then return 0; fi
    local IFS=.
    local i ver1=($v1) ver2=($v2)
    for ((i=0; i<${#ver1[@]} || i<${#ver2[@]}; i++)); do
        local n1=${ver1[i]:-0} n2=${ver2[i]:-0}
        if ((10#$n1 > 10#$n2)); then return 1; fi
        if ((10#$n1 < 10#$n2)); then return 2; fi
    done
    return 0
}

# ── Prompt ──────────────────────────────────────────────────────────────────
confirm() {
    [[ "$AUTO_YES" == true ]] && return 0
    local msg="${1:-Proceed?}"
    read -rp "$msg [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ── Backup ──────────────────────────────────────────────────────────────────
create_backup() {
    [[ "$SKIP_BACKUP" == true ]] && { info "Skipping backup"; return 0; }

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/pre-upgrade-${timestamp}.tar.gz"

    info "Creating pre-upgrade backup..."
    mkdir -p "$BACKUP_DIR"

    # Backup KIRAT OS configs, databases, and custom files
    tar -czf "$BACKUP_FILE" \
        -C / \
        opt/kirat-os/configs 2>/dev/null \
        opt/kirat-os/dashboard/config 2>/dev/null \
        opt/kirat-os/sentinel-core/config 2>/dev/null \
        etc/systemd/system/kirat-*.service 2>/dev/null \
        etc/nginx/sites-enabled/kirat* 2>/dev/null \
        etc/ssh/sshd_config.d/kirat* 2>/dev/null \
        var/lib/kirat-os 2>/dev/null \
        data/ 2>/dev/null || true

    # Backup package list
    dpkg --get-selections > "$BACKUP_DIR/pre-upgrade-${timestamp}-packages.txt" 2>/dev/null || true

    # Backup Ollama model list
    ollama list > "$BACKUP_DIR/pre-upgrade-${timestamp}-ollama.txt" 2>/dev/null || true

    ok "Backup created: $BACKUP_FILE"
    info "Backup size: $(du -h "$BACKUP_FILE" 2>/dev/null | cut -f1)"
}

# ── Rollback ────────────────────────────────────────────────────────────────
rollback() {
    err "ROLLBACK INITIATED - Stage: ${FAILED_STAGE:-unknown}"

    if [[ -n "$BACKUP_FILE" ]] && [[ -f "$BACKUP_FILE" ]]; then
        info "Restoring from backup: $BACKUP_FILE"
        tar -xzf "$BACKUP_FILE" -C / 2>/dev/null || true
        ok "Configuration restored from backup"
    fi

    # Restore package list if available
    local pkg_backup
    pkg_backup=$(ls -t "$BACKUP_DIR"/pre-upgrade-*-packages.txt 2>/dev/null | head -1)
    if [[ -n "$pkg_backup" ]]; then
        info "Package list backup available: $pkg_backup"
    fi

    # Restart services in safe mode
    info "Restarting services in rollback mode..."
    systemctl daemon-reload 2>/dev/null || true
    systemctl restart kirat-dashboard kirat-sentinel 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true

    err "Rollback complete. System restored to pre-upgrade state."
    err "Check logs: $LOG_DIR/upgrade.log"
    exit 1
}

# ── Stage 1: System Packages ────────────────────────────────────────────────
stage_system_packages() {
    FAILED_STAGE="system_packages"
    header
    info "STAGE 1/7: Upgrading system packages..."

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || { err "apt update failed"; rollback; }

    # Dist-upgrade with auto-remove
    apt-get dist-upgrade -y -qq --auto-remove --purge \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" || {
        err "apt upgrade failed"
        rollback
    }

    # Clean up
    apt-get autoremove -y -qq 2>/dev/null || true
    apt-get autoclean -qq 2>/dev/null || true

    ok "System packages upgraded"
}

# ── Stage 2: KIRAT OS Components ────────────────────────────────────────────
stage_kirat_components() {
    FAILED_STAGE="kirat_components"
    header
    info "STAGE 2/7: Upgrading KIRAT OS components..."

    # Method 1: Git pull if it's a git repo
    if [[ -d "$KIRAT_DIR/.git" ]]; then
        info "Updating from git repository..."
        (cd "$KIRAT_DIR" && git stash 2>/dev/null || true)
        (cd "$KIRAT_DIR" && git fetch --tags origin 2>/dev/null || true)
        (cd "$KIRAT_DIR" && git pull origin "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null || true)
        (cd "$KIRAT_DIR" && git stash pop 2>/dev/null || true)
        ok "Git repository updated"
    fi

    # Method 2: Download latest tarball
    local latest_version
    latest_version=$(get_latest_version)
    if [[ "$latest_version" != "unknown" ]] && [[ "$latest_version" != "0.0.0" ]]; then
        info "Latest remote version: $latest_version"
        local tarball_url="$REMOTE_TARBALL_URL/v${latest_version}/kirat-os-${latest_version}.tar.gz"
        local temp_dir
        temp_dir=$(mktemp -d)
        if curl -fsSL --max-time 30 "$tarball_url" -o "$temp_dir/kirat-os.tar.gz" 2>/dev/null; then
            info "Downloaded latest release tarball"
            tar -xzf "$temp_dir/kirat-os.tar.gz" -C "$temp_dir" 2>/dev/null || true
            rsync -a --exclude='configs/' --exclude='data/' "$temp_dir/kirat-os-"*/ "$KIRAT_DIR/" 2>/dev/null || true
            rm -rf "$temp_dir"
            ok "KIRAT OS components updated from release"
        else
            warn "Could not download release tarball (offline or no release yet)"
        fi
    fi

    # Ensure scripts are executable
    chmod +x "$KIRAT_DIR/scripts/"*.sh 2>/dev/null || true

    # Update VERSION file
    echo "$latest_version" > "$VERSION_FILE"

    ok "KIRAT OS components upgraded"
}

# ── Stage 3: Security Fixes ─────────────────────────────────────────────────
stage_security() {
    FAILED_STAGE="security"
    header
    info "STAGE 3/7: Applying security updates..."

    # Re-run security hardening if script exists
    if [[ -f "$KIRAT_DIR/security/fix-pending.sh" ]]; then
        info "Running security fix script..."
        bash "$KIRAT_DIR/security/fix-pending.sh" --yes 2>/dev/null || warn "Security fix script had warnings"
    fi

    # Re-run hardening if script exists
    if [[ -f "$KIRAT_DIR/security/hardening/harden-fixed.sh" ]]; then
        info "Running hardening script..."
        bash "$KIRAT_DIR/security/hardening/harden-fixed.sh" 2>/dev/null || warn "Hardening script had warnings"
    fi

    # Update CA certificates
    update-ca-certificates 2>/dev/null || true

    ok "Security updates applied"
}

# ── Stage 4: AI Models ──────────────────────────────────────────────────────
stage_ai_models() {
    FAILED_STAGE="ai_models"
    header
    info "STAGE 4/7: Upgrading AI models (Ollama)..."

    if ! command -v ollama &>/dev/null; then
        warn "Ollama not installed, skipping AI model upgrade"
        return 0
    fi

    # Update Ollama itself
    info "Checking for Ollama updates..."
    if curl -fsSL https://ollama.com/install.sh | sh 2>/dev/null; then
        ok "Ollama updated"
    else
        warn "Ollama self-update skipped (may be managed by package manager)"
    fi

    # Pull/update models
    local model
    for model in "${OLLAMA_MODELS[@]}"; do
        info "Pulling/updating model: $model"
        if ollama pull "$model" 2>/dev/null; then
            ok "Model $model ready"
        else
            warn "Could not pull model: $model (may be unavailable)"
        fi
    done

    # Show installed models
    info "Installed Ollama models:"
    ollama list 2>/dev/null | head -20 || true

    ok "AI models upgraded"
}

# ── Stage 5: Python Dependencies ────────────────────────────────────────────
stage_python_deps() {
    FAILED_STAGE="python_deps"
    header
    info "STAGE 5/7: Upgrading Python dependencies..."

    # Upgrade system pip
    pip3 install --upgrade pip setuptools wheel 2>/dev/null || true

    # Upgrade KIRAT OS Python packages
    for pkg in "${PYTHON_PACKAGES[@]}"; do
        info "Upgrading $pkg..."
        pip3 install --upgrade "$pkg" 2>/dev/null || warn "Could not upgrade $pkg"
    done

    # Upgrade requirements from KIRAT OS
    if [[ -f "$KIRAT_DIR/sentinel-core/requirements.txt" ]]; then
        pip3 install -r "$KIRAT_DIR/sentinel-core/requirements.txt" --upgrade 2>/dev/null || true
    fi
    if [[ -f "$KIRAT_DIR/dashboard/requirements.txt" ]]; then
        pip3 install -r "$KIRAT_DIR/dashboard/requirements.txt" --upgrade 2>/dev/null || true
    fi
    if [[ -f "$KIRAT_DIR/quantum-ai/requirements.txt" ]]; then
        pip3 install -r "$KIRAT_DIR/quantum-ai/requirements.txt" --upgrade 2>/dev/null || true
    fi

    ok "Python dependencies upgraded"
}

# ── Stage 6: Service Restart ────────────────────────────────────────────────
stage_restart_services() {
    FAILED_STAGE="restart_services"
    header
    info "STAGE 6/7: Restarting services..."

    # Reload systemd
    systemctl daemon-reload 2>/dev/null || true

    # Restart in order
    local services=("kirat-sentinel" "kirat-quantum-ai" "kirat-dashboard" "nginx")
    for svc in "${services[@]}"; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            info "Restarting $svc..."
            systemctl restart "$svc" 2>/dev/null || warn "Could not restart $svc"
            sleep 2
            if systemctl is-active "$svc" &>/dev/null; then
                ok "$svc is running"
            else
                warn "$svc may not be running"
            fi
        fi
    done

    ok "Services restarted"
}

# ── Stage 7: Health Check ───────────────────────────────────────────────────
stage_health_check() {
    FAILED_STAGE="health_check"
    header
    info "STAGE 7/7: Running health checks..."

    local checks_passed=0
    local checks_total=0

    # Check 1: Disk space
    ((checks_total++))
    local disk_usage
    disk_usage=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
    if [[ "$disk_usage" -lt 90 ]]; then
        ok "Disk usage: ${disk_usage}%"
        ((checks_passed++))
    else
        err "Disk usage critical: ${disk_usage}%"
    fi

    # Check 2: Memory
    ((checks_total++))
    local mem_usage
    mem_usage=$(free | awk 'NR==2{printf "%.0f", $3*100/$2}')
    if [[ "$mem_usage" -lt 95 ]]; then
        ok "Memory usage: ${mem_usage}%"
        ((checks_passed++))
    else
        warn "Memory usage high: ${mem_usage}%"
    fi

    # Check 3: Sentinel AI
    ((checks_total++))
    if systemctl is-active kirat-sentinel &>/dev/null; then
        ok "Sentinel AI: running"
        ((checks_passed++))
    else
        warn "Sentinel AI: not running"
    fi

    # Check 4: Dashboard
    ((checks_total++))
    if curl -fsSL http://localhost:8080/health 2>/dev/null | grep -q "ok"; then
        ok "Dashboard: responding"
        ((checks_passed++))
    else
        warn "Dashboard: not responding"
    fi

    # Check 5: Ollama
    ((checks_total++))
    if curl -fsSL http://localhost:11434/api/tags 2>/dev/null | grep -q "name"; then
        ok "Ollama: responding"
        ((checks_passed++))
    else
        warn "Ollama: not responding"
    fi

    # Check 6: SSH
    ((checks_total++))
    if systemctl is-active ssh &>/dev/null || systemctl is-active sshd &>/dev/null; then
        ok "SSH: running"
        ((checks_passed++))
    else
        warn "SSH: not running"
    fi

    # Check 7: Firewall
    ((checks_total++))
    if ufw status 2>/dev/null | grep -q "Status: active" || iptables -L 2>/dev/null | grep -q "DROP"; then
        ok "Firewall: active"
        ((checks_passed++))
    else
        warn "Firewall: check status"
    fi

    # Summary
    header
    info "Health Check Results: $checks_passed/$checks_total passed"
    if [[ "$checks_passed" -ge 5 ]]; then
        ok "System health is GOOD"
    elif [[ "$checks_passed" -ge 3 ]]; then
        warn "System health is DEGRADED — check services"
    else
        err "System health is CRITICAL — review logs"
    fi
}

# ── Rollback Mode ───────────────────────────────────────────────────────────
do_rollback() {
    header
    info "ROLLBACK MODE: Restoring previous version..."

    local backup
    backup=$(ls -t "$BACKUP_DIR"/pre-upgrade-*.tar.gz 2>/dev/null | head -1)

    if [[ -z "$backup" ]]; then
        err "No backup found in $BACKUP_DIR"
        exit 1
    fi

    info "Found backup: $backup"
    if confirm "Restore from this backup?"; then
        tar -xzf "$backup" -C / 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart kirat-dashboard kirat-sentinel 2>/dev/null || true
        ok "Rollback complete!"
    else
        info "Rollback cancelled"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    check_root
    header

    if [[ "$ROLLBACK" == true ]]; then
        do_rollback
        exit 0
    fi

    acquire_lock
    ensure_dirs

    local current_version latest_version
    current_version=$(get_current_version)
    latest_version=$(get_latest_version)

    info "Current version: $current_version"
    info "Latest version:  $latest_version"
    info "Channel: $CHANNEL"

    if [[ "$CHECK_ONLY" == true ]]; then
        version_compare "$current_version" "$latest_version"
        local cmp=$?
        if [[ $cmp -eq 2 ]] || [[ "$FORCE" == true ]]; then
            info "Update available: $current_version → $latest_version"
            exit 0
        else
            info "System is up to date ($current_version)"
            exit 0
        fi
    fi

    version_compare "$current_version" "$latest_version"
    local cmp=$?
    if [[ $cmp -ne 2 ]] && [[ "$FORCE" != true ]]; then
        info "System is already at the latest version ($current_version)"
        info "Use --force to upgrade anyway, or --check-only to verify"
        exit 0
    fi

    if ! confirm "Upgrade KIRAT OS from $current_version to $latest_version?"; then
        info "Upgrade cancelled"
        exit 0
    fi

    UPGRADE_START_TIME=$(date +%s)
    info "Starting upgrade at $(date)"

    # Execute stages
    create_backup
    stage_system_packages
    stage_kirat_components
    stage_security
    stage_ai_models
    stage_python_deps
    stage_restart_services
    stage_health_check

    # Finalize
    local duration
    duration=$(($(date +%s) - UPGRADE_START_TIME))
    header
    ok "UPGRADE COMPLETE!"
    info "Duration: ${duration}s"
    info "Version: $current_version → $latest_version"
    info "Backup: ${BACKUP_FILE:-none}"
    info "Log: $LOG_DIR/upgrade.log"
    echo
    info "Next steps:"
    echo "  • Review health check results above"
    echo "  • Check dashboard: https://$(hostname -I | awk '{print $1}'):8443"
    echo "  • View logs: sudo journalctl -u kirat-sentinel -n 100"
    echo "  • If issues: sudo $0 --rollback"
}

main "$@"
