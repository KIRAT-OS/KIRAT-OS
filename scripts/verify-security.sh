#!/bin/bash
# =============================================================================
# KIRAT OS — Post-Install Security Verification Script
# =============================================================================
# Run this after installing KIRAT OS to verify all security controls are active.
# Usage: sudo bash verify-security.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

PASS=0; FAIL=0; WARN=0

pass()  { echo -e "${GREEN}[PASS]${NC}  $1"; ((PASS++)); }
fail()  { echo -e "${RED}[FAIL]${NC}   $1"; ((FAIL++)); }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; ((WARN++)); }
info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         KIRAT OS — SECURITY VERIFICATION AUDIT                      ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Disk Encryption ──
info "=== 1. DISK ENCRYPTION ==="
if cryptsetup status kirat-root >/dev/null 2>&1; then
    pass "Root partition (kirat-root) is LUKS encrypted"
else
    fail "Root partition encryption not active"
fi

if cryptsetup status kirat-data >/dev/null 2>&1; then
    pass "Data partition (kirat-data) is LUKS encrypted"
else
    fail "Data partition encryption not active"
fi

if [ -f /etc/crypttab ]; then
    grep -q "kirat-root" /etc/crypttab && pass "crypttab configured for root"
    grep -q "kirat-data" /etc/crypttab && pass "crypttab configured for data"
else
    fail "crypttab missing"
fi

# ── 2. Root Account Lockdown ──
info "=== 2. ROOT ACCOUNT ==="
ROOT_SHELL=$(getent passwd root | cut -d: -f7)
if [ "$ROOT_SHELL" = "/usr/sbin/nologin" ] || [ "$ROOT_SHELL" = "/bin/false" ]; then
    pass "Root shell is nologin/false"
else
    warn "Root shell is $ROOT_SHELL (should be nologin)"
fi

if passwd -S root 2>/dev/null | grep -q "L"; then
    pass "Root password is locked"
else
    warn "Root password is NOT locked"
fi

# ── 3. RBAC Users ──
info "=== 3. RBAC USER MODEL ==="
for user in kirat-admin security-officer ops-engineer dev-engineer incident-responder; do
    if id "$user" >/dev/null 2>&1; then
        pass "User $user exists"
    else
        fail "User $user MISSING"
    fi
done

for agent in sentinel-ai quantum-ai executor-ai auditor-ai orchestrator-ai ollama kirat-dashboard; do
    if id "$agent" >/dev/null 2>&1; then
        pass "Service account $agent exists"
    else
        warn "Service account $agent missing (may be optional)"
    fi
done

# ── 4. Sudoers Sanity ──
info "=== 4. SUDOERS CONFIGURATION ==="
if [ -d /etc/sudoers.d ]; then
    WILDCARD_COUNT=$(grep -rE 'NOPASSWD:.*\*' /etc/sudoers.d/ 2>/dev/null | wc -l)
    if [ "$WILDCARD_COUNT" -eq 0 ]; then
        pass "No dangerous wildcards in sudoers"
    else
        fail "Found $WILDCARD_COUNT sudoers lines with wildcards"
    fi
else
    fail "sudoers.d directory missing"
fi

# ── 5. SSH Hardening ──
info "=== 5. SSH HARDENING ==="
if [ -f /etc/ssh/sshd_config.d/kirat-production.conf ]; then
    pass "KIRAT SSH hardening config present"
    grep -q "PermitRootLogin prohibit-password" /etc/ssh/sshd_config.d/kirat-production.conf && pass "Root login prohibited"
    grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/kirat-production.conf && pass "Password auth disabled (key only)"
    grep -q "sntrup761" /etc/ssh/sshd_config.d/kirat-production.conf && pass "PQC SSH enabled"
else
    fail "KIRAT SSH config missing"
fi

# ── 6. Firewall ──
info "=== 6. FIREWALL ==="
if systemctl is-active --quiet ufw 2>/dev/null || ufw status | grep -q "Status: active"; then
    pass "UFW is active"
else
    fail "UFW is NOT active"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Fail2ban is active"
else
    warn "Fail2ban is NOT active"
fi

# ── 7. AppArmor ──
info "=== 7. MANDATORY ACCESS CONTROL ==="
if systemctl is-active --quiet apparmor 2>/dev/null; then
    pass "AppArmor is active"
