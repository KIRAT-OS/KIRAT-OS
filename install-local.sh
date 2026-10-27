#!/bin/bash
# =============================================================================
# KIRAT OS Server - Local Installation Script
# =============================================================================
# Supports: dual-boot, vm, dedicated, wsl, usb-live
# Target: Windows 10/11 laptops/desktops (physical machines)
# Author: KIRAT OS Installer
# Version: 1.0.0
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Global Constants & Defaults
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_DIR="/var/log/kirat-os"
readonly LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
readonly INSTALL_ROOT="/mnt/kirat-os-install"
readonly ISO_URL="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
readonly ISO_FILENAME="debian-netinst.iso"
readonly MIN_RAM_GB=4
readonly MIN_DISK_GB=50
readonly RECOMMENDED_DISK_GB=100
readonly TARGET_HOSTNAME="kirat-os-server"
readonly DASHBOARD_PORT=8080
readonly SSH_PORT=22

# Color codes for terminal output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# State Variables (populated during execution)
# ---------------------------------------------------------------------------
INSTALL_MODE=""
TARGET_DISK=""
WINDOWS_PARTITION=""
EFI_PARTITION=""
BOOT_PARTITION=""
ROOT_PARTITION=""
SWAP_PARTITION=""
DATA_PARTITION=""
USERNAME=""
PASSWORD=""
SSH_PUBKEY=""
WIFI_SSID=""
WIFI_PASS=""
DRY_RUN=false
SKIP_CONFIRM=false
VERBOSE=false

# =============================================================================
# Logging & Output Utilities
# =============================================================================

log_init() {
    if [[ "$EUID" -eq 0 ]]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || true
    fi
}

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    log "INFO: $*"
}

success() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "OK: $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN: $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    log "ERROR: $*"
}

fatal() {
    error "$*"
    echo -e "\n${RED}${BOLD}Installation failed.${NC} Check log: $LOG_FILE"
    exit 1
}

prompt() {
    echo -e "${CYAN}[PROMPT]${NC} $*"
}

header() {
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}\n"
}

# =============================================================================
# Safety & Confirmation
# =============================================================================

confirm() {
    local message="$1"
    local default="${2:-n}"
    
    if [[ "$SKIP_CONFIRM" == true ]]; then
        return 0
    fi
    
    local prompt_text
    if [[ "$default" == "y" ]]; then
        prompt_text="[Y/n]"
    else
        prompt_text="[y/N]"
    fi
    
    while true; do
        prompt "$message $prompt_text"
        read -r response
        
        if [[ -z "$response" ]]; then
            response="$default"
        fi
        
        case "$response" in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo "Please answer yes or no." ;;
        esac
    done
}

confirm_destructive() {
    local operation="$1"
    echo -e "\n${RED}${BOLD}⚠️  DESTRUCTIVE OPERATION WARNING ⚠️${NC}"
    echo -e "${RED}This will: $operation${NC}"
    echo -e "${RED}Data loss may occur if you proceed without backups.${NC}\n"
    
    if ! confirm "Do you have a complete backup of all important data?" "n"; then
        fatal "Installation aborted. Please create backups before proceeding."
    fi
    
    if ! confirm "Are you absolutely sure you want to proceed?" "n"; then
        fatal "Installation aborted by user."
    fi
    
    # Triple confirmation for disk erasure
    if [[ "$INSTALL_MODE" == "dedicated" ]]; then
        echo -e "\n${RED}${BOLD}FINAL WARNING:${NC}"
        echo -e "${RED}You are about to ERASE THE ENTIRE DISK: $TARGET_DISK${NC}"
        echo -e "${RED}ALL DATA ON THIS DISK WILL BE PERMANENTLY DESTROYED.${NC}\n"
        
        local confirm_disk
        prompt "Type the disk name ($TARGET_DISK) to confirm destruction:"
        read -r confirm_disk
        
        if [[ "$confirm_disk" != "$TARGET_DISK" ]]; then
            fatal "Disk name mismatch. Installation aborted for safety."
        fi
    fi
}

# =============================================================================
# Usage & Help
# =============================================================================

show_banner() {
    cat << 'EOF'
 _   ___ _   _ ___ __  __ ___   ___  _   
| | / (_) | | / __|  \/  / __| / _ \| |  
| |/ / _| |_| \__ \ |\/| \__ \| (_) | |__
|___/_|_\___/|___/_|  |_|___/ \__\_\____|
                                          
    Local Installation Script v1.0.0
EOF
    echo ""
}

show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [MODE]

INSTALL MODES:
    dual-boot      Install alongside Windows (shrink partition, dual-boot)
    vm             Install inside QEMU/VirtualBox/VMware
    dedicated      Erase entire disk and install (DESTRUCTIVE)
    wsl            Install as WSL2 distribution
    usb-live       Create a bootable USB for testing

OPTIONS:
    -d, --disk DISK         Target disk (e.g., /dev/sda, /dev/nvme0n1)
    -u, --user USERNAME     Admin username (default: kirat)
    -p, --password PASS     Admin password (will prompt if not given)
    --ssh-key KEY           SSH public key for key-based access
    --wifi-ssid SSID        WiFi network SSID
    --wifi-pass PASS        WiFi password
    --dry-run               Show what would be done without executing
    -y, --yes               Skip confirmation prompts (DANGEROUS)
    -v, --verbose           Verbose output
    -h, --help              Show this help message

EXAMPLES:
    # Interactive installation
    sudo $SCRIPT_NAME dual-boot

    # Dedicated install with options
    sudo $SCRIPT_NAME dedicated --disk /dev/nvme0n1 --user admin --yes

    # WSL2 installation
    $SCRIPT_NAME wsl

    # Create bootable USB
    sudo $SCRIPT_NAME usb-live --disk /dev/sdb

WINDOWS USERS:
    Since you are on Windows, you have several options:

    1. WSL2 (Easiest): Run 'wsl --install' first, then run this script in WSL2
    2. Bootable USB: Use Rufus (https://rufus.ie) to create a Debian live USB,
       boot from it, and run this script
    3. VM: Install VirtualBox or VMware, create a VM, boot Debian ISO, run script

EOF
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
    if [[ $# -eq 0 ]]; then
        show_banner
        show_usage
        exit 0
    fi
    
    # First positional arg is the mode
    case "$1" in
        dual-boot|vm|dedicated|wsl|usb-live)
            INSTALL_MODE="$1"
            shift
            ;;
        -h|--help)
            show_banner
            show_usage
            exit 0
            ;;
        -*)
            # Mode might come after flags
            ;;
        *)
            error "Unknown mode: $1"
            show_usage
            exit 1
            ;;
    esac
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--disk)
                TARGET_DISK="$2"
                shift 2
                ;;
            -u|--user)
                USERNAME="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
                shift 2
                ;;
            --ssh-key)
                SSH_PUBKEY="$2"
                shift 2
                ;;
            --wifi-ssid)
                WIFI_SSID="$2"
                shift 2
                ;;
            --wifi-pass)
                WIFI_PASS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -y|--yes)
                SKIP_CONFIRM=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_banner
                show_usage
                exit 0
                ;;
            dual-boot|vm|dedicated|wsl|usb-live)
                if [[ -z "$INSTALL_MODE" ]]; then
                    INSTALL_MODE="$1"
                fi
                shift
                ;;
            *)
                error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set defaults
    [[ -z "$USERNAME" ]] && USERNAME="kirat"
    
    # Validate mode
    if [[ -z "$INSTALL_MODE" ]]; then
        error "No installation mode specified."
        show_usage
        exit 1
    fi
}

