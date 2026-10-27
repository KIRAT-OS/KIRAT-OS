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

readonly SCRIPT_VERSION="2.0.8"
readonly KIRAT_VERSION="2.0.8"
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
    echo -e "${BOLD}${CYAN}  KIRAT OS Bootable ISO Builder v${SCRIPT_VERSION} — PRE-RELEASE${NC}"
    echo -e "${BOLD}${YELLOW}  Not production-ready; no production fitness or security guarantees.${NC}"
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
    local deps=("debootstrap" "grub-mkimage" "xorriso" "mksquashfs" "unsquashfs" "curl" "mkfs.vfat" "mcopy" "mmd" "rsync")
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
        # Unmount any lingering bind mounts first (busy mounts make rm fail)
        for mp in run sys proc dev/pts dev; do
            umount -l "$WORK_DIR/live/rootfs/$mp" 2>/dev/null || true
        done
        rm -rf "$WORK_DIR"
    fi
}

# ── Stage 1: Build Base Rootfs ──────────────────────────────────────────────
stage_build_rootfs() {
    info "STAGE 1/6: Building base rootfs with debootstrap..."
    local rootfs="$WORK_DIR/live/rootfs"
    mkdir -p "$rootfs"

    # Two-stage debootstrap: unpack first, then configure inside a properly
    # bind-mounted chroot. postinst scripts (polkitd, dbus, golang-*) need
    # /proc /sys /dev /run present — plain debootstrap chroot lacks them (WSL2).
    # Debian-bookworm-native packages only (docker-ce/kubectl/helm live in
    # third-party repos — debootstrap would fail; docker.io covers containers)
    local PKGS="linux-image-amd64,live-boot,live-config,cryptsetup,lvm2,systemd,systemd-sysv,libpam-systemd,openssh-server,nginx,python3,python3-pip,postgresql,postgresql-contrib,ufw,fail2ban,auditd,apparmor,sysstat,htop,curl,wget,vim,nano,sudo,dbus,polkitd,ca-certificates,openssl,gnupg,apt-transport-https,net-tools,iputils-ping,dnsutils,iptables,ipset,wireguard-tools,qrencode,acl,attr,quota,quotatool,rsync,git,unzip,tar,gzip,bzip2,xz-utils,zstd,lz4,lzop,p7zip-full,lm-sensors,smartmontools,ethtool,pciutils,usbutils,cpufrequtils,thermald,dpkg-dev,build-essential,dkms,linux-headers-amd64,bc,bison,flex,libssl-dev,libelf-dev,fakeroot,debootstrap,squashfs-tools,xorriso,grub-pc-bin,grub-efi-amd64-bin,efibootmgr,mokutil,sbsigntool,tpm2-tools,tpm2-abrmd,p11-kit,opensc,libpam-u2f,fido2-tools,libfido2-1,gnutls-bin,libnss3-tools,containerd,docker.io,qemu-system-x86,qemu-utils,libvirt-daemon-system,libvirt-clients,ovmf,seabios,ipxe-qemu,memtest86+,dosfstools,mtools,parted,gdisk"

    debootstrap --arch="$ARCH" --variant=minbase --foreign \
        --include="$PKGS" \
        "$SUITE" "$rootfs" "$MIRROR" || {
        err "debootstrap stage-1 (unpack) failed"
        exit 1
    }

    info "Stage-1 unpack complete — running stage-2 configure in bind-mounted chroot..."
    mount --bind /dev  "$rootfs/dev"
    mount --bind /proc "$rootfs/proc"
    mount --bind /sys  "$rootfs/sys"
    # NOTE: never bind /run — chrooted postinsts would reach the HOST systemd
    # via /run/systemd and hang WSL. policy-rc.d blocks service starts instead.
    printf '#!/bin/sh\nexit 101\n' > "$rootfs/usr/sbin/policy-rc.d"
    chmod +x "$rootfs/usr/sbin/policy-rc.d"

    chroot "$rootfs" env DEBIAN_FRONTEND=noninteractive /debootstrap/debootstrap --second-stage || {
        # Preserve the inner debootstrap log for forensics BEFORE cleanup wipes it
        cp "$rootfs/debootstrap/debootstrap.log" "$(dirname "$OUTPUT")/debootstrap-error.log" 2>/dev/null || true
        err "debootstrap stage-2 (configure) failed — inner log saved to $(dirname "$OUTPUT")/debootstrap-error.log"
        exit 1
    }

    rm -f "$rootfs/usr/sbin/policy-rc.d"
    umount -l "$rootfs/sys"  2>/dev/null || true
    umount -l "$rootfs/proc" 2>/dev/null || true
    umount -l "$rootfs/dev"  2>/dev/null || true

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

    # Add a console-only live user. Its password is locked: never ship the
    # former universal live credential. NOPASSWD sudo is intentionally
    # limited by policy to this local-console live session; anyone who gains a
    # shell as kirat still has full root-equivalent access, so network exposure
    # or running untrusted code as this user is unsafe.
    chroot "$rootfs" useradd -m -s /bin/bash -G sudo,adm,systemd-journal kirat 2>/dev/null || true
    chroot "$rootfs" passwd -l kirat || {
        err "Failed to lock the live user's password"
        exit 1
    }

    # Configure sudo for the local live console (see network-risk note above).
    echo "kirat ALL=(ALL) NOPASSWD: ALL" > "$rootfs/etc/sudoers.d/kirat-live"
    chmod 440 "$rootfs/etc/sudoers.d/kirat-live"

    # SSH is installed for explicit post-install administration, but is never
    # enabled in the live installer. Defense in depth: reject passwords even
    # if an operator starts sshd manually.
    mkdir -p "$rootfs/etc/ssh/sshd_config.d"
    cat > "$rootfs/etc/ssh/sshd_config.d/kirat-live.conf" << 'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
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

    # DHCP networking for the live environment — without this the live
    # system boots with NO network and must be configured manually
    mkdir -p "$rootfs/etc/systemd/network"
    cat > "$rootfs/etc/systemd/network/20-dhcp.network" << 'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

    # Only networking is enabled automatically. SSH and nginx must not run in
    # the live installer; remove package-created wants links as well.
    chroot "$rootfs" systemctl enable systemd-networkd systemd-resolved 2>/dev/null || true
    local unit
    for unit in ssh.service sshd.service ssh.socket nginx.service nginx.socket; do
        chroot "$rootfs" systemctl disable "$unit" 2>/dev/null || true
    done
    rm -f "$rootfs"/etc/systemd/system/*.target.wants/ssh.service \
        "$rootfs"/etc/systemd/system/*.target.wants/sshd.service \
        "$rootfs"/etc/systemd/system/*.target.wants/ssh.socket \
        "$rootfs"/etc/systemd/system/*.target.wants/nginx.service \
        "$rootfs"/etc/systemd/system/*.target.wants/nginx.socket

    # Bulletproof fallback: chroot systemctl can silently skip units, which
    # left the v2.0.5 live env WITHOUT DHCP (found in VM rehearsal). Create
    # the wants-symlinks directly so networking is guaranteed on boot.
    mkdir -p "$rootfs/etc/systemd/system/multi-user.target.wants"
    for unit in systemd-networkd systemd-resolved; do
        for base in /usr/lib/systemd/system /lib/systemd/system; do
            if [ -e "$rootfs$base/${unit}.service" ]; then
                ln -sf "$base/${unit}.service" \
                    "$rootfs/etc/systemd/system/multi-user.target.wants/${unit}.service"
                break
            fi
        done
    done
    # DNS: systemd-resolved is NOT present in the live rootfs (its unit is
    # missing from the minbase package set — found in the v2.0.6 rehearsal
    # when the live env booted with DHCP but zero DNS). Use static public
    # resolvers; networkd still handles the interface via DHCP.
    rm -f "$rootfs/etc/resolv.conf"
    cat > "$rootfs/etc/resolv.conf" << 'EOF'
# KIRAT OS live environment — static DNS (systemd-resolved unavailable)
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    # CRITICAL: regenerate initramfs so live-boot hooks are embedded. Both the
    # regeneration command and its output artifact must succeed; never build a
    # fail-open ISO that will panic while looking for the live root filesystem.
    local module_dirs=("$rootfs"/lib/modules/*)
    local kver
    [[ -d "${module_dirs[0]}" ]] || {
        err "No kernel module directory found; cannot regenerate initramfs"
        exit 1
    }
    kver=$(basename "${module_dirs[0]}")
    if ! chroot "$rootfs" update-initramfs -u -k "$kver"; then
        warn "update-initramfs -u failed — retrying with -c for $kver"
        chroot "$rootfs" update-initramfs -c -k "$kver" || {
            err "Initramfs regeneration failed for kernel $kver"
            exit 1
        }
    fi
    [[ -s "$rootfs/boot/initrd.img-$kver" ]] || {
        err "Initramfs is missing or empty for kernel $kver"
        exit 1
    }

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
        err "install-native.sh not found at $KIRAT_OS_DIR/scripts/install-native.sh"
        exit 1
    fi

    # Copy KIRAT OS components. Never hide copy failures: an ISO without
    # these directories is bootable but cannot install a working AI stack.
    local components_dir="$rootfs/opt/kirat-os"
    mkdir -p "$components_dir"
    rsync -a \
        --exclude='.git' --exclude='.env' --exclude='.env.*' \
        --exclude='.test-venv' --exclude='venv' --exclude='__pycache__' \
        --exclude='.pytest_cache' --exclude='*.pyc' --exclude='*.pyo' \
        --exclude='*.iso' --exclude='*.tar.gz' --exclude='*.tar.gz.gpg' \
        "$KIRAT_OS_DIR/" "$components_dir/" || {
        err "Failed to copy KIRAT OS components"
        exit 1
    }
    local component
    for component in sentinel-core dashboard quantum-ai ai-agents security; do
        [[ -d "$components_dir/$component" ]] || {
            err "Required component missing from ISO rootfs: $component"
            exit 1
        }
    done
    ok "KIRAT OS components copied and verified"

    # Create installer launcher script
    cat > "$rootfs/usr/local/bin/kirat-os-install" << 'INSTALLER'
#!/bin/bash
# KIRAT OS Native Installer Launcher
# Runs from live environment to install KIRAT OS to disk

set -euo pipefail

# Resolve a mounted partition (including LVM/MD members) to its parent disk.
parent_disk() {
    local node="${1%%\[*}" type parent
    [[ "$node" == /dev/* ]] || return 1
    while :; do
        type=$(lsblk -dnro TYPE -- "$node" 2>/dev/null) || return 1
        if [[ "$type" == disk || "$type" == rom ]]; then
            printf '%s\n' "$node"
            return 0
        fi
        parent=$(lsblk -dnro PKNAME -- "$node" 2>/dev/null) || return 1
        [[ -n "$parent" ]] || return 1
        [[ "$parent" == /dev/* ]] || parent="/dev/$parent"
        node="$parent"
    done
}

# Any mounted or swap descendant makes the whole disk ineligible. This also
# protects the normal live-medium mount and all disks backing a system root.
disk_has_mounts() {
    lsblk -nrpo NAME,MOUNTPOINTS -- "$1" 2>/dev/null |
        awk 'NF > 1 { mounted=1 } END { exit mounted ? 0 : 1 }'
}

disk_is_live_or_system() {
    local disk="$1" target source mounted_disk
    for target in / /run/live/medium /lib/live/mount/medium /run/live/boot /cdrom; do
        source=$(findmnt -n -o SOURCE --target "$target" 2>/dev/null || true)
        source="${source%%$'\n'*}"
        [[ -n "$source" ]] || continue
        mounted_disk=$(parent_disk "$source" || true)
        [[ "$mounted_disk" == "$disk" ]] && return 0
    done
    return 1
}

disk_is_installable() {
    local disk="$1"
    [[ "$disk" == /dev/* ]] || return 1
    case "$disk" in /dev/loop*|/dev/zram*|/dev/fd*) return 1 ;; esac
    [[ "$(lsblk -dnro TYPE -- "$disk" 2>/dev/null)" == disk ]] || return 1
    [[ "$(lsblk -dnro RO -- "$disk" 2>/dev/null)" == 0 ]] || return 1
    disk_has_mounts "$disk" && return 1
    disk_is_live_or_system "$disk" && return 1
    return 0
}

list_installable_disks() {
    local disk type
    while read -r disk type; do
        [[ "$type" == disk ]] || continue
        disk_is_installable "$disk" && printf '%s\n' "$disk"
    done < <(lsblk -dnpo NAME,TYPE)
}

select_target_disk() {
    local candidates=() candidate requested confirmation
    DISK=""
    mapfile -t candidates < <(list_installable_disks)
    if [[ ${#candidates[@]} -eq 0 ]]; then
        echo "No safe installable disk found (live, mounted/system, optical, and read-only media excluded)."
        return 1
    fi

    echo "Eligible whole-disk targets (all other devices are excluded):"
    for candidate in "${candidates[@]}"; do
        lsblk -dno NAME,SIZE,MODEL,TRAN -- "$candidate"
    done
    echo "No disk is selected automatically."
    read -rp "Enter the full target disk path (for example /dev/sda): " requested
    for candidate in "${candidates[@]}"; do
        if [[ "$requested" == "$candidate" ]]; then
            DISK="$candidate"
            break
        fi
    done
    if [[ -z "$DISK" ]]; then
        echo "Refused: choose an exact full path from the eligible-disk list."
        return 1
    fi

    echo "WARNING: ALL DATA ON $DISK WILL BE ERASED."
    read -rp "Type the full path $DISK to confirm erasure: " confirmation
    if [[ "$confirmation" != "$DISK" ]]; then
        echo "Confirmation did not match; installation cancelled."
        DISK=""
        return 1
    fi
}

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
    1|2)
        # Both paths require an explicit eligible-disk choice and an exact
        # full-path erasure confirmation before the native installer is run.
        select_target_disk || exit 1
        sudo bash /opt/kirat-os-installer/install-native.sh --disk "$DISK"
        ;;
    3)
        echo "Dual boot is not automated yet: shrink your Windows partition"
        echo "from Windows first, then use option 2 and pick the free disk."
        ;;
    *)
        echo "Installation cancelled."
        exit 0
        ;;
esac

INSTALLER
    chmod +x "$rootfs/usr/local/bin/kirat-os-install"

    # Auto-launch hook: the GRUB "Install" entries pass kirat-install=...
    # on the kernel command line. Without this hook the flag was silently
    # ignored and every entry just booted plain live mode (found in the
    # v2.0.6 rehearsal). profile.d runs on the tty1 autologin shell.
    cat > "$rootfs/etc/profile.d/kirat-autoinstall.sh" << 'EOF'
# Auto-start the KIRAT OS installer when booted via a GRUB Install entry
if grep -q 'kirat-install=' /proc/cmdline 2>/dev/null; then
    if [ "$(tty 2>/dev/null)" = "/dev/tty1" ] && [ -z "${KIRAT_AUTOINSTALL_DONE:-}" ]; then
        export KIRAT_AUTOINSTALL_DONE=1
        echo ""
        echo "KIRAT OS installer starting (booted with kirat-install flag)..."
        sleep 2
        /usr/local/bin/kirat-os-install
    fi
fi
EOF

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

menuentry "▶ Try KIRAT OS Live (Safe Mode)" --class kirat {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "▶ Try KIRAT OS Live (Forensic Mode - No Mount)" --class kirat {
    linux /live/vmlinuz boot=live components quiet splash nomount
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

    # Require a nonempty kernel and its matching nonempty initramfs before
    # squashing. Missing boot artifacts are fatal, never a warning-only ISO.
    local kernel vmlinuz initrd kver
    local kernels=("$rootfs"/boot/vmlinuz-*)
    kernel="${kernels[0]}"
    [[ -s "$kernel" ]] || {
        err "No nonempty kernel found in $rootfs/boot; refusing to squash"
        exit 1
    }
    vmlinuz=$(basename "$kernel")
    kver="${vmlinuz#vmlinuz-}"
    initrd="$rootfs/boot/initrd.img-$kver"
    [[ -s "$initrd" ]] || {
        err "Matching initramfs is missing or empty: $initrd"
        exit 1
    }

    cp "$kernel" "$WORK_DIR/live/vmlinuz"
    cp "$initrd" "$WORK_DIR/live/initrd.img"
    [[ -s "$WORK_DIR/live/vmlinuz" && -s "$WORK_DIR/live/initrd.img" ]] || {
        err "Failed to stage required boot files"
        exit 1
    }
    ok "Kernel: $vmlinuz"
    ok "Matching initramfs copied"

    # MemTest86+ for the GRUB memory-test entry (BIOS boot only)
    if [[ -f "$rootfs/boot/memtest86+.bin" ]]; then
        cp "$rootfs/boot/memtest86+.bin" "$WORK_DIR/live/memtest86+"
        ok "MemTest86+ included"
    else
        warn "memtest86+.bin not found — GRUB memtest entry will be inert"
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
# Secure Boot strategy (debian-cd style):
#   Firmware → MS-signed shim (BOOTX64.EFI) → Debian-signed GRUB (grubx64.efi)
#            → trampoline grub.cfg in ESP → /boot/grub/grub.cfg on ISO9660
# The signed GRUB verifies the kernel through shim; Debian stock kernels are
# signed by the Debian Secure Boot CA embedded in shim, so the full chain
# passes with factory Microsoft keys. If signed binaries are missing on the
# build host we fall back to the unsigned monolithic GRUB (UEFI/BIOS boot
# still works, Secure Boot will refuse — install shim-signed +
# grub-efi-amd64-signed to fix).
stage_build_iso() {
    info "STAGE 6/6: Building bootable ISO..."

    local grub_i386="/usr/lib/grub/i386-pc"
    [[ -d "$grub_i386" ]] || { err "grub-pc-bin not installed ($grub_i386 missing)"; exit 1; }

    # ── 1. BIOS El Torito image (i386-pc, modules on ISO are fine unsigned) ──
    mkdir -p "$WORK_DIR/boot/grub/i386-pc"
    cp "$grub_i386"/*.mod "$grub_i386"/*.lst 2>/dev/null \
        "$WORK_DIR/boot/grub/i386-pc/" || true

    cat > "$WORK_DIR/efi/embed.cfg" <<'EMBEDEOF'
search --no-floppy --set=root --file /live/vmlinuz
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
EMBEDEOF

    # Modules must include everything embed.cfg uses (search, configfile)
    # plus normal (menu) and linux/linux16 (boot entries) — grub-mkimage
    # does NOT auto-resolve command->module deps; missing modules produce
    # "Unknown command" at boot (verified 2026-10-13 BIOS boot test).
    grub-mkimage -O i386-pc -d "$grub_i386" \
        -o "$WORK_DIR/efi/core.img" \
        -c "$WORK_DIR/efi/embed.cfg" \
        -p /boot/grub \
        biosdisk iso9660 search configfile normal linux linux16 \
        || { err "grub-mkimage (BIOS) failed"; exit 1; }
    cat "$grub_i386/cdboot.img" "$WORK_DIR/efi/core.img" \
        > "$WORK_DIR/boot/grub/i386-pc/eltorito.img" || { err "eltorito.img build failed"; exit 1; }
    ok "BIOS El Torito image created"

    # ── 2. ESP image (FAT) with signed shim + GRUB ──────────────────────────
    local efi_img="$WORK_DIR/efi/efiboot.img"
    dd if=/dev/zero of="$efi_img" bs=1M count=64 2>/dev/null
    mkfs.vfat "$efi_img" >/dev/null || { err "mkfs.vfat failed"; exit 1; }

    local shim="" grub="" mmx=""
    local c
    for c in /usr/lib/shim/shimx64.efi.signed /usr/lib/shim/shimx64.efi; do
        [[ -f "$c" ]] && shim="$c" && break
    done
    # GRUB flavor matters: gcdx64.efi is the CD/removable-media build
    # (what debian-cd uses). The plain grubx64.efi.signed disk flavor
    # HANGS pre-display when chainloaded from optical media — verified
    # by boot test on 2026-10-12 (plain UEFI and Secure Boot both spin
    # at 100% CPU with no console; gcdx64 boots to the menu fine).
    for c in /usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed \
             /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
             /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi; do
        [[ -f "$c" ]] && grub="$c" && break
    done
    for c in /usr/lib/shim/mmx64.efi.signed /usr/lib/shim/mmx64.efi; do
        [[ -f "$c" ]] && mmx="$c" && break
    done

    local secure_boot=false
    if [[ "$shim" == *.signed && "$grub" == *.signed ]]; then
        secure_boot=true
        ok "Signed shim + GRUB found — Secure Boot chain ENABLED"
    else
        warn "Signed shim/GRUB not found — Secure Boot will REFUSE this ISO"
        warn "Install 'shim-signed' and 'grub-efi-amd64-signed' to enable it"
        [[ -z "$grub" ]] && { err "No grubx64.efi available at all"; exit 1; }
    fi

    mmd -i "$efi_img" ::/EFI ::/EFI/BOOT || { err "mmd failed"; exit 1; }
    if [[ "$secure_boot" == true ]]; then
        mcopy -i "$efi_img" "$shim" ::/EFI/BOOT/BOOTX64.EFI
        mcopy -i "$efi_img" "$grub" ::/EFI/BOOT/grubx64.efi
    else
        mcopy -i "$efi_img" "$grub" ::/EFI/BOOT/BOOTX64.EFI
    fi
    [[ -n "$mmx" ]] && mcopy -i "$efi_img" "$mmx" ::/EFI/BOOT/mmx64.efi
    # NOTE: do NOT add fbx64.efi / BOOTX64.CSV to the ESP. When shim is
    # booted from the removable-media path and finds fbx64+CSV, it runs the
    # fallback loader which writes a NVRAM entry and RESETS the machine —
    # under OVMF (and many laptops booting USB/CD) this loops forever.
    # Verified by boot test on 2026-10-13 (minimal ISO + fbx = reset loop;
    # identical ISO without fbx boots to menu).

    # Trampoline grub.cfg: signed GRUB reads this from the ESP, then hops to
    # the real menu on the ISO9660 filesystem.
    cat > "$WORK_DIR/efi/grub.cfg.esp" <<'ESPEOF'
search --no-floppy --set=live_root --file /live/vmlinuz
set prefix=($live_root)/boot/grub
configfile ($live_root)/boot/grub/grub.cfg
ESPEOF
    mcopy -i "$efi_img" "$WORK_DIR/efi/grub.cfg.esp" ::/EFI/BOOT/grub.cfg
    ok "ESP image populated (shim chain: $secure_boot)"

    # Mirror the EFI binaries onto the ISO9660 tree (some firmwares and
    # manual copies look there; also matches previous KIRAT ISO layout).
    mkdir -p "$WORK_DIR/EFI/BOOT"
    if [[ "$secure_boot" == true ]]; then
        cp "$shim" "$WORK_DIR/EFI/BOOT/BOOTX64.EFI"
        cp "$grub" "$WORK_DIR/EFI/BOOT/grubx64.efi"
    else
        cp "$grub" "$WORK_DIR/EFI/BOOT/BOOTX64.EFI"
    fi
    [[ -n "$mmx" ]] && cp "$mmx" "$WORK_DIR/EFI/BOOT/mmx64.efi"
    # No fbx64.efi / BOOTX64.CSV here either (see ESP note above).
    cp "$WORK_DIR/efi/grub.cfg.esp" "$WORK_DIR/EFI/BOOT/grub.cfg"

    # x86_64-efi modules on the ISO so grub.cfg's insmods (gfxterm/png/...)
    # succeed when Secure Boot is off. Under SB the signed monolithic GRUB
    # has these embedded; on-disk insmod fails harmlessly (text-mode menu).
    if [[ -d /usr/lib/grub/x86_64-efi ]]; then
        mkdir -p "$WORK_DIR/boot/grub/x86_64-efi"
        cp /usr/lib/grub/x86_64-efi/*.mod /usr/lib/grub/x86_64-efi/*.lst 2>/dev/null \
            "$WORK_DIR/boot/grub/x86_64-efi/" || true
    fi

    # ── 3. Assemble hybrid ISO (BIOS + UEFI + USB) with xorriso ─────────────
    # Flag set mirrors the proven grub-mkrescue invocation that produced the
    # verified-bootable v2.0.0 ISO on this build host.
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "KIRAT-OS-${KIRAT_VERSION}" \
        --grub2-mbr "$grub_i386/boot_hybrid.img" \
        --protective-msdos-label \
        -partition_cyl_align off \
        -partition_offset 0 \
        -c boot/grub/boot.cat \
        -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e efi/efiboot.img \
        -efi-boot-part --efi-boot-image \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -isohybrid-apm-hfsplus \
        -o "$OUTPUT" \
        "$WORK_DIR" || { err "ISO build failed (xorriso)"; exit 1; }

    ok "ISO built: $OUTPUT"
    info "Size: $(du -h "$OUTPUT" | cut -f1)"
    info "Volume ID: KIRAT-OS-${KIRAT_VERSION}"

    # Sign ISO if requested
    if [[ "$SIGN_ISO" == true ]]; then
        info "Signing ISO with GPG..."
        gpg --detach-sign --armor "$OUTPUT" 2>/dev/null || warn "GPG signing failed (no key?)"
    fi

    # Generate checksums strictly; a missing checksum is a failed build.
    info "Generating checksums..."
    (cd "$(dirname "$OUTPUT")" && \
        sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" && \
        md5sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").md5") || {
        err "Checksum generation failed"
        exit 1
    }
    ok "Checksums generated"
    validate_artifacts
}

# ── Post-build Artifact Validation ──────────────────────────────────────────
validate_artifacts() {
    info "Validating ISO, boot catalog, checksum, and squashfs contents..."
    [[ -s "$OUTPUT" ]] || {
        err "ISO is missing or empty: $OUTPUT"
        exit 1
    }

    local output_dir output_name
    output_dir=$(dirname "$OUTPUT")
    output_name=$(basename "$OUTPUT")
    [[ -s "$output_dir/$output_name.sha256" ]] || {
        err "SHA-256 checksum file is missing or empty"
        exit 1
    }
    (cd "$output_dir" && sha256sum -c "$output_name.sha256") || {
        err "ISO SHA-256 verification failed"
        exit 1
    }

    local el_torito_report
    if ! el_torito_report=$(xorriso -indev "$OUTPUT" -report_el_torito plain 2>&1); then
        err "El Torito catalog report failed"
        printf '%s\n' "$el_torito_report"
        exit 1
    fi
    grep -q 'El Torito catalog' <<< "$el_torito_report" || {
        err "El Torito catalog is absent from the ISO report"
        printf '%s\n' "$el_torito_report"
        exit 1
    }
    ok "El Torito catalog report verified"

    local squash_paths required component
    local required_paths=(
        opt/kirat-os-installer/install-native.sh
        usr/local/bin/kirat-os-install
    )
    if [[ "$INCLUDE_INSTALLER" == true ]]; then
        if ! squash_paths=$(unsquashfs -ll "$WORK_DIR/live/filesystem.squashfs" |
            awk '{ path=$NF; sub(/^\.\//, "", path); sub(/^squashfs-root\//, "", path); print path }'); then
            err "Unable to list squashfs contents"
            exit 1
        fi
        for component in sentinel-core dashboard quantum-ai ai-agents security; do
            required_paths+=("opt/kirat-os/$component")
        done
        for required in "${required_paths[@]}"; do
            grep -Fxq "$required" <<< "$squash_paths" || {
                err "Required squashfs path is missing: $required"
                exit 1
            }
        done
        ok "Squashfs contains the installer and all required components"
    fi
    ok "Post-build artifact validation passed"
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
    ok "KIRAT OS PRE-RELEASE ISO BUILD COMPLETE — NOT PRODUCTION-READY!"
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
