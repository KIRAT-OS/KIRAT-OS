#!/bin/bash
# =============================================================================
# KIRAT OS — WSL2 Build Environment Setup Helper
# =============================================================================
# Run this inside Debian WSL2 after first login.
# It installs every package needed to build and test the KIRAT OS ISO.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${BLUE}[SETUP]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}   $1"; }

die() { log_error "$1"; exit 1; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         KIRAT OS — WSL2 Build Environment Setup                       ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""

# ── Check we are in WSL2 ──
if [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
    die "This script must run inside WSL2. Detected native Linux or WSL1."
fi
log_ok "WSL2 environment confirmed"

# ── Check architecture ──
ARCH=$(uname -m)
if [ "$ARCH" != "x86_64" ]; then
    die "Unsupported architecture: $ARCH. KIRAT OS builds require x86_64."
fi
log_ok "Architecture: x86_64"

# ── Update system ──
log_info "Updating package lists..."
sudo apt-get update -qq

# ── Install build toolchain ──
log_info "Installing ISO build tools..."
sudo apt-get install -y -qq \
    debootstrap squashfs-tools xorriso isolinux syslinux-efi \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
    parted e2fsprogs fakeroot \
    git curl wget rsync jq

# ── Install QEMU for testing ──
log_info "Installing QEMU + KVM..."
sudo apt-get install -y -qq \
    qemu-utils qemu-system-x86 qemu-kvm \
    libvirt-clients libvirt-daemon-system \
    ovmf

# ── Add user to kvm group ──
log_info "Adding user to kvm group for hardware acceleration..."
sudo usermod -aG kvm "$USER"

# ── Verify KVM ──
if [ -c /dev/kvm ]; then
    log_ok "KVM device /dev/kvm is available"
else
    log_warn "KVM device not found. QEMU will use software emulation (slower)."
    log_warn "To fix: enable 'Virtualization' (Intel VT-x) in your BIOS/UEFI."
fi

# ── Check disk space ──
FREE_GB=$(df -BG "$HOME" | tail -1 | awk '{print $4}' | tr -d 'G')
log_info "Free disk space in $HOME: ${FREE_GB}GB"
if [ "$FREE_GB" -lt 30 ]; then
    log_warn "Less than 30 GB free. ISO build + QEMU test may fail."
    log_warn "Free up space or set TMPDIR to another drive."
fi

# ── Summary ──
echo ""
echo "╔══════════════════════════════════════════════════════════════════════╗"
echo "║         WSL2 BUILD ENVIRONMENT READY                                  ║"
echo "╚══════════════════════════════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo "    1. Copy project to WSL2 native filesystem:"
echo "       cp -r /mnt/c/Users/#RAI/Documents/kimi/workspace/kirat-os-server ~/"
echo ""
echo "    2. Enter the project:"
echo "       cd ~/kirat-os-server/scripts"
echo ""
echo "    3. Build the ISO:"
echo "       sudo ./build-iso.sh --output /tmp/kirat-os-2.0.0.iso --include-installer"
echo ""
echo "    4. Test with QEMU:"
echo "       qemu-img create -f qcow2 /tmp/test-disk.qcow2 30G"
echo "       qemu-system-x86_64 -enable-kvm -m 8192 -smp 4 \\"
echo "         -cdrom /tmp/kirat-os-2.0.0.iso -hda /tmp/test-disk.qcow2 -boot d"
echo ""
echo "  IMPORTANT: Log out and back into WSL2 for 'kvm' group to take effect."
echo ""