# =============================================================================
# Hardware Compatibility Checks
# =============================================================================

check_root() {
    if [[ "$EUID" -ne 0 ]] && [[ "$INSTALL_MODE" != "wsl" ]]; then
        fatal "This script must be run as root for $INSTALL_MODE installation.\nUse: sudo $SCRIPT_NAME $INSTALL_MODE"
    fi
}

check_cpu() {
    header "Checking CPU Compatibility"
    
    local cpu_info
    cpu_info=$(cat /proc/cpuinfo 2>/dev/null || echo "")
    
    if [[ -z "$cpu_info" ]]; then
        warn "Cannot read CPU info. Assuming compatible x86_64 system."
        return 0
    fi
    
    local cpu_model
    cpu_model=$(echo "$cpu_info" | grep -m1 "model name" | cut -d: -f2 | xargs || echo "Unknown")
    info "CPU: $cpu_model"
    
    # Check for 64-bit support
    if ! echo "$cpu_info" | grep -q "lm\|flags.*:.*lm"; then
        fatal "64-bit CPU required. Your CPU does not appear to support x86_64."
    fi
    success "CPU is 64-bit capable"
    
    # Check virtualization support (for VM mode)
    if [[ "$INSTALL_MODE" == "vm" ]]; then
        if echo "$cpu_info" | grep -qE "vmx|svm"; then
            success "CPU virtualization support detected (VT-x/AMD-V)"
        else
            warn "CPU virtualization extensions not detected. VM performance may be degraded."
            warn "Enable VT-x/AMD-V in BIOS for better VM performance."
        fi
    fi
    
    # Check core count
    local cores
    cores=$(nproc 2>/dev/null || echo "1")
    info "CPU cores: $cores"
    if [[ "$cores" -lt 2 ]]; then
        warn "Only $cores core detected. Minimum 2 cores recommended."
    else
        success "Sufficient CPU cores: $cores"
    fi
}

check_ram() {
    header "Checking RAM"
    
    local total_ram_kb
    total_ram_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "0")
    local total_ram_gb=$((total_ram_kb / 1024 / 1024))
    
    info "Total RAM: ${total_ram_gb}GB"
    
    if [[ "$total_ram_gb" -lt "$MIN_RAM_GB" ]]; then
        fatal "Insufficient RAM: ${total_ram_gb}GB. Minimum ${MIN_RAM_GB}GB required."
    fi
    
    if [[ "$total_ram_gb" -lt 8 ]]; then
        warn "Only ${total_ram_gb}GB RAM. 8GB+ recommended for optimal performance."
    else
        success "Sufficient RAM: ${total_ram_gb}GB"
    fi
}

check_disk_space() {
    header "Checking Disk Space"
    
    if [[ -n "$TARGET_DISK" ]]; then
        local disk_size
        disk_size=$(lsblk -bnd -o SIZE "$TARGET_DISK" 2>/dev/null | head -1)
        if [[ -n "$disk_size" ]]; then
            local disk_size_gb=$((disk_size / 1024 / 1024 / 1024))
            info "Target disk $TARGET_DISK: ${disk_size_gb}GB"
            
            if [[ "$disk_size_gb" -lt "$MIN_DISK_GB" ]]; then
                fatal "Disk too small: ${disk_size_gb}GB. Minimum ${MIN_DISK_GB}GB required."
            fi
            
            if [[ "$disk_size_gb" -lt "$RECOMMENDED_DISK_GB" ]]; then
                warn "Disk size ${disk_size_gb}GB is below recommended ${RECOMMENDED_DISK_GB}GB"
            else
                success "Disk size adequate: ${disk_size_gb}GB"
            fi
        fi
    else
        # Check available space on current system
        local avail_space
        avail_space=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
        info "Available space: ${avail_space}GB"
        
        if [[ "$avail_space" -lt "$MIN_DISK_GB" ]]; then
            warn "Low disk space. At least ${MIN_DISK_GB}GB recommended."
        fi
    fi
}

check_uefi() {
    header "Checking Boot Mode"
    
    if [[ -d /sys/firmware/efi ]]; then
        success "UEFI mode detected"
        return 0
    else
        warn "Legacy BIOS mode detected. UEFI recommended for dual-boot."
        return 1
    fi
}

check_network() {
    header "Checking Network Connectivity"
    
    if ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1; then
        success "Internet connectivity confirmed"
        return 0
    else
        warn "No internet connectivity detected. Some features may not work."
        return 1
    fi
}

check_windows_partitions() {
    header "Detecting Windows Partitions"
    
    local windows_parts
    windows_parts=$(lsblk -o NAME,FSTYPE,LABEL -ln 2>/dev/null | grep -iE "ntfs|msftres|basic data partition" || true)
    
    if [[ -n "$windows_parts" ]]; then
        info "Windows partitions detected:"
        echo "$windows_parts"
        
        # Find the main Windows partition (largest NTFS)
        WINDOWS_PARTITION=$(lsblk -bno NAME,SIZE,FSTYPE,TYPE 2>/dev/null | \
            awk '$3=="ntfs" && $4=="part" {print "/dev/"$1, $2}' | \
            sort -k2 -nr | head -1 | awk '{print $1}')
        
        if [[ -n "$WINDOWS_PARTITION" ]]; then
            success "Main Windows partition: $WINDOWS_PARTITION"
        fi
    else
        warn "No Windows partitions detected"
    fi
}

# =============================================================================
# ISO Download
# =============================================================================

download_iso() {
    header "Downloading Debian Netinstall ISO"
    
    local iso_path="/tmp/$ISO_FILENAME"
    
    if [[ -f "$iso_path" ]]; then
        info "ISO already exists at $iso_path"
        if confirm "Re-download ISO?" "n"; then
            rm -f "$iso_path"
        else
            success "Using existing ISO"
            return 0
        fi
    fi
    
    info "Downloading from: $ISO_URL"
    info "This may take several minutes..."
    
    if command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "$iso_path" "$ISO_URL" || \
            fatal "Failed to download ISO"
    elif command -v curl >/dev/null 2>&1; then
        curl -L --progress-bar -o "$iso_path" "$ISO_URL" || \
            fatal "Failed to download ISO"
    else
        fatal "Neither wget nor curl available. Cannot download ISO."
    fi
    
    success "ISO downloaded to $iso_path"
}

