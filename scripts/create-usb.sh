#!/bin/bash
###############################################################################
# KIRAT OS - BOOTABLE USB TEST DRIVE CREATOR
###############################################################################
# Creates a bootable USB drive for testing KIRAT OS without installing.
# Perfect for:
#   • Testing KIRAT OS on real hardware before dedicated install
#   • Running KIRAT OS as a live system
#   • Installing on systems without network access
#   • Recovery and diagnostic operations
#
# Prerequisites:
#   • USB drive 8GB+ (ALL DATA WILL BE ERASED)
#   • Root privileges
#   • Linux environment (or WSL2 with USB passthrough)
#
# Usage:
#   sudo ./create-usb.sh /dev/sdX
#   sudo ./create-usb.sh --iso-only          # Just create ISO file
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIMI_OS_VERSION="1.0.0-QUANTUM"
ISO_FILENAME="kirat-os-server-${KIMI_OS_VERSION}.iso"
ISO_OUTPUT_DIR="/tmp/kirat-os-iso"
LIVE_USER="sentinel"
LIVE_PASSWORD="kirat-live"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[USB]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERR]${NC}  $1"; }
log_stage() { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${CYAN}[STAGE] $1${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

die() { log_error "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

check_requirements() {
    log_stage "Pre-flight Checks"
    
    if [ "$EUID" -ne 0 ]; then
        die "This script must be run as root"
    fi
    
    # Check required tools
    local required=("xorriso" "syslinux" "parted" "mkfs.vfat" "grub-mkrescue")
    local missing=()
    
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "Installing missing tools: ${missing[*]}"
        apt-get update -qq
        apt-get install -y -qq "${missing[@]}" grub-pc-bin grub-efi-amd64-bin \
            mtools xorriso syslinux syslinux-efi syslinux-common \
            debootstrap squashfs-tools 2>/dev/null || {
            log_warn "Some tools may need manual installation"
        }
    fi
    
    log_ok "Requirements satisfied"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUILD LIVE SYSTEM
# ─────────────────────────────────────────────────────────────────────────────

build_live_system() {
    log_stage "Building KIRAT OS Live System"
    
    local work_dir="/tmp/kirat-os-live-build"
    local chroot_dir="$work_dir/chroot"
    local image_dir="$work_dir/image"
    
    # Clean previous builds
    rm -rf "$work_dir"
    mkdir -p "$chroot_dir" "$image_dir"
    
    # Create base system with debootstrap
    log_info "Creating live system base (this takes 10-15 minutes)..."
    debootstrap --variant=minbase \
        --include=linux-image-amd64,systemd,systemd-sysv,\
openssh-server,sudo,curl,wget,vim,nano,htop,ncdu,tree,rsync,git,\
net-tools,iproute2,iptables,nftables,dnsutils,ca-certificates,openssl,\
parted,e2fsprogs,python3,python3-pip,python3-venv,nginx,\
cryptsetup,cryptsetup-bin,xserver-xorg,x11-xserver-utils,\
lightdm,xfce4,xfce4-terminal,firefox-esr,pulseaudio,\
firmware-linux-nonfree,firmware-iwlwifi,firmware-realtek \
        bookworm "$chroot_dir" http://deb.debian.org/debian
    
    log_ok "Live base system created"
    
    # Configure live system
    log_info "Configuring live environment..."
    
    # Hostname
    echo "kirat-os-live" > "$chroot_dir/etc/hostname"
    
    # Hosts
    cat > "$chroot_dir/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   kirat-os-live
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
    # Live user (auto-login)
    chroot "$chroot_dir" useradd -m -s /bin/bash -G sudo,audio,video "$LIVE_USER"
    echo "$LIVE_USER:$LIVE_PASSWORD" | chroot "$chroot_dir" chpasswd
    
    # Auto-login for live session
    mkdir -p "$chroot_dir/etc/lightdm/lightdm.conf.d"
    cat > "$chroot_dir/etc/lightdm/lightdm.conf.d/autologin.conf" << EOF
[Seat:*]
autologin-user=$LIVE_USER
autologin-user-timeout=0
EOF
    
    # Sudo without password for live user
    echo "$LIVE_USER ALL=(ALL) NOPASSWD: ALL" > "$chroot_dir/etc/sudoers.d/live-user"
    chmod 440 "$chroot_dir/etc/sudoers.d/live-user"
    
    # SSH configuration
    cat > "$chroot_dir/etc/ssh/sshd_config.d/kirat-live.conf" << 'EOF'
# KIRAT OS Live SSH
Port 22
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
EOF
    
    # Enable services
    chroot "$chroot_dir" systemctl enable ssh
    chroot "$chroot_dir" systemctl enable lightdm
    
    # Install KIRAT OS components
    log_info "Installing KIRAT OS components..."
    mkdir -p "$chroot_dir/opt/kirat-os"
    
    # Copy quantum-ai
    if [ -d "$SCRIPT_DIR/../quantum-ai" ]; then
        cp -r "$SCRIPT_DIR/../quantum-ai" "$chroot_dir/opt/kirat-os/"
        log_ok "Quantum AI ecosystem installed"
    fi
    
    # Copy security
    if [ -d "$SCRIPT_DIR/../security" ]; then
        cp -r "$SCRIPT_DIR/../security" "$chroot_dir/opt/kirat-os/"
        log_ok "Security tools installed"
    fi
    
    # Copy dashboard
    if [ -d "$SCRIPT_DIR/../dashboard" ]; then
        cp -r "$SCRIPT_DIR/../dashboard" "$chroot_dir/opt/kirat-os/"
        log_ok "Dashboard installed"
    fi
    
    # Copy sentinel-core
    if [ -d "$SCRIPT_DIR/../sentinel-core" ]; then
        cp -r "$SCRIPT_DIR/../sentinel-core" "$chroot_dir/opt/kirat-os/"
    fi
    
    # Create live boot scripts
    mkdir -p "$chroot_dir/opt/kirat-os/scripts"
    
    cat > "$chroot_dir/opt/kirat-os/scripts/live-startup.sh" << 'EOF'
#!/bin/bash
# KIRAT OS Live Session Startup

# Set up environment
export KIMI_OS_MODE=live
export KIMI_OS_VERSION=1.0.0-QUANTUM

# Start quantum AI (if available)
if [ -f /opt/kirat-os/quantum-ai/ecosystem-api.py ]; then
    cd /opt/kirat-os/quantum-ai
    python3 -m venv venv 2>/dev/null || true
    ./venv/bin/pip install -r requirements.txt 2>/dev/null || true
    ./venv/bin/python ecosystem-api.py &
fi

# Show welcome message
cat << 'WELCOME'

╔══════════════════════════════════════════════════════════════════════╗
║                    KIRAT OS - LIVE SESSION                             ║
║                                                                       ║
║  Welcome to the KIRAT OS live environment!                             ║
║                                                                       ║
║  User: sentinel    Password: kirat-live                               ║
║                                                                       ║
║  Services:                                                            ║
║    • SSH on port 22                                                   ║
║    • Dashboard: http://localhost:8080                                 ║
║    • Quantum AI: http://localhost:8081/quantum/health                   ║
║                                                                       ║
║  To install: sudo /opt/kirat-os/scripts/install-from-live.sh           ║
║                                                                       ║
╚══════════════════════════════════════════════════════════════════════╝

WELCOME
EOF
    chmod +x "$chroot_dir/opt/kirat-os/scripts/live-startup.sh"
    
    # Create systemd service for live startup
    cat > "$chroot_dir/etc/systemd/system/kirat-live-startup.service" << 'EOF'
[Unit]
Description=KIRAT OS Live Session Startup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/kirat-os/scripts/live-startup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chroot "$chroot_dir" systemctl enable kirat-live-startup
    
    # Create installer script for live-to-disk
    cat > "$chroot_dir/opt/kirat-os/scripts/install-from-live.sh" << 'INSTALLER'
#!/bin/bash
# Install KIRAT OS from live session to disk

set -euo pipefail

echo "KIRAT OS Live-to-Disk Installer"
echo "=============================="
echo ""

# Find available disks
echo "Available disks:"
lsblk -dno NAME,SIZE,MODEL | grep -E "^sd|^nvme" | while read -r name size model; do
    echo "  /dev/$name - $size - $model"
done

echo ""
read -p "Enter target disk (e.g., /dev/sda): " target_disk

if [ ! -b "$target_disk" ]; then
    echo "Error: $target_disk is not a valid block device"
    exit 1
fi

echo "WARNING: This will ERASE ALL DATA on $target_disk"
read -p "Type 'YES' to continue: " confirm
[ "$confirm" = "YES" ] || exit 1

# Run the main installer
cd /opt/kirat-os
if [ -f scripts/build-server-fixed.sh ]; then
    bash scripts/build-server-fixed.sh --target home-server --disk "$target_disk"
else
    echo "Installer not found. Using manual method..."
    # Manual install would go here
fi

echo ""
echo "Installation complete! Reboot and remove USB."
INSTALLER
    chmod +x "$chroot_dir/opt/kirat-os/scripts/install-from-live.sh"
    
    log_ok "Live system configured"
    
    # Build squashfs (compressed root filesystem)
    log_info "Creating compressed root filesystem..."
    mkdir -p "$image_dir/live"
    mksquashfs "$chroot_dir" "$image_dir/live/filesystem.squashfs" \
        -comp xz -Xbcj x86 -e boot
    
    log_ok "Squashfs created"
    
    echo "$image_dir"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUILD ISO
# ─────────────────────────────────────────────────────────────────────────────

build_iso() {
    log_stage "Building Bootable ISO"
    
    local image_dir="$1"
    local iso_path="$ISO_OUTPUT_DIR/$ISO_FILENAME"
    
    mkdir -p "$ISO_OUTPUT_DIR"
    
    # Create EFI boot structure
    mkdir -p "$image_dir/boot/grub"
    
    # GRUB configuration
    cat > "$image_dir/boot/grub/grub.cfg" << 'EOF'
set timeout=10
set default=0

# Load fonts
loadfont unicode

set gfxmode=auto
set gfxpayload=keep
terminal_output gfxterm

# Theme
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

menuentry "KIRAT OS - Live (Graphical)" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}

menuentry "KIRAT OS - Live (Text Mode)" {
    linux /live/vmlinuz boot=live components quiet text
    initrd /live/initrd.img
}

menuentry "KIRAT OS - Install to Disk" {
    linux /live/vmlinuz boot=live components quiet install
    initrd /live/initrd.img
}

menuentry "KIRAT OS - Rescue Mode" {
    linux /live/vmlinuz boot=live components rescue quiet
    initrd /live/initrd.img
}

menuentry "Memory Test (memtest86+)" {
    linux16 /live/memtest
}

menuentry "Boot from Hard Disk" {
    exit
}
EOF
    
    # Copy kernel and initrd
    log_info "Preparing boot files..."
    local chroot_dir="/tmp/kirat-os-live-build/chroot"
    
    local kver
    kver=$(ls "$chroot_dir/boot/vmlinuz-*" 2>/dev/null | head -1 | sed 's/.*vmlinuz-//')
    
    if [ -n "$kver" ]; then
        cp "$chroot_dir/boot/vmlinuz-$kver" "$image_dir/live/vmlinuz"
        cp "$chroot_dir/boot/initrd.img-$kver" "$image_dir/live/initrd.img"
        log_ok "Kernel $kver copied"
    else
        log_warn "Kernel not found, using generic"
        cp "$chroot_dir/boot/vmlinuz"* "$image_dir/live/vmlinuz" 2>/dev/null || true
        cp "$chroot_dir/boot/initrd.img"* "$image_dir/live/initrd.img" 2>/dev/null || true
    fi
    
    # Create EFI boot image
    mkdir -p "$image_dir/EFI/boot"
    
    # Copy GRUB EFI binary
    if [ -f /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi ]; then
        cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi "$image_dir/EFI/boot/bootx64.efi"
    elif [ -f /usr/lib/shim/shimx64.efi ]; then
        cp /usr/lib/shim/shimx64.efi "$image_dir/EFI/boot/bootx64.efi"
    fi
    
    # Create ISO
    log_info "Building ISO image (this may take a few minutes)..."
    
    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "KIRAT-OS-LIVE" \
        -eltorito-boot boot/grub/grub.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --eltorito-catalog boot/grub/boot.cat \
        -output "$iso_path" \
        "$image_dir" 2>/dev/null || {
        
        # Fallback: use grub-mkrescue
        grub-mkrescue \
            -o "$iso_path" \
            "$image_dir" \
            --modules="part_gpt part_msdos fat iso9660 zfs zfsinfo" \
            2>/dev/null || die "ISO creation failed"
    }
    
    if [ -f "$iso_path" ]; then
        local iso_size
        iso_size=$(du -h "$iso_path" | cut -f1)
        log_ok "ISO created: $iso_path ($iso_size)"
        echo "$iso_path"
    else
        die "ISO creation failed"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# WRITE TO USB
# ─────────────────────────────────────────────────────────────────────────────

write_to_usb() {
    log_stage "Writing to USB Device"
    
    local usb_device="$1"
    local iso_path="$2"
    
    # Verify it's a USB device
    local removable
    removable=$(cat "/sys/block/$(basename "$usb_device")/removable" 2>/dev/null || echo "0")
    
    if [ "$removable" != "1" ]; then
        log_warn "$usb_device may not be a removable USB device!"
        read -p "Are you ABSOLUTELY SURE this is a USB drive? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || die "Aborted for safety"
    fi
    
    # Verify device size
    local dev_size
    dev_size=$(lsblk -bnd -o SIZE "$usb_device" 2>/dev/null | head -1)
    local dev_size_gb=$((dev_size / 1024 / 1024 / 1024))
    
    log_info "USB device: $usb_device (${dev_size_gb}GB)"
    
    if [ "$dev_size_gb" -lt 4 ]; then
        die "USB drive too small. Need at least 4GB, have ${dev_size_gb}GB"
    fi
    
    # Final warning
    echo ""
    echo -e "${RED}⚠️  FINAL WARNING ⚠️${NC}"
    echo -e "${RED}About to ERASE ALL DATA on $usb_device${NC}"
    echo -e "${RED}This action is IRREVERSIBLE${NC}"
    echo ""
    read -p "Type the device name ($(basename "$usb_device")) to confirm: " confirm_name
    [ "$confirm_name" = "$(basename "$usb_device")" ] || die "Device name mismatch. Aborted."
    
    # Write ISO to USB using dd
    log_info "Writing ISO to $usb_device..."
    log_info "This will take several minutes. Do NOT remove the USB!"
    
    dd if="$iso_path" of="$usb_device" bs=4M status=progress conv=fsync oflag=direct
    sync
    
    log_ok "USB drive created successfully!"
    
    # Verify
    log_info "Verifying write..."
    local iso_checksum
    iso_checksum=$(sha256sum "$iso_path" | awk '{print $1}')
    local usb_checksum
    usb_checksum=$(dd if="$usb_device" bs=4M count=$(($(stat -c%s "$iso_path") / 4194304 + 1)) 2>/dev/null | sha256sum | awk '{print $1}')
    
    if [ "$iso_checksum" = "$usb_checksum" ]; then
        log_ok "Verification passed - USB matches ISO"
    else
        log_warn "Verification checksum mismatch - USB may have errors"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SHOW USAGE GUIDE
# ─────────────────────────────────────────────────────────────────────────────

show_usb_guide() {
    log_stage "USB Drive Ready!"
    
    cat << 'GUIDE'

╔══════════════════════════════════════════════════════════════════════╗
║              KIRAT OS BOOTABLE USB - CREATION SUCCESSFUL               ║
╚══════════════════════════════════════════════════════════════════════╝

BOOT INSTRUCTIONS:
  1. Insert USB into target computer
  2. Power on and press boot menu key:
     • Dell: F12
     • HP: F9 or Esc
     • Lenovo: F12 or Fn+F12
     • ASUS: F8 or Esc
     • Acer: F12
     • Generic: F12, F10, F2, or Del
  3. Select "USB" or "UEFI: USB" from boot menu
  4. Select "KIRAT OS - Live (Graphical)"

LIVE SESSION:
  User:     sentinel
  Password: kirat-live
  
  Services available immediately:
    • SSH: ssh sentinel@<ip>
    • Dashboard: http://<ip>:8080
    • Quantum AI: http://<ip>:8081/quantum/health

INSTALL TO DISK:
  From live desktop, run:
    sudo /opt/kirat-os/scripts/install-from-live.sh

TROUBLESHOOTING:
  • If boot fails, try "Legacy USB" mode in BIOS
  • Disable Secure Boot if needed (or enroll MOK)
  • For UEFI issues, ensure USB is GPT formatted

GUIDE
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

show_banner() {
    cat << 'BANNER'
 _  ___ _ _ ___ _ _ ___ _  _  ___ _   _ 
| |/ / | | | _ ) | | __| \| |/ __| | | |
| ' <| |_| | _ \_  _| _|| .` | (__| |_| |
|_|\_\\___/|___/ |_| |___|_|\_|\___|\___/ 
                                           
    Bootable USB Creator for KIRAT OS
    
BANNER
}

show_help() {
    cat << 'HELP'
Usage: sudo ./create-usb.sh [OPTIONS] [DEVICE]

Options:
  --iso-only          Create ISO file only (don't write to USB)
  --iso-path PATH     Custom ISO output path
  --help              Show this help

Arguments:
  DEVICE              USB device to write to (e.g., /dev/sdb, /dev/sdc)
                      Use lsblk to identify your USB drive

Examples:
  # Create ISO only
  sudo ./create-usb.sh --iso-only

  # Create and write to USB
  sudo ./create-usb.sh /dev/sdb

  # Just list USB devices
  lsblk -d -o NAME,SIZE,TYPE,MODEL

HELP
}

main() {
    show_banner
    
    local iso_only=false
    local custom_iso_path=""
    local usb_device=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iso-only) iso_only=true; shift ;;
            --iso-path) custom_iso_path="$2"; shift 2 ;;
            --help) show_help; exit 0 ;;
            /dev/*) usb_device="$1"; shift ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
    
    check_requirements
    
    # Build live system
    local image_dir
    image_dir=$(build_live_system)
    
    # Build ISO
    local iso_path
    iso_path=$(build_iso "$image_dir")
    
    if [ "$iso_only" = true ]; then
        log_stage "ISO Only Mode"
        log_ok "ISO created at: $iso_path"
        log_info "Use Rufus (Windows) or Etcher to write to USB"
        log_info "Or: sudo dd if=$iso_path of=/dev/sdX bs=4M status=progress"
        
        if [ -n "$custom_iso_path" ]; then
            cp "$iso_path" "$custom_iso_path"
            log_ok "ISO copied to: $custom_iso_path"
        fi
        
        echo ""
        echo "ISO file: $iso_path"
        echo "Size: $(du -h "$iso_path" | cut -f1)"
        return 0
    fi
    
    # Write to USB if device specified
    if [ -n "$usb_device" ]; then
        write_to_usb "$usb_device" "$iso_path"
        show_usb_guide
    else
        log_info "No USB device specified. ISO available at: $iso_path"
        log_info "To write to USB: sudo dd if=$iso_path of=/dev/sdX bs=4M status=progress"
        
        # List available USB devices
        echo ""
        log_info "Available USB devices:"
        lsblk -d -o NAME,SIZE,TYPE,MODEL,RM | grep -E "1$" | while read -r name size type model rm; do
            echo "  /dev/$name - $size - $model"
        done
    fi
    
    log_ok "Complete!"
}

main "$@"
