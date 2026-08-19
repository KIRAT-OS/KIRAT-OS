#!/bin/bash
# =============================================================================
# KIRAT OS - Bootable ISO Builder
# =============================================================================
# Usage: sudo ./build-iso.sh [options]
# Options:
#   --output PATH        Output ISO path (default: /tmp/kirat-os-2.0.0.iso)
#   --arch ARCH          Target architecture (default: amd64)
#   --suite SUITE        Debian suite (default: bookworm)
#   --mirror URL         Debian mirror (default: http://deb.debian.org/debian)
#   --include-installer  Include native installer in ISO
#   --sign               GPG-sign the ISO
#   --compression TYPE   xz|gzip|lzo (default: xz)
#   -h, --help           Show this help
#
# Creates a bootable ISO with:
#   • Debian Live environment (try without installing)
#   • Native KIRAT OS installer (bare-metal install)
#   • GRUB2 EFI + BIOS dual boot
#   • LUKS/cryptsetup in initramfs
#   • Secure Boot support (if keys available)
# =============================================================================

set -euo pipefail

readonly SCRIPT_VERSION="2.0.0"
readonly KIRAT_VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KIRAT_OS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ───────────────────────────────────────────────────────────
ARCH="amd64"
SUITE="bookworm"
MIRROR="http://deb.debian.org/debian"
OUTPUT="/tmp/kirat-os-${KIRAT_VERSION}.iso"
INCLUDE_INSTALLER=true
SIGN_ISO=false
COMPRESSION="xz"
WORK_DIR=""
CLEANUP=true

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*"; }
info() { echo -e "${CYAN}ℹ${NC} $*"; }

# ── Header ──────────────────────────────────────────────────────────────────
header() {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  KIRAT OS Bootable ISO Builder v${SCRIPT_VERSION}${NC}"
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
            --output) OUTPUT="$2"; shift 2 ;;
            --arch) ARCH="$2"; shift 2 ;;
            --suite) SUITE="$2"; shift 2 ;;
            --mirror) MIRROR="$2"; shift 2 ;;
            --include-installer) INCLUDE_INSTALLER=true; shift ;;
            --no-installer) INCLUDE_INSTALLER=false; shift ;;
            --sign) SIGN_ISO=true; shift ;;
            --compression) COMPRESSION="$2"; shift 2 ;;
            --no-cleanup) CLEANUP=false; shift ;;
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