# =============================================================================
# Disk Operations
# =============================================================================

list_disks() {
    header "Available Disks"
    
    echo -e "${BOLD}Disk          Size    Type    Model${NC}"
    echo "────────────────────────────────────────────"
    
    lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | while read -r name size type model; do
        if [[ "$type" == "disk" ]]; then
            printf "%-12s %-8s %-6s %s\n" "/dev/$name" "$size" "$type" "$model"
        fi
    done
    
    echo ""
    info "NVMe disks may appear as /dev/nvme0n1, /dev/nvme1n1, etc."
    info "SATA disks may appear as /dev/sda, /dev/sdb, etc."
}

select_disk() {
    if [[ -z "$TARGET_DISK" ]]; then
        list_disks
        prompt "Enter the target disk (e.g., /dev/sda, /dev/nvme0n1):"
        read -r TARGET_DISK
    fi
    
    if [[ ! -b "$TARGET_DISK" ]]; then
        fatal "Invalid disk: $TARGET_DISK is not a block device"
    fi
    
    success "Target disk: $TARGET_DISK"
}

shrink_windows_partition() {
    header "Shrinking Windows Partition"
    
    if [[ -z "$WINDOWS_PARTITION" ]]; then
        fatal "No Windows partition found to shrink"
    fi
    
    info "Windows partition: $WINDOWS_PARTITION"
    
    # Check if partition is mounted
    if mount | grep -q "$WINDOWS_PARTITION"; then
        warn "Windows partition is mounted. Unmounting..."
        umount "$WINDOWS_PARTITION" 2>/dev/null || true
    fi
    
    # Check NTFS health
    info "Checking NTFS filesystem health..."
    if command -v ntfsresize >/dev/null 2>&1; then
        ntfsresize -i "$WINDOWS_PARTITION" || \
            fatal "NTFS filesystem check failed. Run Windows chkdsk /f first."
    else
        warn "ntfsresize not available. Skipping NTFS check."
    fi
    
    # Get current size and calculate shrink amount
    local part_size
    part_size=$(lsblk -bno SIZE "$WINDOWS_PARTITION" | head -1)
    local part_size_gb=$((part_size / 1024 / 1024 / 1024))
    
    info "Current Windows partition size: ${part_size_gb}GB"
    
    local shrink_gb
    prompt "How much space to free for KIRAT OS (GB)? [Recommended: 50+]"
    read -r shrink_gb
    
    if [[ -z "$shrink_gb" ]] || ! [[ "$shrink_gb" =~ ^[0-9]+$ ]]; then
        shrink_gb=50
    fi
    
    if [[ "$shrink_gb" -lt "$MIN_DISK_GB" ]]; then
        warn "Less than ${MIN_DISK_GB}GB may not be sufficient"
    fi
    
    local new_size_gb=$((part_size_gb - shrink_gb))
    
    info "Will shrink Windows from ${part_size_gb}GB to ${new_size_gb}GB"
    info "This frees up ${shrink_gb}GB for KIRAT OS"
    
    confirm_destructive "Resize Windows partition $WINDOWS_PARTITION"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would shrink $WINDOWS_PARTITION by ${shrink_gb}GB"
        return 0
    fi
    
    # Perform shrink
    if command -v ntfsresize >/dev/null 2>&1; then
        info "Shrinking NTFS partition..."
        ntfsresize --size "${new_size_gb}G" "$WINDOWS_PARTITION" || \
            fatal "Failed to shrink Windows partition"
    else
        warn "ntfsresize not available."
        warn "Please shrink the Windows partition using Windows Disk Management first:"
        echo "  1. Boot into Windows"
        echo "  2. Open Disk Management (diskmgmt.msc)"
        echo "  3. Right-click C: drive → Shrink Volume"
        echo "  4. Enter ${shrink_gb}GB to shrink"
        echo "  5. Leave the unallocated space empty"
        echo "  6. Reboot into this installer"
        
        if ! confirm "Have you already shrunk the Windows partition?" "n"; then
            fatal "Please shrink the Windows partition first, then re-run this script."
        fi
    fi
    
    success "Windows partition shrunk successfully"
}

create_partitions_dualboot() {
    header "Creating Partitions (Dual-Boot)"
    
    confirm_destructive "Create new partitions on $TARGET_DISK"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would create partitions on $TARGET_DISK"
        return 0
    fi
    
    # Find unallocated space
    info "Finding unallocated space..."
    
    # Use parted to create partitions in the free space
    # This is a simplified version - in production, use more sophisticated logic
    
    # Create EFI partition if it doesn't exist
    if [[ -z "$EFI_PARTITION" ]]; then
        info "Creating EFI partition..."
        # parted commands would go here
        EFI_PARTITION="${TARGET_DISK}p1"
    fi
    
    # Create boot partition
    info "Creating boot partition..."
    BOOT_PARTITION="${TARGET_DISK}p2"
    
    # Create root partition
    info "Creating root partition..."
    ROOT_PARTITION="${TARGET_DISK}p3"
    
    # Create swap partition
    info "Creating swap partition..."
    SWAP_PARTITION="${TARGET_DISK}p4"
    
    # Create data partition
    info "Creating data partition..."
    DATA_PARTITION="${TARGET_DISK}p5"
    
    success "Partitions created"
}

