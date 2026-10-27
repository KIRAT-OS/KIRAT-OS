#!/bin/bash
###############################################################################
# KIRAT OS — VM Test Script for WSL2 or Linux Hosts
# Tests the native installer inside QEMU without risking real hardware.
###############################################################################

set -euo pipefail

RAM_GB="${RAM_GB:-8}"
DISK_GB="${DISK_GB:-60}"
CPU_CORES="${CPU_CORES:-4}"
VM_NAME="${VM_NAME:-kirat-os-test}"
WORK_DIR="${WORK_DIR:-$HOME/kirat-os-vm-test}"
ISO_URL="https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.7.0-amd64-standard.iso"
ISO_FILE="${ISO_FILE:-$WORK_DIR/debian-live-12-amd64-standard.iso}"
DISK_FILE="$WORK_DIR/${VM_NAME}-disk.img"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[BUILD]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}   $1"; }
log_stage() { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  ▶ $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}\n"; }

# ── PRE-FLIGHT ──
log_stage "PRE-FLIGHT: Checking Environment"

if [ "$(uname -m)" != "x86_64" ]; then
    log_error "KIRAT OS requires x86_64. Current: $(uname -m)"
    exit 1
fi
log_ok "Architecture: x86_64"

if ! command -v qemu-system-x86_64 &>/dev/null; then
    log_warn "qemu-system-x86_64 not found."
    echo "Install QEMU:"
    echo "  Debian/Ubuntu: sudo apt-get install qemu-system-x86 qemu-utils"
    echo "  Fedora:        sudo dnf install qemu-system-x86"
    echo "  Arch:          sudo pacman -S qemu-full"
    exit 1
fi
log_ok "QEMU found: $(which qemu-system-x86_64)"

# ── SETUP ──
log_stage "SETUP: Creating Workspace"
mkdir -p "$WORK_DIR"
log_ok "Workspace: $WORK_DIR"

# ── DOWNLOAD ISO ──
log_stage "DOWNLOAD: Debian 12 Live ISO"
if [ -f "$ISO_FILE" ]; then
    log_ok "ISO already exists: $ISO_FILE"
else
    log_warn "Downloading Debian Live ISO... (~400MB-3GB)"
    wget -O "$ISO_FILE" "$ISO_URL" || curl -L -o "$ISO_FILE" "$ISO_URL"
    log_ok "ISO downloaded: $ISO_FILE"
fi

# ── CREATE DISK ──
log_stage "DISK: Creating ${DISK_GB}GB Virtual Disk"
if [ -f "$DISK_FILE" ]; then
    log_warn "Disk already exists: $DISK_FILE"
    read -p "Overwrite? (y/N): " confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        rm -f "$DISK_FILE"
        qemu-img create -f raw "$DISK_FILE" "${DISK_GB}G"
        log_ok "Disk recreated: $DISK_FILE"
    fi
else
    qemu-img create -f raw "$DISK_FILE" "${DISK_GB}G"
    log_ok "Disk created: $DISK_FILE (${DISK_GB}GB raw)"
fi

# ── BOOT VM ──
log_stage "BOOT: Starting KIRAT OS Test VM"

cat << EOF
┌─────────────────────────────────────────────────────────────┐
│  KIRAT OS VM TEST ENVIRONMENT                               │
├─────────────────────────────────────────────────────────────┤
│  Engine:    QEMU (Linux/WSL2)                               │
│  RAM:       ${RAM_GB}GB                                     │
│  CPU:       ${CPU_CORES} cores                              │
│  Disk:      ${DISK_GB}GB                                    │
│  Disk File: ${DISK_FILE}                                    │
└─────────────────────────────────────────────────────────────┘

WHAT WILL HAPPEN:
  1. Debian Live boots inside QEMU
  2. Open a terminal inside the VM
  3. Mount your workspace with KIRAT OS files:
     sudo mkdir -p /mnt/kirat && sudo mount -t 9p -o trans=virtio kirat-share /mnt/kirat
  4. cd /mnt/kirat && sudo bash scripts/install-native.sh --disk /dev/sda --hostname test-kirat
  5. VM disk is wiped and KIRAT OS is installed (NOT your real disk)

PRESS ENTER TO START THE VM...
EOF
read -r

qemu-system-x86_64 \
    -m "$((RAM_GB * 1024))" \
    -smp "$CPU_CORES" \
    -hda "$DISK_FILE" \
    -cdrom "$ISO_FILE" \
    -boot d \
    -vga std \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device e1000,netdev=net0 \
    -fsdev local,id=kiratshare,path="$(dirname "$(dirname "$(dirname "$0")")")",security_model=none \
    -device virtio-9p-pci,fsdev=kiratshare,mount_tag=kirat-share \
    -name "$VM_NAME" \
    -no-reboot

log_stage "POST-TEST"
cat << EOF
QEMU session ended.

TO TEST KIRAT OS AFTER INSTALL:
  1. Re-run this script WITHOUT the ISO (boot from disk):
     qemu-system-x86_64 -m 8192 -hda "$DISK_FILE" -vga std \\
       -netdev user,id=net0,hostfwd=tcp::2222-:22 -device e1000,netdev=net0

  2. SSH from host: ssh -p 2222 kirat-admin@localhost

  3. Check services: sudo systemctl status nginx ssh ollama sentinel

TO CLEAN UP:
  rm -f "$DISK_FILE" "$ISO_FILE"
  rmdir "$WORK_DIR" 2>/dev/null || true

KIRAT OS VM test complete! 🛡️
EOF
