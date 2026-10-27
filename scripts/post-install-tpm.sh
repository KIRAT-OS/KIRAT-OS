#!/bin/bash
# =============================================================================
# KIRAT OS — TPM 2.0 LUKS Auto-Unlock Setup
# =============================================================================
# Binds your LUKS encrypted partitions to TPM 2.0 so they unlock
# automatically at boot WITHOUT typing the passphrase.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${BLUE}[TPM]${NC}   $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}   $1"; }

die() { log_error "$1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         KIRAT OS — TPM 2.0 LUKS Auto-Unlock Setup                   ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Check TPM 2.0 ──
if [ ! -d /sys/class/tpm/tpm0 ]; then
    die "No TPM 2.0 device found. Check BIOS: Security → TPM must be ENABLED."
fi

TPM_VERSION=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "0")
if [ "$TPM_VERSION" != "2" ]; then
    die "TPM version $TPM_VERSION detected. TPM 2.0 is required."
fi
log_ok "TPM 2.0 detected"

# ── Check clevis ──
if ! command -v clevis >/dev/null 2>&1; then
    log_info "Installing clevis and TPM2 tools..."
    apt-get update -qq
    apt-get install -y -qq clevis clevis-luks clevis-tpm2 clevis-dracut tpm2-tools
fi

# ── Detect LUKS partitions ──
echo ""
log_info "Detecting LUKS encrypted partitions..."

LUKS_PARTITIONS=()
for dev in $(lsblk -dpno NAME,TYPE | grep 'disk$' | awk '{print $1}'); do
    for part in "${dev}"*; do
        if [ "$part" = "$dev" ]; then continue; fi
        if cryptsetup isLuks "$part" 2>/dev/null; then
            LUKS_PARTITIONS+=("$part")
            echo "  Found LUKS: $part"
        fi
    done
done

if [ ${#LUKS_PARTITIONS[@]} -eq 0 ]; then
    die "No LUKS partitions found. Did you install KIRAT OS with encryption?"
fi

log_ok "Found ${#LUKS_PARTITIONS[@]} LUKS partition(s)"

# ── Bind each partition to TPM ──
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  This will bind your LUKS passphrase to TPM 2.0."
echo "  Your disk will unlock automatically at boot."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  WARNING:"
echo "    - If TPM is cleared/reset, auto-unlock will FAIL"
echo "    - You must still remember your LUKS passphrase as backup"
echo "    - PCR policy binds to current boot state (secure)"
echo ""
read -p "  Continue? [yes/NO]: " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "  Aborted."
    exit 0
fi

for PART in "${LUKS_PARTITIONS[@]}"; do
    PART_NAME=$(basename "$PART")
    MAPPED_NAME=""

    # Determine mapper name from crypttab
    if grep -q "$PART_NAME" /etc/crypttab 2>/dev/null; then
        MAPPED_NAME=$(grep "$PART_NAME" /etc/crypttab | awk '{print $1}')
    elif grep -q "$PART" /etc/crypttab 2>/dev/null; then
        MAPPED_NAME=$(grep "$PART" /etc/crypttab | awk '{print $1}')
    fi

    if [ -z "$MAPPED_NAME" ]; then
        log_warn "Could not determine mapper name for $PART, skipping"
        continue
    fi

    echo ""
    log_info "Binding $PART ($MAPPED_NAME) to TPM 2.0..."

    # Check if already bound
    if clevis luks list -d "$PART" 2>/dev/null | grep -q "tpm2"; then
        log_warn "$PART is already TPM-bound. Skipping."
        continue
    fi

    read -s -p "  Enter LUKS passphrase for $PART: " PASSPHRASE
    echo ""

    # Bind with PCR policy (PCR 0,2,7 = firmware, kernel, secure boot state)
    if printf '%s' "$PASSPHRASE" | clevis luks bind -d "$PART" tpm2 '{"pcr_ids":"0,2,7"}' -; then
        log_ok "$PART → TPM 2.0 binding SUCCESS"
    else
        log_error "$PART → TPM 2.0 binding FAILED"
        log_error "Common causes: wrong passphrase, TPM already max slots"
    fi
done

# ── Update initramfs ──
echo ""
log_info "Updating initramfs for TPM unlock..."
update-initramfs -u -k all
log_ok "initramfs updated"

# ── Done ──
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         TPM 2.0 AUTO-UNLOCK CONFIGURED                              ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next boot: your disk will unlock automatically via TPM."
echo "  Backup passphrase still works if TPM fails."
echo ""
echo "  To remove TPM binding later:"
echo "    clevis luks unbind -d <partition> -s <slot>"
echo ""
echo "  To verify binding:"
echo "    clevis luks list -d <partition>"
echo ""