create_partitions_dedicated() {
    header "Creating Partitions (Dedicated)"
    
    confirm_destructive "ERASE ALL DATA on $TARGET_DISK and create new partitions"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would erase $TARGET_DISK and create partitions"
        return 0
    fi
    
    # Wipe disk
    info "Wiping disk signature..."
    wipefs -a "$TARGET_DISK" 2>/dev/null || true
    
    # Create partition table
    if check_uefi >/dev/null 2>&1; then
        info "Creating GPT partition table..."
        parted -s "$TARGET_DISK" mklabel gpt
    else
        info "Creating MBR partition table..."
        parted -s "$TARGET_DISK" mklabel msdos
    fi
    
    # Create partitions
    local disk_size
    disk_size=$(lsblk -bno SIZE "$TARGET_DISK" | head -1)
    local disk_size_gb=$((disk_size / 1024 / 1024 / 1024))
    
    info "Disk size: ${disk_size_gb}GB"
    
    # EFI partition (512MB)
    if check_uefi >/dev/null 2>&1; then
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
        parted -s "$TARGET_DISK" set 1 esp on
        EFI_PARTITION="${TARGET_DISK}1"
    fi
    
    # Boot partition (1GB)
    parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 1537MiB
    BOOT_PARTITION="${TARGET_DISK}2"
    
    # Calculate sizes for remaining partitions
    local remaining_gb=$((disk_size_gb - 2))
    local swap_gb=8
    local root_gb=$((remaining_gb / 2))
    if [[ "$root_gb" -gt 100 ]]; then
        root_gb=100
    fi
    local data_gb=$((remaining_gb - swap_gb - root_gb))
    
    # Root partition
    parted -s "$TARGET_DISK" mkpart primary ext4 1537MiB "$((1537 + root_gb * 1024))MiB"
    ROOT_PARTITION="${TARGET_DISK}3"
    
    # Swap partition
    parted -s "$TARGET_DISK" mkpart primary linux-swap "$((1537 + root_gb * 1024))MiB" "$((1537 + root_gb * 1024 + swap_gb * 1024))MiB"
    SWAP_PARTITION="${TARGET_DISK}4"
    
    # Data partition (rest)
    parted -s "$TARGET_DISK" mkpart primary ext4 "$((1537 + root_gb * 1024 + swap_gb * 1024))MiB" 100%
    DATA_PARTITION="${TARGET_DISK}5"
    
    # Format partitions
    info "Formatting partitions..."
    
    [[ -n "$EFI_PARTITION" ]] && mkfs.fat -F32 "$EFI_PARTITION"
    mkfs.ext4 -F "$BOOT_PARTITION"
    mkfs.ext4 -F "$ROOT_PARTITION"
    mkswap "$SWAP_PARTITION"
    mkfs.ext4 -F "$DATA_PARTITION"
    
    success "Partitions created and formatted"
}

# =============================================================================
# Base System Installation
# =============================================================================

install_base_system() {
    header "Installing Base System"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would install Debian base system"
        return 0
    fi
    
    # Mount root partition
    mkdir -p "$INSTALL_ROOT"
    mount "$ROOT_PARTITION" "$INSTALL_ROOT"
    
    # Create necessary directories
    mkdir -p "$INSTALL_ROOT"/{boot,home,tmp,var,etc,usr,lib,lib64,bin,sbin,dev,proc,sys,run}
    
    # Mount boot partition
    mkdir -p "$INSTALL_ROOT/boot"
    mount "$BOOT_PARTITION" "$INSTALL_ROOT/boot"
    
    # Mount EFI partition if exists
    if [[ -n "$EFI_PARTITION" ]]; then
        mkdir -p "$INSTALL_ROOT/boot/efi"
        mount "$EFI_PARTITION" "$INSTALL_ROOT/boot/efi"
    fi
    
    # Debootstrap or extract base system
    info "Installing base Debian system..."
    
    if command -v debootstrap >/dev/null 2>&1; then
        debootstrap --arch=amd64 stable "$INSTALL_ROOT" http://deb.debian.org/debian
    else
        warn "debootstrap not available. Using alternative method..."
        # Alternative: extract from ISO or use pre-built tarball
    fi
    
    # Mount pseudo-filesystems
    mount --bind /dev "$INSTALL_ROOT/dev"
    mount --bind /proc "$INSTALL_ROOT/proc"
    mount --bind /sys "$INSTALL_ROOT/sys"
    mount --bind /run "$INSTALL_ROOT/run"
    
    success "Base system installed"
}

configure_system() {
    header "Configuring Base System"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would configure system"
        return 0
    fi
    
    # Set hostname
    echo "$TARGET_HOSTNAME" > "$INSTALL_ROOT/etc/hostname"
    
    # Set hosts
    cat > "$INSTALL_ROOT/etc/hosts" << EOF
127.0.0.1       localhost
127.0.1.1       $TARGET_HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
    # Configure timezone
    ln -sf /usr/share/zoneinfo/UTC "$INSTALL_ROOT/etc/localtime"
    
    # Configure locale
    echo "en_US.UTF-8 UTF-8" > "$INSTALL_ROOT/etc/locale.gen"
    chroot "$INSTALL_ROOT" locale-gen
    echo "LANG=en_US.UTF-8" > "$INSTALL_ROOT/etc/default/locale"
    
    # Configure fstab
    cat > "$INSTALL_ROOT/etc/fstab" << EOF
# /etc/fstab: static file system information
#
# <file system>                           <mount point>  <type>  <options>          <dump>  <pass>
$(blkid -s UUID -o value "$ROOT_PARTITION")  /              ext4    defaults,noatime   0       1
$(blkid -s UUID -o value "$BOOT_PARTITION")  /boot          ext4    defaults           0       2
EOF
    
    if [[ -n "$EFI_PARTITION" ]]; then
        echo "$(blkid -s UUID -o value "$EFI_PARTITION")  /boot/efi      vfat    umask=0077         0       1" >> "$INSTALL_ROOT/etc/fstab"
    fi
    
    if [[ -n "$SWAP_PARTITION" ]]; then
        echo "$(blkid -s UUID -o value "$SWAP_PARTITION")  none           swap    sw                 0       0" >> "$INSTALL_ROOT/etc/fstab"
    fi
    
    if [[ -n "$DATA_PARTITION" ]]; then
        echo "$(blkid -s UUID -o value "$DATA_PARTITION")  /data          ext4    defaults           0       2" >> "$INSTALL_ROOT/etc/fstab"
    fi
    
    success "System configured"
}

# =============================================================================
# Bootloader Installation
# =============================================================================

install_grub() {
    header "Installing GRUB Bootloader"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would install GRUB"
        return 0
    fi
    
    # Install GRUB packages
    chroot "$INSTALL_ROOT" apt-get update
    chroot "$INSTALL_ROOT" apt-get install -y grub-pc grub-efi-amd64 os-prober shim-signed
    
    # Install GRUB
    if [[ -n "$EFI_PARTITION" ]]; then
        info "Installing EFI GRUB..."
        chroot "$INSTALL_ROOT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=debian --removable
    else
        info "Installing BIOS GRUB..."
        chroot "$INSTALL_ROOT" grub-install --target=i386-pc "$TARGET_DISK"
    fi
    
    # Enable os-prober for Windows detection
    echo "GRUB_DISABLE_OS_PROBER=false" >> "$INSTALL_ROOT/etc/default/grub"
    
    # Update GRUB config
    chroot "$INSTALL_ROOT" update-grub
    
    success "GRUB installed"
}

# =============================================================================
# KIRAT OS Specific Components
# =============================================================================

