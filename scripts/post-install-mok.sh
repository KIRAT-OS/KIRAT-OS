#!/bin/bash
# =============================================================================
# KIRAT OS — Secure Boot MOK Enrollment Helper
# =============================================================================
# Run this AFTER first boot to enroll your Machine Owner Key (MOK) for
# Secure Boot. This script is safe, guided, and requires physical presence.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${BLUE}[MOK]${NC}   $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}   $1"; }

die() { log_error "$1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         KIRAT OS — Secure Boot MOK Enrollment                       ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Check UEFI ──
if [ ! -d /sys/firmware/efi ]; then
    die "This system is using Legacy BIOS. Secure Boot MOK requires UEFI."
fi
log_ok "UEFI mode confirmed"

# ── Check MOK keys exist ──
MOK_DIR="/opt/kirat-os/security/mok"
MOK_DER="$MOK_DIR/MOK.der"
MOK_PRIV="$MOK_DIR/MOK.priv"

if [ ! -f "$MOK_DER" ] || [ ! -f "$MOK_PRIV" ]; then
    die "MOK keys not found at $MOK_DIR. Run the native installer first."
fi

log_ok "MOK keys found"
ls -la "$MOK_DIR"

# ── Check mokutil ──
if ! command -v mokutil >/dev/null 2>&1; then
    log_info "Installing mokutil..."
    apt-get update -qq && apt-get install -y -qq mokutil
fi

# ── Check Secure Boot status ──
SB_STATUS=$(mokutil --sb-state 2>/dev/null | head -1 || echo "unknown")
log_info "Secure Boot state: $SB_STATUS"

if echo "$SB_STATUS" | grep -qi "enabled"; then
    log_warn "Secure Boot is ENABLED. You MUST enroll the MOK or the system"
    log_warn "will refuse to boot custom kernels or modules."
elif echo "$SB_STATUS" | grep -qi "disabled"; then
    log_warn "Secure Boot is DISABLED. You can enable it after MOK enrollment."
fi

# ── Enroll MOK ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 1: Enroll MOK into firmware"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  This will:"
echo "    1. Import the MOK public key into the firmware"
echo "    2. Ask you to create a ONE-TIME enrollment password"
echo "    3. REBOOT the system"
echo "    4. Show a BLUE SCREEN at boot — type the enrollment password"
echo "    5. Select 'Enroll MOK' → 'Continue' → 'Yes' → enter password"
echo ""
read -p "  Continue? [yes/NO]: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "  Aborted. Run this script again when ready."
    exit 0
fi

# Create a one-time enrollment password
ENROLL_PASS="KIRAT-$(openssl rand -hex 4)"
echo ""
echo "  🔐 Your ONE-TIME enrollment password: $ENROLL_PASS"
echo "     Write this down. You will type it at the blue boot screen."
echo ""

# Import the MOK
echo "$ENROLL_PASS" | mokutil --import "$MOK_DER" --password-

if [ $? -eq 0 ]; then
    log_ok "MOK imported successfully"
else
    die "MOK import failed"
fi

# ── Reboot instructions ──
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         REBOOT REQUIRED                                             ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  After reboot, you will see a BLUE SCREEN titled 'MOK Manager'."
echo ""
echo "  Follow these exact steps:"
echo "    1. Select 'Enroll MOK'"
echo "    2. Select 'Continue'"
echo "    3. Select 'Yes' to enroll"
echo "    4. Enter password: $ENROLL_PASS"
echo "    5. Select 'Reboot'"
echo ""
echo "  After reboot, Secure Boot will trust your KIRAT OS kernel modules."
echo ""
read -p "  Reboot now? [yes/NO]: " REBOOT

if [ "$REBOOT" = "yes" ]; then
    log_info "Rebooting..."
    reboot
else
    echo "  Remember to reboot manually. The password is: $ENROLL_PASS"
    echo "  Save this password to a file: echo '$ENROLL_PASS' > ~/mok-password.txt"
fi