else
    warn "AppArmor is NOT active"
fi

# ── 8. Kernel Hardening ──
info "=== 8. KERNEL PARAMETERS ==="
if [ -f /etc/sysctl.d/99-kirat-production.conf ]; then
    pass "KIRAT kernel hardening config present"
    sysctl kernel.randomize_va_space 2>/dev/null | grep -q "2" && pass "ASLR enabled"
    sysctl kernel.kptr_restrict 2>/dev/null | grep -q "2" && pass "kptr_restrict enabled"
    sysctl kernel.dmesg_restrict 2>/dev/null | grep -q "1" && pass "dmesg_restrict enabled"
else
    fail "Kernel hardening config missing"
fi

# ── 9. Intrusion Detection ──
info "=== 9. INTRUSION DETECTION ==="
if command -v aide >/dev/null 2>&1; then
    pass "AIDE installed"
    if [ -f /var/lib/aide/aide.db ]; then
        pass "AIDE database initialized"
    else
        warn "AIDE database not initialized yet"
    fi
else
    fail "AIDE not installed"
fi

if command -v rkhunter >/dev/null 2>&1; then
    pass "rkhunter installed"
else
    warn "rkhunter not installed"
fi

if command -v auditd >/dev/null 2>&1; then
    pass "auditd installed"
    systemctl is-active --quiet auditd 2>/dev/null && pass "auditd is running"
else
    warn "auditd not installed"
fi

# ── 10. Auto-Patching ──
info "=== 10. AUTOMATIC SECURITY PATCHES ==="
if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then
    pass "unattended-upgrades configured"
    grep -q "Unattended-Upgrade::Unattended-Upgrade" /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null && pass "Auto-upgrades enabled"
else
    fail "unattended-upgrades NOT configured"
fi

# ── 11. TLS Certificate ──
info "=== 11. TLS / HTTPS ==="
if [ -f /etc/nginx/ssl/kirat-cert.pem ]; then
    pass "TLS certificate exists"
    openssl x509 -in /etc/nginx/ssl/kirat-cert.pem -noout -text 2>/dev/null | grep -q "Subject Alternative Name" && pass "Certificate has SAN"
else
    fail "TLS certificate missing"
fi

# ── 12. Audit Logging ──
info "=== 12. AI AGENT AUDIT LOG ==="
if [ -f /opt/kirat-os/security/rbac/logs/executor-audit.jsonl ]; then
    LOG_COUNT=$(wc -l < /opt/kirat-os/security/rbac/logs/executor-audit.jsonl)
    pass "Executor audit log exists ($LOG_COUNT entries)"
else
    warn "No executor audit entries yet (normal for fresh install)"
fi

# ── 13. Secure Boot MOK ──
info "=== 13. SECURE BOOT / MOK ==="
if [ -f /opt/kirat-os/security/mok/MOK.der ] && [ -f /opt/kirat-os/security/mok/MOK.priv ]; then
    pass "MOK keys generated"
    PERM=$(stat -c %a /opt/kirat-os/security/mok/MOK.priv 2>/dev/null)
    if [ "$PERM" = "600" ]; then
        pass "MOK private key has correct permissions (600)"
    else
        warn "MOK private key permissions are $PERM (should be 600)"
    fi
else
    warn "MOK keys not found (UEFI only, may be N/A)"
fi

# ── 14. Services ──
info "=== 14. CRITICAL SERVICES ==="
for svc in nginx postgresql redis-server docker; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        pass "Service $svc is enabled"
    else
        warn "Service $svc is not enabled"
    fi
done

# ── Summary ──
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         SECURITY VERIFICATION COMPLETE                              ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}PASSED:${NC}  $PASS"
echo -e "  ${YELLOW}WARNINGS:${NC} $WARN"
echo -e "  ${RED}FAILED:${NC}  $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}KIRAT OS SECURITY: VERIFIED${NC}"
    echo "  All critical controls are in place."
    exit 0
else
    echo -e "  ${RED}${BOLD}KIRAT OS SECURITY: ISSUES DETECTED${NC}"
    echo "  $FAIL critical checks failed. Review above and remediate."
    exit 1
fi