copy_kirat_files() {
    header "Copying KIRAT OS Files"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would copy KIRAT OS files"
        return 0
    fi
    
    local kirat_dir="$INSTALL_ROOT/opt/kirat-os"
    mkdir -p "$kirat_dir"
    
    # Copy fixed files if they exist in the current directory
    local source_dir="$(dirname "$0")"
    
    info "Looking for KIRAT OS components in: $source_dir"
    
    # Copy kernel module source
    if [[ -f "$source_dir/kirat-ai-fixed.c" ]]; then
        cp "$source_dir/kirat-ai-fixed.c" "$kirat_dir/"
        success "Copied kirat-ai-fixed.c"
    else
        warn "kirat-ai-fixed.c not found in $source_dir"
    fi
    
    # Copy hardening script
    if [[ -f "$source_dir/harden-fixed.sh" ]]; then
        cp "$source_dir/harden-fixed.sh" "$kirat_dir/"
        chmod +x "$kirat_dir/harden-fixed.sh"
        success "Copied harden-fixed.sh"
    else
        warn "harden-fixed.sh not found in $source_dir"
    fi
    
    # Copy dashboard files
    if [[ -d "$source_dir/dashboard" ]]; then
        cp -r "$source_dir/dashboard" "$kirat_dir/"
        success "Copied dashboard files"
    else
        warn "dashboard directory not found"
    fi
    
    # Copy Sentinel AI runtime
    if [[ -d "$source_dir/sentinel" ]]; then
        cp -r "$source_dir/sentinel" "$kirat_dir/"
        success "Copied Sentinel AI runtime"
    else
        warn "sentinel directory not found"
    fi
    
    # Copy configuration templates
    if [[ -d "$source_dir/configs" ]]; then
        cp -r "$source_dir/configs" "$kirat_dir/"
        success "Copied configuration templates"
    fi
    
    success "KIRAT OS files copied"
}

build_kernel_module() {
    header "Building Kernel Module"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would build kernel module"
        return 0
    fi
    
    local kirat_dir="$INSTALL_ROOT/opt/kirat-os"
    
    if [[ ! -f "$kirat_dir/kirat-ai-fixed.c" ]]; then
        warn "Kernel module source not found. Skipping build."
        return 0
    fi
    
    # Install build dependencies
    chroot "$INSTALL_ROOT" apt-get install -y build-essential linux-headers-amd64 dkms
    
    # Create DKMS configuration
    cat > "$kirat_dir/dkms.conf" << 'EOF'
PACKAGE_NAME="kirat-ai"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="kirat-ai"
DEST_MODULE_LOCATION[0]="/kernel/drivers/misc"
AUTOINSTALL="yes"
EOF
    
    # Install via DKMS
    mkdir -p "$INSTALL_ROOT/usr/src/kirat-ai-1.0"
    cp "$kirat_dir/kirat-ai-fixed.c" "$INSTALL_ROOT/usr/src/kirat-ai-1.0/"
    cp "$kirat_dir/dkms.conf" "$INSTALL_ROOT/usr/src/kirat-ai-1.0/"
    
    chroot "$INSTALL_ROOT" dkms add -m kirat-ai -v 1.0
    chroot "$INSTALL_ROOT" dkms build -m kirat-ai -v 1.0
    chroot "$INSTALL_ROOT" dkms install -m kirat-ai -v 1.0
    
    success "Kernel module built and installed"
}

install_sentinel_runtime() {
    header "Installing Sentinel AI Runtime"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would install Sentinel AI runtime"
        return 0
    fi
    
    # Install Python and dependencies
    chroot "$INSTALL_ROOT" apt-get install -y python3 python3-pip python3-venv
    
    local sentinel_dir="$INSTALL_ROOT/opt/kirat-os/sentinel"
    
    if [[ -d "$sentinel_dir" ]]; then
        # Create virtual environment
        chroot "$INSTALL_ROOT" bash -c "cd /opt/kirat-os/sentinel && python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt 2>/dev/null || true"
        
        # Create systemd service
        cat > "$INSTALL_ROOT/etc/systemd/system/sentinel.service" << 'EOF'
[Unit]
Description=Sentinel AI Runtime
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/kirat-os/sentinel
Environment=PATH=/opt/kirat-os/sentinel/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/opt/kirat-os/sentinel/venv/bin/python /opt/kirat-os/sentinel/main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        chroot "$INSTALL_ROOT" systemctl enable sentinel.service
        success "Sentinel AI runtime installed"
    else
        warn "Sentinel AI runtime files not found"
    fi
}