# ── Dependency Check ────────────────────────────────────────────────────────
check_deps() {
    local deps=("debootstrap" "grub-mkrescue" "xorriso" "mksquashfs" "curl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
        info "Install with: sudo apt-get install -y debootstrap grub-pc-bin grub-efi-amd64-bin xorriso squashfs-tools curl"
        exit 1
    fi

    ok "All dependencies present"
}

# ── Setup Working Directory ─────────────────────────────────────────────────
setup_workdir() {
    WORK_DIR=$(mktemp -d -t kirat-iso-XXXXXX)
    info "Working directory: $WORK_DIR"
    mkdir -p "$WORK_DIR"/{live,installer,efi,boot/grub}
}

# ── Cleanup ─────────────────────────────────────────────────────────────────
cleanup() {
    if [[ "$CLEANUP" == true ]] && [[ -n "$WORK_DIR" ]] && [[ -d "$WORK_DIR" ]]; then
        info "Cleaning up working directory..."
        rm -rf "$WORK_DIR"
    fi
}

# ── Stage 1: Build Base Rootfs ──────────────────────────────────────────────
stage_build_rootfs() {
    info "STAGE 1/6: Building base rootfs with debootstrap..."
    local rootfs="$WORK_DIR/live/rootfs"
    mkdir -p "$rootfs"

    # Debootstrap minimal base
    debootstrap --arch="$ARCH" --variant=minbase \
        --include="linux-image-amd64,live-boot,cryptsetup,lvm2,systemd,systemd-sysv,openssh-server,nginx,python3,python3-pip,nodejs,npm,postgresql,postgresql-contrib,ufw,fail2ban,auditd,apparmor,sysstat,htop,curl,wget,vim,nano,sudo,dbus,polkitd,ca-certificates,openssl,gnupg,apt-transport-https,net-tools,iputils-ping,dnsutils,iptables,ipset,wireguard-tools,qrencode,openvpn,easy-rsa,strongswan,strongswan-pki,libstrongswan-extra-plugins,libcharon-extra-plugins,acl,attr,quota,quotatool,nfs-common,samba,rsync,git,unzip,tar,gzip,bzip2,xz-utils,zstd,lz4,lzo,p7zip-full,lm-sensors,smartmontools,ethtool,pciutils,usbutils,cpufrequtils,thermald,dpkg-dev,build-essential,dkms,linux-headers-amd64,bc,bison,flex,libssl-dev,libelf-dev,debhelper,quilt,lintian,fakeroot,devscripts,debootstrap,squashfs-tools,xorriso,grub-pc-bin,grub-efi-amd64-bin,efibootmgr,shim-signed,shim-helpers-amd64-signed,mokutil,sbsigntool,systemd-boot,systemd-boot-efi,tpm2-tools,tpm2-abrmd,libtss2-esys-3.0.2-0,libtss2-rc0,libtss2-mu0,libtss2-tcti-device0,libtss2-tcti-mssim0,p11-kit,opensc,libpam-pkcs11,libpam-u2f,fido2-tools,libfido2-1,softhsm2,libengine-pkcs11-openssl,gnutls-bin,libgnutls30,libnss3-tools,ca-certificates-java,java-common,default-jre-headless,containerd.io,docker-ce,docker-ce-cli,docker-compose-plugin,kubectl,kubeadm,kubelet,helm,minikube,cri-o-runc,cri-tools,buildah,podman,skopeo,slirp4netns,fuse-overlayfs,uidmap,slirp4netns,qemu-system-x86,qemu-utils,libvirt-daemon-system,libvirt-clients,virt-manager,ovmf,ovmf-ia32, seabios,ipxe-qemu" \
        "$SUITE" "$rootfs" "$MIRROR" || {
        err "debootstrap failed"
        exit 1
    }

    ok "Base rootfs created"
}

# ── Stage 2: Configure Live Environment ─────────────────────────────────────
stage_configure_live() {
    info "STAGE 2/6: Configuring live environment..."
    local rootfs="$WORK_DIR/live/rootfs"

    # Mount pseudo-filesystems for chroot
    mount --bind /dev "$rootfs/dev"
    mount --bind /proc "$rootfs/proc"
    mount --bind /sys "$rootfs/sys"
    mount --bind /dev/pts "$rootfs/dev/pts"

    # Set hostname
    echo "kirat-os-live" > "$rootfs/etc/hostname"
    cat > "$rootfs/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   kirat-os-live
EOF

    # Configure live-boot
    cat > "$rootfs/etc/live/config.conf" << EOF
# KIRAT OS Live Configuration
LIVE_USERNAME=kirat
LIVE_USER_FULLNAME="KIRAT OS Live User"
LIVE_HOSTNAME=kirat-os-live
EOF

    # Add live user
    chroot "$rootfs" useradd -m -s /bin/bash -G sudo,adm,systemd-journal kirat 2>/dev/null || true
    echo "kirat:kirat" | chroot "$rootfs" chpasswd 2>/dev/null || true

    # Configure sudo
    echo "kirat ALL=(ALL) NOPASSWD: ALL" > "$rootfs/etc/sudoers.d/kirat-live"
    chmod 440 "$rootfs/etc/sudoers.d/kirat-live"

    # Configure SSH for live
    cat > "$rootfs/etc/ssh/sshd_config.d/kirat-live.conf" << 'EOF'
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

    # Configure autologin for TTY1
    mkdir -p "$rootfs/etc/systemd/system/getty@tty1.service.d"
    cat > "$rootfs/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kirat --noclear %I $TERM
EOF

    # Enable services
    chroot "$rootfs" systemctl enable ssh nginx 2>/dev/null || true

    # Unmount
    umount -l "$rootfs/dev/pts" 2>/dev/null || true
    umount -l "$rootfs/dev" 2>/dev/null || true
    umount -l "$rootfs/proc" 2>/dev/null || true
    umount -l "$rootfs/sys" 2>/dev/null || true

    ok "Live environment configured"
}

# ── Stage 3: Include Installer ──────────────────────────────────────────────
stage_include_installer() {
    [[ "$INCLUDE_INSTALLER" != true ]] && { info "Skipping installer"; return 0; }

    info "STAGE 3/6: Including native KIRAT OS installer..."
    local rootfs="$WORK_DIR/live/rootfs"
    local installer_dir="$rootfs/opt/kirat-os-installer"

    mkdir -p "$installer_dir"

    # Copy installer script
    if [[ -f "$KIRAT_OS_DIR/scripts/install-native.sh" ]]; then
        cp "$KIRAT_OS_DIR/scripts/install-native.sh" "$installer_dir/"
        chmod +x "$installer_dir/install-native.sh"
        ok "Native installer copied"
    else
        warn "install-native.sh not found at $KIRAT_OS_DIR/scripts/install-native.sh"
    fi

    # Copy KIRAT OS components
    if [[ -d "$KIRAT_OS_DIR" ]]; then
        rsync -a --exclude='.git' --exclude='*.iso' \
            "$KIRAT_OS_DIR/" "$rootfs/opt/kirat-os/" 2>/dev/null || true
        ok "KIRAT OS components copied to live environment"
    fi

    # Create installer launcher script
    cat > "$rootfs/usr/local/bin/kirat-os-install" << 'INSTALLER'
#!/bin/bash
# KIRAT OS Native Installer Launcher
# Runs from live environment to install KIRAT OS to disk

set -e

clear
echo "═══════════════════════════════════════════════════════════════"
echo "  KIRAT OS Native Installer"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  This will install KIRAT OS to your computer's hard drive."
echo "  ALL DATA ON THE TARGET DISK WILL BE ERASED."
echo ""
echo "  Options:"
echo "    1) Standard Install (UEFI, LUKS2, full hardening)"
echo "    2) Advanced Install (custom partitioning)"
echo "    3) Dual Boot with Windows (shrink existing partition)"
echo "    4) Cancel"
echo ""
read -rp "Select option [1-4]: " choice

case "$choice" in
    1)
        sudo bash /opt/kirat-os-installer/install-native.sh --target auto --uefi --luks2 --harden
        ;;
    2)
        sudo bash /opt/kirat-os-installer/install-native.sh --interactive
        ;;
    3)
        sudo bash /opt/kirat-os-installer/install-native.sh --dual-boot --target auto
        ;;
    *)
        echo "Installation cancelled."
        exit 0
        ;;
