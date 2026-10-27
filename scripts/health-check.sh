#!/bin/bash
###############################################################################
# KIRAT OS — System Health Check
###############################################################################
# One-command diagnostic that reports system health, security posture,
# AI agent status, and performance metrics.
#
# Usage: sudo kirat-health
###############################################################################

set -uo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; MAGENTA='\033[0;35m'; NC='\033[0m'; BOLD='\033[1m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║         KIRAT OS — System Health Diagnostic                          ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "  ${CYAN}ℹ${NC} $1"; }

score=0
max_score=0

check() {
    local name="$1"
    local cmd="$2"
    max_score=$((max_score + 10))
    echo -n "Checking $name... "
    if eval "$cmd" >/dev/null 2>&1; then
        ok "PASS"
        score=$((score + 10))
        return 0
    else
        fail "FAIL"
        return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM HEALTH
# ─────────────────────────────────────────────────────────────────────────────
check_system() {
    echo -e "${MAGENTA}${BOLD}── System Health ──${NC}"

    check "Disk space (root > 20% free)" "[ \$(df / | tail -1 | awk '{print \$4}') -gt 2097152 ]"
    check "Disk space (data > 20% free)" "[ \$(df /data 2>/dev/null | tail -1 | awk '{print \$4}') -gt 2097152 ]"
    check "Memory (RAM > 1GB free)" "[ \$(free | grep Mem | awk '{print \$7}') -gt 1048576 ]"
    check "Load average (< 5.0)" "[ \$(cat /proc/loadavg | awk '{print \$1}' | cut -d. -f1) -lt 5 ]"
    check "Uptime (< 365 days)" "[ \$(cat /proc/uptime | awk '{print \$1}' | cut -d. -f1) -lt 31536000 ]"

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY POSTURE
# ─────────────────────────────────────────────────────────────────────────────
check_security() {
    echo -e "${MAGENTA}${BOLD}── Security Posture ──${NC}"

    check "UFW firewall active" "ufw status | grep -q 'Status: active'"
    check "Fail2ban running" "systemctl is-active fail2ban"
    check "AppArmor enabled" "aa-status --enabled 2>/dev/null"
    check "SSH key-only auth" "grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config.d/kirat-production.conf"
    check "Root locked" "passwd -S root | grep -q 'L'"
    check "LUKS encryption active" "cryptsetup status kirat-root"
    check "AIDE baseline exists" "[ -f /var/lib/aide/aide.db.new ]"
    check "Auditd running" "systemctl is-active auditd"
    check "Unattended upgrades enabled" "grep -q 'Unattended-Upgrade' /etc/apt/apt.conf.d/50unattended-upgrades"
    check "Kernel lockdown" "grep -q 'lockdown=confidentiality' /proc/cmdline"

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# AI AGENT STATUS
# ─────────────────────────────────────────────────────────────────────────────
check_ai_agents() {
    echo -e "${MAGENTA}${BOLD}── AI Agent Status ──${NC}"

    for agent in jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai sentinel; do
        local svc="$agent"
        [ "$agent" = "sentinel" ] && svc="sentinel"
        if systemctl is-active "$svc" >/dev/null 2>&1; then
            ok "$agent: ACTIVE"
            score=$((score + 5))
        else
            fail "$agent: INACTIVE"
        fi
        max_score=$((max_score + 5))
    done

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICES
# ─────────────────────────────────────────────────────────────────────────────
check_services() {
    echo -e "${MAGENTA}${BOLD}── Business Services ──${NC}"

    check "PostgreSQL" "systemctl is-active postgresql"
    check "Redis" "systemctl is-active redis-server"
    check "Nginx" "systemctl is-active nginx"
    check "Docker" "systemctl is-active docker"
    check "Ollama" "systemctl is-active ollama"

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# PERFORMANCE
# ─────────────────────────────────────────────────────────────────────────────
check_performance() {
    echo -e "${MAGENTA}${BOLD}── Performance Metrics ──${NC}"

    local cpu_idle
    cpu_idle=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}' | cut -d'%' -f1)
    info "CPU idle: ${cpu_idle}%"

    local mem_used
    mem_used=$(free | grep Mem | awk '{printf "%.1f", ($3/$2)*100}')
    info "Memory used: ${mem_used}%"

    local disk_io
    disk_io=$(iostat -d 1 1 2>/dev/null | tail -1 | awk '{print $10}' || echo "N/A")
    info "Disk I/O (tps): $disk_io"

    local net_conn
    net_conn=$(ss -tuln | wc -l)
    info "Open ports: $net_conn"

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# SECURITY SCORE
# ─────────────────────────────────────────────────────────────────────────────
print_score() {
    local pct=$((score * 100 / max_score))
    echo -e "${MAGENTA}${BOLD}── Overall Health Score ──${NC}"
    echo ""
    if [ "$pct" -ge 90 ]; then
        echo -e "  ${GREEN}${BOLD}SCORE: $pct/100 — EXCELLENT${NC}"
    elif [ "$pct" -ge 75 ]; then
        echo -e "  ${YELLOW}${BOLD}SCORE: $pct/100 — GOOD${NC}"
    elif [ "$pct" -ge 60 ]; then
        echo -e "  ${YELLOW}${BOLD}SCORE: $pct/100 — FAIR${NC}"
    else
        echo -e "  ${RED}${BOLD}SCORE: $pct/100 — NEEDS ATTENTION${NC}"
    fi
    echo ""
    echo "  $score / $max_score checks passed"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

header
check_system
check_security
check_ai_agents
check_services
check_performance
print_score

echo -e "${CYAN}Run 'kirat-admin agent status' for detailed AI agent info.${NC}"
echo -e "${CYAN}Run 'journalctl -xe' for system logs.${NC}"
echo ""