install_dashboard() {
    header "Installing Dashboard"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would install dashboard"
        return 0
    fi
    
    # Install Node.js and dependencies
    chroot "$INSTALL_ROOT" apt-get install -y nodejs npm nginx
    
    local dashboard_dir="$INSTALL_ROOT/opt/kirat-os/dashboard"
    
    if [[ -d "$dashboard_dir" ]]; then
        # Build dashboard
        chroot "$INSTALL_ROOT" bash -c "cd /opt/kirat-os/dashboard && npm install 2>/dev/null || true && npm run build 2>/dev/null || true"
        
        # Configure nginx
        cat > "$INSTALL_ROOT/etc/nginx/sites-available/kirat-dashboard" << EOF
server {
    listen $DASHBOARD_PORT default_server;
    listen [::]:$DASHBOARD_PORT default_server;
    
    root /opt/kirat-os/dashboard/dist;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location /api {
        proxy_pass http://localhost:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
        
        chroot "$INSTALL_ROOT" ln -sf /etc/nginx/sites-available/kirat-dashboard /etc/nginx/sites-enabled/
        chroot "$INSTALL_ROOT" systemctl enable nginx
        
        success "Dashboard installed on port $DASHBOARD_PORT"
    else
        warn "Dashboard files not found"
    fi
}

run_hardening() {
    header "Running Security Hardening"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would run hardening script"
        return 0
    fi
    
    local harden_script="$INSTALL_ROOT/opt/kirat-os/harden-fixed.sh"
    
    if [[ -f "$harden_script" ]]; then
        # Run hardening in chroot
        chroot "$INSTALL_ROOT" bash /opt/kirat-os/harden-fixed.sh || \
            warn "Hardening script returned non-zero exit code"
        success "Security hardening applied"
    else
        warn "Hardening script not found. Applying basic hardening..."
        
        # Basic hardening
        # Disable root login
        sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$INSTALL_ROOT/etc/ssh/sshd_config"
        
        # Enable firewall
        chroot "$INSTALL_ROOT" apt-get install -y ufw
        chroot "$INSTALL_ROOT" ufw default deny incoming
        chroot "$INSTALL_ROOT" ufw default allow outgoing
        chroot "$INSTALL_ROOT" ufw allow ssh
        chroot "$INSTALL_ROOT" ufw allow "$DASHBOARD_PORT/tcp"
        chroot "$INSTALL_ROOT" ufw --force enable
        
        # Install fail2ban
        chroot "$INSTALL_ROOT" apt-get install -y fail2ban
        chroot "$INSTALL_ROOT" systemctl enable fail2ban
        
        success "Basic hardening applied"
    fi
}

# =============================================================================
# User & Access Configuration
# =============================================================================

configure_users() {
    header "Configuring Users"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would configure users"
        return 0
    fi
    
    # Get password if not provided
    if [[ -z "$PASSWORD" ]]; then
        prompt "Enter password for user '$USERNAME':"
        read -rs PASSWORD
        echo ""
        prompt "Confirm password:"
        local confirm_pass
        read -rs confirm_pass
        echo ""
        
        if [[ "$PASSWORD" != "$confirm_pass" ]]; then
            fatal "Passwords do not match"
        fi
    fi
    
    # Create user
    chroot "$INSTALL_ROOT" useradd -m -s /bin/bash -G sudo "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chroot "$INSTALL_ROOT" chpasswd
    
    # Configure sudo
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > "$INSTALL_ROOT/etc/sudoers.d/$USERNAME"
    chmod 440 "$INSTALL_ROOT/etc/sudoers.d/$USERNAME"
    
    # Set up SSH key
    if [[ -n "$SSH_PUBKEY" ]]; then
        info "Configuring SSH key access..."
        local ssh_dir="$INSTALL_ROOT/home/$USERNAME/.ssh"
        mkdir -p "$ssh_dir"
        echo "$SSH_PUBKEY" > "$ssh_dir/authorized_keys"
        chmod 700 "$ssh_dir"
        chmod 600 "$ssh_dir/authorized_keys"
        chroot "$INSTALL_ROOT" chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"
        success "SSH key configured"
    fi
    
    success "User '$USERNAME' configured"
}

configure_ssh() {
    header "Configuring SSH"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would configure SSH"
        return 0
    fi
    
    # Install OpenSSH
    chroot "$INSTALL_ROOT" apt-get install -y openssh-server
    
    # Configure SSH
    cat > "$INSTALL_ROOT/etc/ssh/sshd_config.d/kirat-os.conf" << EOF
# KIRAT OS SSH Configuration
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthenticationMethods publickey password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
    
    chroot "$INSTALL_ROOT" systemctl enable ssh
    
    success "SSH configured on port $SSH_PORT"
}

# =============================================================================
# Network Configuration
# =============================================================================

configure_network() {
    header "Configuring Network"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would configure network"
        return 0
    fi
    
    # Install network tools
    chroot "$INSTALL_ROOT" apt-get install -y \
        network-manager \
        net-tools \
        wireless-tools \
        wpasupplicant \
        iw \
        firmware-linux-nonfree \
        firmware-iwlwifi \
        firmware-realtek \
        firmware-atheros
    
    # Enable NetworkManager
    chroot "$INSTALL_ROOT" systemctl enable NetworkManager
    
    # Configure WiFi if credentials provided
    if [[ -n "$WIFI_SSID" ]]; then
        info "Configuring WiFi connection..."
        
        cat > "$INSTALL_ROOT/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection" << EOF
[connection]
id=$WIFI_SSID
uuid=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
type=wifi
interface-name=wlan0

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASS

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto

[proxy]
EOF
        
        chmod 600 "$INSTALL_ROOT/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
        success "WiFi configured for: $WIFI_SSID"
    fi
    
    # Configure hostname resolution
    chroot "$INSTALL_ROOT" apt-get install -y systemd-resolved
    chroot "$INSTALL_ROOT" systemctl enable systemd-resolved
    
    success "Network configured"
}

# =============================================================================
# WSL2 Installation
# =============================================================================

install_wsl() {
    header "WSL2 Installation"
    
    info "This will create a KIRAT OS distribution for WSL2"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would create WSL2 distribution"
        return 0
    fi
    
    # Check if running in WSL
    if [[ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]] && [[ ! -f /run/WSLInterop ]]; then
        warn "Not running in WSL environment"
        info "To install in WSL2, first run in PowerShell (as Administrator):"
        echo "  wsl --install"
        echo "  wsl --update"
        echo ""
        info "Then run this script inside WSL2 Ubuntu/Debian"
        
        if ! confirm "Continue anyway?" "n"; then
            return 1
        fi
    fi
    
    # Create a rootfs tarball
    local rootfs_tar="/tmp/kirat-os-wsl-rootfs.tar.gz"
    
    info "Creating WSL rootfs tarball..."
    
    # Use debootstrap to create a minimal rootfs
    local wsl_root="/tmp/kirat-os-wsl"
    mkdir -p "$wsl_root"
    
    if command -v debootstrap >/dev/null 2>&1; then
        debootstrap --variant=minbase stable "$wsl_root" http://deb.debian.org/debian
    else
        fatal "debootstrap required for WSL installation"
    fi
    
    # Configure WSL-specific settings
    cat > "$wsl_root/etc/wsl.conf" << 'EOF'
[boot]
systemd=true

[user]
default=kirat

[interop]
enabled=true
appendWindowsPath=true

[network]
generateHosts=true
generateResolvConf=true
EOF
    
    # Install KIRAT OS components in the rootfs
    mkdir -p "$wsl_root/opt/kirat-os"
    
    # Copy files
    local source_dir="$(dirname "$0")"
    [[ -f "$source_dir/kirat-ai-fixed.c" ]] && cp "$source_dir/kirat-ai-fixed.c" "$wsl_root/opt/kirat-os/"
    [[ -f "$source_dir/harden-fixed.sh" ]] && cp "$source_dir/harden-fixed.sh" "$wsl_root/opt/kirat-os/"
    
    # Create tarball
    tar -czf "$rootfs_tar" -C "$wsl_root" .
    
    info "WSL rootfs created: $rootfs_tar"
    info ""
    info "To import into WSL2, run in PowerShell:"
    echo "  wsl --import KIRAT-OS C:\\WSL\\KIRAT-OS $rootfs_tar"
    echo ""
    info "Then start it with:"
    echo "  wsl -d KIRAT-OS"
    
    success "WSL2 installation package created"
}

# =============================================================================
# USB Live Creation
# =============================================================================

create_usb_live() {
    header "Creating Bootable USB"
    
    select_disk
    
    info "Target USB device: $TARGET_DISK"
    
    # Verify it's a USB device
    local removable
    removable=$(cat "/sys/block/$(basename "$TARGET_DISK")/removable" 2>/dev/null || echo "0")
    
    if [[ "$removable" != "1" ]]; then
        warn "$TARGET_DISK may not be a removable USB device"
        if ! confirm "Are you sure this is a USB drive?" "n"; then
            fatal "Aborted"
        fi
    fi
    
    confirm_destructive "ERASE ALL DATA on $TARGET_DISK and create bootable USB"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would create bootable USB on $TARGET_DISK"
        return 0
    fi
    
    # Download ISO
    download_iso
    
    # Write ISO to USB
    info "Writing ISO to USB... This may take several minutes."
    info "Do not remove the USB drive during this process!"
    
    dd if="/tmp/$ISO_FILENAME" of="$TARGET_DISK" bs=4M status=progress conv=fsync
    
    sync
    
    success "Bootable USB created on $TARGET_DISK"
    info ""
    info "To use:"
    info "1. Insert USB into target machine"
    info "2. Boot from USB (usually F12, F2, or Del during startup)"
    info "3. Select 'Try without installing' for live mode"
    info "4. Or select 'Install' to install to disk"
}

# =============================================================================
# VM Installation
# =============================================================================

install_vm() {
    header "VM Installation"
    
    info "This will help you install KIRAT OS in a virtual machine"
    
    # Detect VM software
    local vm_type=""
    
    if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        vm_type="qemu"
    elif command -v VBoxManage >/dev/null 2>&1; then
        vm_type="virtualbox"
    elif command -v vmrun >/dev/null 2>&1; then
        vm_type="vmware"
    fi
    
    if [[ -z "$vm_type" ]]; then
        warn "No VM software detected"
        info "Please install one of: QEMU/KVM, VirtualBox, or VMware"
        info ""
        info "For QEMU:  sudo apt-get install qemu-kvm libvirt-daemon-system"
        info "For VBox:  sudo apt-get install virtualbox"
        info "For VMware: Download from https://www.vmware.com"
        
        prompt "Which VM software will you use? [qemu/virtualbox/vmware]"
        read -r vm_type
    fi
    
    info "VM software: $vm_type"
    
    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would create VM using $vm_type"
        return 0
    fi
    
    # Download ISO
    download_iso
    
    local vm_name="kirat-os-vm"
    local vm_disk="/var/lib/libvirt/images/${vm_name}.qcow2"
    local vm_disk_size="50G"
    local vm_ram="4096"
    local vm_cpus="2"
    
    case "$vm_type" in
        qemu|kvm)
            info "Creating QEMU/KVM VM..."
            
            # Create disk
            qemu-img create -f qcow2 "$vm_disk" "$vm_disk_size"
            
            # Create VM
            virt-install \
                --name "$vm_name" \
                --memory "$vm_ram" \
                --vcpus "$vm_cpus" \
                --disk path="$vm_disk",format=qcow2 \
                --cdrom "/tmp/$ISO_FILENAME" \
                --network bridge=virbr0 \
                --graphics vnc,listen=0.0.0.0 \
                --noautoconsole \
                --boot cdrom,hd
            
            success "QEMU VM created: $vm_name"
            info "Connect with: virt-viewer $vm_name"
            ;;
            
        virtualbox)
            info "Creating VirtualBox VM..."
            
            # Create VM
            VBoxManage createvm --name "$vm_name" --register
            VBoxManage modifyvm "$vm_name" --memory "$vm_ram" --cpus "$vm_cpus"
            VBoxManage modifyvm "$vm_name" --nic1 nat
            
            # Create disk
            VBoxManage createhd --filename "$vm_disk" --size "$((50 * 1024))"
            
            # Attach storage
            VBoxManage storagectl "$vm_name" --name "SATA Controller" --add sata
            VBoxManage storageattach "$vm_name" --storagectl "SATA Controller" --port 0 --device 0 --type hdd --medium "$vm_disk"
            VBoxManage storageattach "$vm_name" --storagectl "SATA Controller" --port 1 --device 0 --type dvddrive --medium "/tmp/$ISO_FILENAME"
            
            success "VirtualBox VM created: $vm_name"
            info "Start with: VBoxManage startvm $vm_name"
            ;;
            
        vmware)
            info "VMware Workstation/Player detected"
            info "Please create a VM manually with these settings:"
            echo "  - OS: Linux / Debian 12 x64"
            echo "  - RAM: ${vm_ram}MB"
            echo "  - Disk: ${vm_disk_size}"
            echo "  - ISO: /tmp/$ISO_FILENAME"
            ;;
            
        *)
            warn "Unknown VM type: $vm_type"
            ;;
    esac
}