esac

INSTALLER
    chmod +x "$rootfs/usr/local/bin/kirat-os-install"

    # Create desktop entry for installer
    mkdir -p "$rootfs/usr/share/applications"
    cat > "$rootfs/usr/share/applications/kirat-os-install.desktop" << 'EOF'
[Desktop Entry]
Name=Install KIRAT OS
Comment=Install KIRAT OS to your computer
Exec=lxterminal -e /usr/local/bin/kirat-os-install
Type=Application
Terminal=false
Icon=system-software-install
Categories=System;
EOF

    ok "Installer integration complete"
}

# ── Stage 4: Create Boot Menu ───────────────────────────────────────────────
stage_boot_menu() {
    info "STAGE 4/6: Creating GRUB2 boot menu..."

    local grub_dir="$WORK_DIR/boot/grub"
    mkdir -p "$grub_dir"

    # GRUB theme/config
    cat > "$grub_dir/grub.cfg" << GRUBEOF
# KIRAT OS GRUB2 Boot Configuration
set timeout=10
set default=0

# Load modules
insmod part_gpt
insmod part_msdos
insmod fat
insmod iso9660
insmod all_video
insmod gfxterm
insmod png

# Set resolution
set gfxmode=auto
terminal_output gfxterm

# Colors
set menu_color_normal=white/black
set menu_color_highlight=black/white

# KIRAT OS Branding
set title="KIRAT OS Server ${KIRAT_VERSION}"

# ── Menu Entries ──────────────────────────────────────────────────────────

menuentry "▶ Try KIRAT OS Live (Safe Mode)" --class kirat {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "▶ Try KIRAT OS Live (Forensic Mode - No Mount)" --class kirat {
    linux /live/vmlinuz boot=live components quiet splash nomount
    initrd /live/initrd.img
}

menuentry "▶ Install KIRAT OS (Standard - Full Disk)" --class installer {
    linux /live/vmlinuz boot=live components quiet splash kirat-install=auto
    initrd /live/initrd.img
}

menuentry "▶ Install KIRAT OS (Advanced - Interactive)" --class installer {
    linux /live/vmlinuz boot=live components quiet splash kirat-install=interactive
    initrd /live/initrd.img
}

menuentry "▶ Install KIRAT OS (Dual Boot with Windows)" --class installer {
    linux /live/vmlinuz boot=live components quiet splash kirat-install=dualboot
    initrd /live/initrd.img
}

menuentry "🛠 Rescue Mode" --class rescue {
    linux /live/vmlinuz boot=live components rescue quiet
    initrd /live/initrd.img
}

menuentry "🐧 MemTest86+ (Memory Test)" --class memtest {
    linux16 /live/memtest86+
}

menuentry "🔄 Reboot" --class reboot {
    reboot
}

menuentry "⏻ Shutdown" --class halt {
    halt
}

GRUBEOF

    ok "GRUB2 boot menu created"
}

# ── Stage 5: Squash Rootfs ──────────────────────────────────────────────────
stage_squash() {
    info "STAGE 5/6: Creating compressed squashfs..."
    local rootfs="$WORK_DIR/live/rootfs"

    # Find kernel and initramfs
    local kernel vmlinuz initrd
    kernel=$(ls "$rootfs/boot/vmlinuz-"* 2>/dev/null | head -1)
    vmlinuz=$(basename "$kernel" 2>/dev/null || echo "vmlinuz")
    initrd=$(ls "$rootfs/boot/initrd.img-"* 2>/dev/null | head -1)

    if [[ -f "$kernel" ]]; then
        cp "$kernel" "$WORK_DIR/live/vmlinuz"
        ok "Kernel: $vmlinuz"
    fi

    if [[ -f "$initrd" ]]; then
        cp "$initrd" "$WORK_DIR/live/initrd.img"
        ok "Initramfs copied"
    fi

    # Create squashfs with selected compression
    local comp_opts
    case "$COMPRESSION" in
        xz) comp_opts="-comp xz -Xbcj x86" ;;
        gzip) comp_opts="-comp gzip" ;;
        lzo) comp_opts="-comp lzo" ;;
        *) comp_opts="-comp xz" ;;
    esac

    mksquashfs "$rootfs" "$WORK_DIR/live/filesystem.squashfs" \
        -noappend -always-use-fragments $comp_opts 2>/dev/null || {
        err "mksquashfs failed"
        exit 1
    }

    ok "Squashfs created: $(du -h "$WORK_DIR/live/filesystem.squashfs" | cut -f1)"

    # Cleanup rootfs to save space before ISO build
    rm -rf "$rootfs"
}

