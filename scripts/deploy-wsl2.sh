#!/bin/bash
###############################################################################
# KIRAT OS - WSL2 DEPLOYMENT SCRIPT
###############################################################################
# Deploys KIRAT OS as a WSL2 distribution on Windows 10/11.
# No dual-boot needed. Runs alongside Windows with full Linux kernel.
#
# Prerequisites (Windows side):
#   1. WSL2 installed:  wsl --install
#   2. Virtualization enabled in BIOS
#   3. Windows 10 version 2004+ or Windows 11
#
# Usage:
#   # In PowerShell (Admin), run setup first:
#   wsl --install -d Debian
#   # Then in WSL2 Debian, run:
#   sudo bash deploy-wsl2.sh
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIMI_OS_VERSION="1.0.0-QUANTUM"
WSL_DISTRO_NAME="KIRAT-OS"
WSL_INSTALL_DIR="/mnt/c/WSL/KIRAT-OS"
ROOTFS_SIZE_GB=20

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[WSL2]${NC} $1"; }
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

check_wsl_environment() {
    log_stage "Checking WSL2 Environment"
    
    # Are we running inside WSL?
    if [ -f /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -f /run/WSLInterop ]; then
        log_ok "Running inside WSL2"
    else
        log_warn "Not running inside WSL2"
        log_info "Please run this script inside a WSL2 distribution (e.g., Debian, Ubuntu)"
        log_info "Or run in PowerShell: wsl -d Debian bash -c 'sudo bash deploy-wsl2.sh'"
        
        read -p "Continue anyway? [y/N] " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
    fi
    
    # Check WSL version
    local wsl_version
    wsl_version=$(uname -r | grep -oE "WSL2|microsoft-standard" || true)
    if [ -n "$wsl_version" ]; then
        log_ok "WSL2 kernel detected"
    else
        log_warn "WSL version unclear. Ensure WSL2 (not WSL1)."
    fi
    
    # Check disk space
    local avail_gb
    avail_gb=$(df -BG /mnt/c 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
    if [ "${avail_gb:-0}" -lt 30 ]; then
        die "Need at least 30GB free on C: drive. Have: ${avail_gb}GB"
    fi
    log_ok "Disk space sufficient: ${avail_gb}GB available"
    
    # Check if we have root
    if [ "$EUID" -ne 0 ]; then
        die "This script must be run as root inside WSL2. Use: sudo bash deploy-wsl2.sh"
    fi
    
    log_ok "Pre-flight passed"
}

# ─────────────────────────────────────────────────────────────────────────────
# BUILD ROOTFS
# ─────────────────────────────────────────────────────────────────────────────

build_rootfs() {
    log_stage "Building KIRAT OS WSL2 Root Filesystem"
    
    local rootfs_dir="/tmp/kirat-os-wsl-rootfs"
    local rootfs_tar="/tmp/kirat-os-wsl.tar.gz"
    
    # Clean up any previous build
    rm -rf "$rootfs_dir" "$rootfs_tar"
    mkdir -p "$rootfs_dir"
    
    # Install debootstrap if needed
    if ! command -v debootstrap &>/dev/null; then
        log_info "Installing debootstrap..."
        apt-get update -qq
        apt-get install -y -qq debootstrap
    fi
    
    # Create minimal Debian rootfs
    log_info "Creating Debian base (this may take 10-15 minutes)..."
    debootstrap --variant=minbase \
        --include=systemd,systemd-sysv,openssh-server,sudo,curl,wget,vim,nano,\
htop,ncdu,tree,rsync,git,net-tools,iproute2,iptables,nftables,dnsutils,\
ca-certificates,openssl,python3,python3-pip,python3-venv,docker.io,\
containerd,nginx,cryptsetup,cryptsetup-bin \
        bookworm "$rootfs_dir" http://deb.debian.org/debian
    
    log_ok "Base system created"
    
    # Configure WSL-specific settings
    log_info "Configuring WSL integration..."
    
    cat > "$rootfs_dir/etc/wsl.conf" << 'EOF'
[boot]
systemd=true
command = /opt/kirat-os/scripts/wsl-first-boot.sh

[user]
default=sentinel

[interop]
enabled=true
appendWindowsPath=true

[network]
generateHosts=true
generateResolvConf=true

[automount]
enabled=true
mountFsTab=true
root=/mnt/
options="metadata,umask=22,fmask=11"

[filesystem]
umask=022
EOF
    
    # Set hostname
    echo "kirat-os-wsl" > "$rootfs_dir/etc/hostname"
    
    cat > "$rootfs_dir/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   kirat-os-wsl
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
    
    # Create sentinel user
    chroot "$rootfs_dir" useradd -m -s /bin/bash -G sudo,docker sentinel
    echo "sentinel:sentinel" | chroot "$rootfs_dir" chpasswd
    
    # Configure SSH
    cat > "$rootfs_dir/etc/ssh/sshd_config.d/kirat-wsl.conf" << 'EOF'
# KIRAT OS WSL SSH Configuration
Port 2222
PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
X11Forwarding no
EOF
    
    # Enable services
    chroot "$rootfs_dir" systemctl enable ssh
    chroot "$rootfs_dir" systemctl enable nginx
    
    # Install KIRAT OS components
    log_info "Installing KIRAT OS components..."
    mkdir -p "$rootfs_dir/opt/kirat-os"
    
    # Copy quantum-ai ecosystem
    if [ -d "$SCRIPT_DIR/../quantum-ai" ]; then
        cp -r "$SCRIPT_DIR/../quantum-ai" "$rootfs_dir/opt/kirat-os/"
        log_ok "Quantum AI ecosystem copied"
    fi
    
    # Copy security files
    if [ -d "$SCRIPT_DIR/../security" ]; then
        cp -r "$SCRIPT_DIR/../security" "$rootfs_dir/opt/kirat-os/"
        log_ok "Security files copied"
    fi
    
    # Copy dashboard
    if [ -d "$SCRIPT_DIR/../dashboard" ]; then
        cp -r "$SCRIPT_DIR/../dashboard" "$rootfs_dir/opt/kirat-os/"
        log_ok "Dashboard copied"
    fi
    
    # Copy sentinel-core
    if [ -d "$SCRIPT_DIR/../sentinel-core" ]; then
        cp -r "$SCRIPT_DIR/../sentinel-core" "$rootfs_dir/opt/kirat-os/"
        log_ok "Sentinel core copied"
    fi
    
    # Create WSL first-boot script
    mkdir -p "$rootfs_dir/opt/kirat-os/scripts"
    cat > "$rootfs_dir/opt/kirat-os/scripts/wsl-first-boot.sh" << 'EOF'
#!/bin/bash
# KIRAT OS WSL First Boot Setup

if [ -f /var/lib/kirat-wsl-first-boot ]; then
    exit 0
fi

# Set up Python environment for quantum AI
if [ -d /opt/kirat-os/quantum-ai ]; then
    cd /opt/kirat-os/quantum-ai
    python3 -m venv venv 2>/dev/null || true
    ./venv/bin/pip install -r requirements.txt 2>/dev/null || true
fi

# Start services
systemctl start ssh 2>/dev/null || true
systemctl start nginx 2>/dev/null || true

# Create completion marker
touch /var/lib/kirat-wsl-first-boot
EOF
    chmod +x "$rootfs_dir/opt/kirat-os/scripts/wsl-first-boot.sh"
    
    # Create systemd service for quantum AI
    cat > "$rootfs_dir/etc/systemd/system/kirat-quantum-ai.service" << 'EOF'
[Unit]
Description=KIRAT OS Quantum AI Ecosystem
After=network-online.target

[Service]
Type=simple
User=sentinel
WorkingDirectory=/opt/kirat-os/quantum-ai
ExecStart=/opt/kirat-os/quantum-ai/venv/bin/python -m uvicorn ecosystem-api:app --host 0.0.0.0 --port 8081
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    chroot "$rootfs_dir" systemctl enable kirat-quantum-ai
    
    # Create the tarball
    log_info "Creating rootfs tarball (this may take a few minutes)..."
    tar -czf "$rootfs_tar" -C "$rootfs_dir" .
    
    local tar_size
    tar_size=$(du -h "$rootfs_tar" | cut -f1)
    log_ok "Rootfs tarball created: $rootfs_tar ($tar_size)"
    
    echo "$rootfs_tar"
}

# ─────────────────────────────────────────────────────────────────────────────
# IMPORT INTO WSL2
# ─────────────────────────────────────────────────────────────────────────────

import_wsl() {
    log_stage "Importing into WSL2"
    
    local rootfs_tar="$1"
    local windows_tar_path
    
    # Convert path to Windows format for wsl --import
    windows_tar_path=$(wslpath -w "$rootfs_tar" 2>/dev/null || echo "$rootfs_tar")
    
    # Check if distro already exists
    if wsl -l -v 2>/dev/null | grep -q "$WSL_DISTRO_NAME"; then
        log_warn "Distribution '$WSL_DISTRO_NAME' already exists"
        read -p "Unregister existing and re-import? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Unregistering existing distribution..."
            wsl --unregister "$WSL_DISTRO_NAME" || true
        else
            log_info "Skipping import. To manually import:"
            log_info "  wsl --import $WSL_DISTRO_NAME C:\\WSL\\$WSL_DISTRO_NAME $windows_tar_path"
            return 0
        fi
    fi
    
    # Create Windows directory for WSL
    local wsl_windows_dir
    wsl_windows_dir=$(wslpath -w "$WSL_INSTALL_DIR" 2>/dev/null || echo "C:\\WSL\\$WSL_DISTRO_NAME")
    
    log_info "Importing $WSL_DISTRO_NAME..."
    log_info "Install location: $wsl_windows_dir"
    
    # Import the distribution
    wsl --import "$WSL_DISTRO_NAME" "$wsl_windows_dir" "$rootfs_tar" || {
        log_error "WSL import failed"
        log_info "Manual import command:"
        log_info "  wsl --import $WSL_DISTRO_NAME $wsl_windows_dir $windows_tar_path"
        return 1
    }
    
    log_ok "KIRAT OS imported as WSL2 distribution: $WSL_DISTRO_NAME"
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURE WSL2 SETTINGS
# ─────────────────────────────────────────────────────────────────────────────

configure_wsl_settings() {
    log_stage "Configuring WSL2 Settings"
    
    # Create/update .wslconfig for global WSL2 settings
    local wslconfig_path="/mnt/c/Users/$USER/.wslconfig"
    
    cat > /tmp/wslconfig << 'EOF'
# KIRAT OS WSL2 Global Configuration
# Place this file at C:\Users\<YourUsername>\.wslconfig

[wsl2]
# Memory allocation (adjust based on your system)
memory=16GB
processors=8

# Swap file
swap=8GB
swapFile=C:\\temp\\wsl-swap.vhdx

# Networking
localhostForwarding=true

# Kernel command line (for module.sig_enforce)
kernelCommandLine=module.sig_enforce=1

# GUI applications
guiApplications=true

# Disk performance
pageReporting=true
EOF
    
    log_info "WSL2 config template created at: /tmp/wslconfig"
    log_info "Copy to: C:\\Users\\<YourUsername>\\.wslconfig"
    
    # Set default distribution
    log_info "Setting $WSL_DISTRO_NAME as default WSL distribution..."
    wsl --set-default "$WSL_DISTRO_NAME" 2>/dev/null || \
        log_warn "Could not set default (may need to run manually)"
    
    log_ok "WSL2 configuration complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# POST-INSTALL GUIDE
# ─────────────────────────────────────────────────────────────────────────────

show_post_install_guide() {
    log_stage "WSL2 Deployment Complete!"
    
    cat << 'GUIDE'

╔══════════════════════════════════════════════════════════════════════╗
║              KIRAT OS WSL2 - DEPLOYMENT SUCCESSFUL                     ║
╚══════════════════════════════════════════════════════════════════════╝

START KIRAT OS:
  wsl -d KIRAT-OS

OR (if set as default):
  wsl

ACCESS SERVICES:
  SSH:        ssh sentinel@localhost -p 2222
  Dashboard:  http://localhost:8080
  Quantum AI: http://localhost:8081/quantum/health
  (From Windows, access via localhost)

WINDOWS INTEGRATION:
  • Files accessible at: \\wsl$\KIRAT-OS
  • Windows paths auto-mounted under /mnt/
  • Windows executables callable from KIRAT OS

MANAGEMENT COMMANDS:
  wsl -l -v                    # List distributions
  wsl --shutdown               # Shutdown all WSL
  wsl -t KIRAT-OS               # Terminate KIRAT-OS
  wsl --unregister KIRAT-OS     # Remove completely

RESOURCE LIMITS:
  Edit C:\Users\<You>\.wslconfig to adjust:
    memory=16GB
    processors=8

NEXT STEPS:
  1. wsl -d KIRAT-OS
  2. sudo systemctl status kirat-quantum-ai
  3. curl http://localhost:8081/quantum/health
  4. Run security hardening: sudo /opt/kirat-os/security/harden-fixed.sh
  5. Run security fixes: sudo /opt/kirat-os/security/fix-pending.sh

GUIDE
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    log_stage "KIRAT OS WSL2 Deployment"
    log_info "Version: $KIMI_OS_VERSION"
    
    check_wsl_environment
    
    local rootfs_tar
    rootfs_tar=$(build_rootfs)
    
    import_wsl "$rootfs_tar"
    configure_wsl_settings
    show_post_install_guide
    
    log_ok "Deployment complete!"
}

main "$@"