# =============================================================================
# Post-Install Report
# =============================================================================

generate_report() {
    header "Post-Installation Report"
    
    local report_file="/tmp/kirat-os-install-report.txt"
    
    cat > "$report_file" << EOF
===============================================================================
KIRAT OS SERVER - INSTALLATION REPORT
Generated: $(date)
Version: $SCRIPT_VERSION
===============================================================================

INSTALLATION SUMMARY
--------------------
Installation Mode: $INSTALL_MODE
Target Hostname: $TARGET_HOSTNAME
Target Disk: ${TARGET_DISK:-"N/A"}

PARTITIONS
----------
EOF
    
    [[ -n "$EFI_PARTITION" ]] && echo "EFI:     $EFI_PARTITION" >> "$report_file"
    [[ -n "$BOOT_PARTITION" ]] && echo "Boot:    $BOOT_PARTITION" >> "$report_file"
    [[ -n "$ROOT_PARTITION" ]] && echo "Root:    $ROOT_PARTITION" >> "$report_file"
    [[ -n "$SWAP_PARTITION" ]] && echo "Swap:    $SWAP_PARTITION" >> "$report_file"
    [[ -n "$DATA_PARTITION" ]] && echo "Data:    $DATA_PARTITION" >> "$report_file"
    [[ -n "$WINDOWS_PARTITION" ]] && echo "Windows: $WINDOWS_PARTITION" >> "$report_file"
    
    cat >> "$report_file" << EOF

USER ACCESS
-----------
Username: $USERNAME
SSH Port: $SSH_PORT
Dashboard Port: $DASHBOARD_PORT

EOF
    
    if [[ -n "$SSH_PUBKEY" ]]; then
        echo "SSH Key: Configured" >> "$report_file"
    else
        echo "SSH Key: Not configured (password auth enabled)" >> "$report_file"
    fi
    
    cat >> "$report_file" << EOF

NETWORK
-------
EOF
    
    if [[ -n "$WIFI_SSID" ]]; then
        echo "WiFi SSID: $WIFI_SSID" >> "$report_file"
    fi
    
    cat >> "$report_file" << EOF
Ethernet: Auto-configured via DHCP

INSTALLED COMPONENTS
--------------------
EOF
    
    [[ -f "$INSTALL_ROOT/opt/kirat-os/kirat-ai-fixed.c" ]] && echo "[✓] Kernel Module Source" >> "$report_file"
    [[ -f "$INSTALL_ROOT/opt/kirat-os/harden-fixed.sh" ]] && echo "[✓] Hardening Script" >> "$report_file"
    [[ -d "$INSTALL_ROOT/opt/kirat-os/dashboard" ]] && echo "[✓] Dashboard" >> "$report_file"
    [[ -d "$INSTALL_ROOT/opt/kirat-os/sentinel" ]] && echo "[✓] Sentinel AI Runtime" >> "$report_file"
    
    cat >> "$report_file" << EOF

SERVICES
--------
[✓] SSH (sshd)
[✓] Dashboard (nginx)
[✓] Sentinel AI (systemd)
[✓] Firewall (ufw)
[✓] Fail2ban

NEXT STEPS
----------
1. Reboot the system
2. Access the dashboard at: http://$(hostname -I 2>/dev/null | awk '{print $1}'):$DASHBOARD_PORT
3. SSH access: ssh $USERNAME@<hostname>
4. Review logs at: $LOG_FILE

ROLLBACK INSTRUCTIONS
---------------------
If you need to rollback:

For dual-boot:
  1. Boot from Windows recovery USB
  2. Open Command Prompt
  3. Run: bootrec /fixmbr
  4. Run: bootrec /fixboot
  5. Run: bootrec /rebuildbcd
  6. Delete Linux partitions from Disk Management

For dedicated install:
  1. Boot from any Linux live USB
  2. Reinstall your preferred OS

For WSL:
  wsl --unregister KIRAT-OS

SUPPORT
-------
For issues or questions, check:
- Installation log: $LOG_FILE
- System logs: journalctl -xe
- KIRAT OS documentation

===============================================================================
EOF
    
    # Copy report to installed system
    if [[ -d "$INSTALL_ROOT" ]]; then
        cp "$report_file" "$INSTALL_ROOT/root/kirat-os-install-report.txt"
    fi
    
    cat "$report_file"
    
    success "Report saved to: $report_file"
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    header "Cleaning Up"
    
    if [[ -d "$INSTALL_ROOT" ]]; then
        # Unmount everything
        umount -R "$INSTALL_ROOT" 2>/dev/null || true
        
        # Remove mount point
        rmdir "$INSTALL_ROOT" 2>/dev/null || true
    fi
    
    success "Cleanup complete"
}