# ── Stage 6: Build ISO ──────────────────────────────────────────────────────
stage_build_iso() {
    info "STAGE 6/6: Building bootable ISO..."

    # Create EFI boot image
    local efi_img="$WORK_DIR/efi/efiboot.img"
    mkdir -p "$WORK_DIR/efi"
    dd if=/dev/zero of="$efi_img" bs=1M count=64 2>/dev/null
    mkfs.vfat "$efi_img" 2>/dev/null || true

    # Copy GRUB EFI files
    mkdir -p "$WORK_DIR/efi/boot"
    if [[ -f /usr/lib/shim/shimx64.efi.signed ]]; then
        cp /usr/lib/shim/shimx64.efi.signed "$WORK_DIR/efi/boot/bootx64.efi" 2>/dev/null || true
        cp /usr/lib/shim/mmx64.efi "$WORK_DIR/efi/boot/mmx64.efi" 2>/dev/null || true
    elif [[ -f /usr/lib/shim/shimx64.efi ]]; then
        cp /usr/lib/shim/shimx64.efi "$WORK_DIR/efi/boot/bootx64.efi" 2>/dev/null || true
    fi

    if [[ -f /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed ]]; then
        cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$WORK_DIR/efi/boot/grubx64.efi" 2>/dev/null || true
    elif [[ -f /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi ]]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi "$WORK_DIR/efi/boot/grubx64.efi" 2>/dev/null || true
    fi

    # Build ISO with grub-mkrescue
    grub-mkrescue \
        -o "$OUTPUT" \
        -V "KIRAT-OS-${KIRAT_VERSION}" \
        --modules="part_gpt part_msdos fat iso9660 all_video gfxterm png" \
        "$WORK_DIR" 2>/dev/null || {
        # Fallback: use xorriso directly
        xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "KIRAT-OS-${KIRAT_VERSION}" \
            -eltorito-boot boot/grub/grub.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/grub/boot.cat \
            -eltorito-alt-boot \
            -e efi/efiboot.img \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -isohybrid-apm-hfsplus \
            -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
            -output "$OUTPUT" \
            "$WORK_DIR" 2>/dev/null || {
            err "ISO build failed"
            exit 1
        }
    }

    ok "ISO built: $OUTPUT"
    info "Size: $(du -h "$OUTPUT" | cut -f1)"
    info "Volume ID: KIRAT-OS-${KIRAT_VERSION}"

    # Sign ISO if requested
    if [[ "$SIGN_ISO" == true ]]; then
        info "Signing ISO with GPG..."
        gpg --detach-sign --armor "$OUTPUT" 2>/dev/null || warn "GPG signing failed (no key?)"
    fi

    # Generate checksums
    info "Generating checksums..."
    (cd "$(dirname "$OUTPUT")" && \
        sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" && \
        md5sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").md5" 2>/dev/null) || true

    ok "Checksums generated"
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"
    check_root
    header
    check_deps
    setup_workdir
    trap cleanup EXIT

    info "Build configuration:"
    info "  Architecture: $ARCH"
    info "  Debian suite: $SUITE"
    info "  Output:       $OUTPUT"
    info "  Installer:    $INCLUDE_INSTALLER"
    info "  Compression:  $COMPRESSION"
    echo

    stage_build_rootfs
    stage_configure_live
    stage_include_installer
    stage_boot_menu
    stage_squash
    stage_build_iso

    header
    ok "KIRAT OS ISO BUILD COMPLETE!"
    info "Output: $OUTPUT"
    info "Size:   $(du -h "$OUTPUT" 2>/dev/null | cut -f1)"
    echo
    info "Next steps:"
    echo "  • Test in VM:  qemu-system-x86_64 -cdrom $OUTPUT -m 4G"
    echo "  • Write to USB: sudo dd if=$OUTPUT of=/dev/sdX bs=4M status=progress"
    echo "  • Verify:       sha256sum -c ${OUTPUT}.sha256"
    echo
    info "Boot menu options:"
    echo "  • Try KIRAT OS Live"
    echo "  • Install KIRAT OS (Standard/Advanced/Dual Boot)"
    echo "  • Rescue Mode"
}

main "$@"