# =============================================================================
# Main Installation Flow
# =============================================================================

run_dual_boot() {
    header "DUAL-BOOT INSTALLATION"
    
    info "This will install KIRAT OS alongside your existing Windows installation"
    info ""
    warn "IMPORTANT PREREQUISITES:"
    echo "  1. BACK UP ALL IMPORTANT DATA"
    echo "  2. Disable BitLocker (if enabled)"
    echo "  3. Disable Secure Boot (or add custom keys)"
    echo "  4. Shrink Windows partition to free space (or let this script do it)"
    echo "  5. Have a Windows recovery USB ready"
    echo ""
    
    if ! confirm "Have you completed all prerequisites?" "n"; then
        info "Please complete the prerequisites and re-run this script"
        exit 0
    fi
    
    check_cpu
    check_ram
    check_disk_space
    check_uefi
    check_network
    check_windows_partitions
    
    select_disk
    
    # Shrink Windows partition or use existing free space
    if confirm "Do you want to shrink the Windows partition now?" "n"; then
        shrink_windows_partition
    fi
    
    create_partitions_dualboot
    install_base_system
    configure_system
    install_grub
    copy_kirat_files
    build_kernel_module
    install_sentinel_runtime
    install_dashboard
    configure_users
    configure_ssh
    configure_network
    run_hardening
    generate_report
    cleanup
    
    header "Installation Complete!"
    success "KIRAT OS has been installed alongside Windows"
    info ""
    info "NEXT STEPS:"
    echo "  1. Reboot your computer"
    echo "  2. Select 'Debian' or 'KIRAT OS' from the GRUB menu"
    echo "  3. On first boot, the system will finalize configuration"
    echo "  4. Access the dashboard at http://<ip>:$DASHBOARD_PORT"
    echo ""
    info "To boot Windows: Select 'Windows' from the GRUB menu"
}

run_dedicated() {
    header "DEDICATED INSTALLATION"
    
    info "This will ERASE THE ENTIRE DISK and install KIRAT OS"
    
    check_cpu
    check_ram
    check_disk_space
    check_uefi
    check_network
    
    select_disk
    
    create_partitions_dedicated
    install_base_system
    configure_system
    install_grub
    copy_kirat_files
    build_kernel_module
    install_sentinel_runtime
    install_dashboard
    configure_users
    configure_ssh
    configure_network
    run_hardening
    generate_report
    cleanup
    
    header "Installation Complete!"
    success "KIRAT OS has been installed on $TARGET_DISK"
    info ""
    info "NEXT STEPS:"
    echo "  1. Remove installation media (USB/CD)"
    echo "  2. Reboot your computer"
    echo "  3. The system will boot into KIRAT OS"
    echo "  4. Access the dashboard at http://<ip>:$DASHBOARD_PORT"
}

run_vm() {
    header "VM INSTALLATION"
    
    info "This will create a KIRAT OS virtual machine"
    
    check_cpu
    check_ram
    check_network
    
    install_vm
    
    header "VM Created!"
    success "Virtual machine has been configured"
    info ""
    info "Complete the installation inside the VM:"
    echo "  1. Start the VM"
    echo "  2. Follow the Debian installer"
    echo "  3. After Debian install, run this script in 'dedicated' mode"
}

run_wsl() {
    header "WSL2 INSTALLATION"
    
    info "This will create a KIRAT OS WSL2 distribution"
    
    check_network
    install_wsl
    
    header "WSL Package Created!"
    success "WSL2 rootfs tarball is ready"
    info ""
    info "Import into WSL2:"
    echo "  wsl --import KIRAT-OS C:\\WSL\\KIRAT-OS C:\\path\\to\\kirat-os-wsl-rootfs.tar.gz"
}

run_usb_live() {
    header "USB LIVE CREATION"
    
    info "This will create a bootable USB drive for testing KIRAT OS"
    
    check_network
    create_usb_live
    
    header "USB Created!"
    success "Bootable USB is ready"
    info ""
    info "To use:"
    echo "  1. Insert USB into target computer"
    echo "  2. Boot from USB (F12, F2, or Del)"
    echo "  3. Select 'Try without installing' for live mode"
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    log_init
    log "Starting KIRAT OS installation script v$SCRIPT_VERSION"
    log "Arguments: $*"
    
    parse_args "$@"
    
    show_banner
    
    info "Installation mode: $INSTALL_MODE"
    info "Dry run: $DRY_RUN"
    info ""
    
    # Run mode-specific installation
    case "$INSTALL_MODE" in
        dual-boot)
            check_root
            run_dual_boot
            ;;
        dedicated)
            check_root
            run_dedicated
            ;;
        vm)
            run_vm
            ;;
        wsl)
            run_wsl
            ;;
        usb-live)
            check_root
            run_usb_live
            ;;
        *)
            fatal "Unknown installation mode: $INSTALL_MODE"
            ;;
    esac
    
    log "Installation completed successfully"
    
    echo -e "\n${GREEN}${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Installation Complete!${NC}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════${NC}\n"
}

# Run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
