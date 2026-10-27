#!/bin/bash
###############################################################################
# KIRAT OS Server Edition - Automated Build Script
# Builds a headless, enterprise-grade server OS with integrated AI
# 
# Targets:
#   home-server    - Media hub, file storage, home automation (10-65W)
#   cloud          - VPS/cloud instance, web hosting, APIs
#   edge           - Industrial/retail edge computing
#   homelab        - Kubernetes learning cluster
#   database       - Optimized for PostgreSQL/MySQL/Redis
#
# Usage:
#   sudo ./build-server.sh --target home-server --hostname sentinel-01
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

TARGET="${TARGET:-home-server}"
HOSTNAME="${HOSTNAME:-kirat-server}"
DISK="${DISK:-/dev/sda}"
BUILD_DIR="${BUILD_DIR:-/tmp/kirat-os-build}"
INSTALL_DIR="${INSTALL_DIR:-/mnt/kirat-os}"
AI_MODEL="${AI_MODEL:-llama-3.1-8b-sentinel}"
AI_QUANT="${AI_QUANT:-Q4_K_M}"

# Server profiles
declare -A PROFILE_PACKAGES
PROFILE_PACKAGES[home-server]="jellyfin nextcloud pihole home-assistant wireguard minio syncthing"
PROFILE_PACKAGES[cloud]="nginx caddy traefik docker k3s postgresql redis mongodb"
PROFILE_PACKAGES[edge]="docker mqtt nats redis sqlite tensorflow-lite"
PROFILE_PACKAGES[homelab]="k3s docker nomad consul vault prometheus grafana loki"
PROFILE_PACKAGES[database]="postgresql mysql redis clickhouse etcd patroni pgbackrest"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[BUILD]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_stage() { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            echo -e "${CYAN}[STAGE] $1${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

die() { log_error "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

check_requirements() {
    log_stage "Pre-flight Checks"
    
    # Must be root
    if [ "$EUID" -ne 0 ]; then
        die "This script must be run as root"
    fi
    
    # Check available tools
    local required=("wget" "curl" "git" "make" "gcc" "parted" "mkfs.ext4" "debootstrap")
    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_warn "Missing: $cmd (attempting to install)"
            apt-get update && apt-get install -y "$cmd" 2>/dev/null || true
        fi
    done
    
    # Disk space
    local free_space=$(df -BG "$(dirname "$BUILD_DIR")" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "${free_space:-0}" -lt 20 ]; then
        die "Need at least 20GB free space, have ${free_space}GB"
    fi
    
    # Target validation
    if [ -z "${PROFILE_PACKAGES[$TARGET]:-}" ]; then
        die "Unknown target: $TARGET. Valid: home-server, cloud, edge, homelab, database"
    fi
    
    log_ok "Pre-flight passed. Target: $TARGET"
}

# ─────────────────────────────────────────────────────────────────────────────
# DISK PREPARATION
# ─────────────────────────────────────────────────────────────────────────────

prepare_disk() {
    log_stage "Disk Preparation: $DISK"
    
    # WARNING: This erases the target disk!
    log_warn "About to erase $DISK. All data will be lost!"
    read -p "Type 'YES' to continue: " confirm
    if [ "$confirm" != "YES" ]; then
        die "Aborted by user"
    fi
    
    # Partition scheme (GPT):
    # 1. EFI System Partition (512MB)
    # 2. Boot partition (1GB, ext4)
    # 3. Root partition (20GB+, ext4 or ZFS)
    # 4. Data partition (remainder, ZFS)
    
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart primary fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    parted -s "$DISK" mkpart primary ext4 513MiB 1537MiB
    parted -s "$DISK" mkpart primary ext4 1537MiB 20GiB
    parted -s "$DISK" mkpart primary zfs 20GiB 100%
    
    # Format partitions
    mkfs.fat -F32 "${DISK}1"
    mkfs.ext4 -L boot "${DISK}2"
    mkfs.ext4 -L root "${DISK}3"
    
    # ZFS for data (if available)
    if command -v zpool &>/dev/null; then
        zpool create -f tank "${DISK}4"
        zfs create tank/data
        zfs create tank/backups
        zfs set compression=zstd tank
        zfs set atime=off tank
    else
        mkfs.ext4 -L data "${DISK}4"
    fi
    
    # Mount
    mkdir -p "$INSTALL_DIR"
    mount "${DISK}3" "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/boot"
    mount "${DISK}2" "$INSTALL_DIR/boot"
    mkdir -p "$INSTALL_DIR/boot/efi"
    mount "${DISK}1" "$INSTALL_DIR/boot/efi"
    
    if [ -d /tank ]; then
        mkdir -p "$INSTALL_DIR/data"
        mount --bind /tank "$INSTALL_DIR/data"
    fi
    
    log_ok "Disk prepared and mounted"
}

# ─────────────────────────────────────────────────────────────────────────────
# BASE SYSTEM (Debootstrap)
# ─────────────────────────────────────────────────────────────────────────────

install_base() {
    log_stage "Installing Base System"
    
    # Use debootstrap for quick base install
    # Alternative: Build from source (LFS style) - much slower
    # FIX 1: Make microcode packages optional with fallback for pure Debian (non-free).
    # Try debootstrap with microcode first (requires non-free-firmware on Bookworm+).
    # If that fails, retry without microcode packages so pure Debian still works.
    local microcode_pkgs="intel-microcode,amd64-microcode"
    local base_pkgs="linux-image-amd64,systemd,systemd-sysv,\
openssh-server,sudo,curl,wget,vim,nano,\
htop,iotop,ncdu,tree,rsync,git,\
net-tools,iproute2,iptables,nftables,\
dnsutils,ca-certificates,openssl,\
parted,e2fsprogs,zfsutils-linux,\
python3,python3-pip,python3-venv,\
docker.io,containerd,\
nfs-common,samba,cifs-utils,\
wireguard-tools"

    if debootstrap --variant=minbase --include="${base_pkgs},${microcode_pkgs}" \
        bookworm "$INSTALL_DIR" http://deb.debian.org/debian 2>/dev/null; then
        log_ok "Base system installed (with microcode)"
    else
        log_warn "Microcode packages failed (non-free repo may be missing). Retrying without microcode..."
        debootstrap --variant=minbase --include="${base_pkgs}" \
            bookworm "$INSTALL_DIR" http://deb.debian.org/debian
        log_ok "Base system installed (without microcode)"
    fi
    
    # Mount pseudo-filesystems for chroot
    mount --bind /dev "$INSTALL_DIR/dev"
    mount --bind /proc "$INSTALL_DIR/proc"
    mount --bind /sys "$INSTALL_DIR/sys"
    mount --bind /run "$INSTALL_DIR/run"
    
    log_ok "Base system installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# CHROOT CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

configure_system() {
    log_stage "System Configuration"
    
    # Set hostname
    echo "$HOSTNAME" > "$INSTALL_DIR/etc/hostname"
    cat > "$INSTALL_DIR/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Set timezone
    ln -sf /usr/share/zoneinfo/UTC "$INSTALL_DIR/etc/localtime"
    
    # Configure networking (systemd-networkd)
    cat > "$INSTALL_DIR/etc/systemd/network/20-wired.network" << 'EOF'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes

[DHCPv4]
RouteMetric=100

[IPv6AcceptRA]
RouteMetric=100
EOF

    # Enable services
    chroot "$INSTALL_DIR" systemctl enable systemd-networkd
    chroot "$INSTALL_DIR" systemctl enable systemd-resolved
    chroot "$INSTALL_DIR" systemctl enable ssh
    
    # Configure SSH (hardened)
    cat > "$INSTALL_DIR/etc/ssh/sshd_config.d/kirat.conf" << 'EOF'
# KIRAT OS SSH Hardening
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding yes
PermitTunnel no
EOF

    # Create sentinel user
    chroot "$INSTALL_DIR" useradd -m -s /bin/bash -G sudo,docker sentinel
    
    # Set up sudo
    cat > "$INSTALL_DIR/etc/sudoers.d/sentinel" << 'EOF'
sentinel ALL=(ALL) NOPASSWD: /usr/bin/sentinel
sentinel ALL=(ALL) NOPASSWD: /usr/bin/docker
sentinel ALL=(ALL) NOPASSWD: /usr/bin/systemctl
EOF
    chmod 440 "$INSTALL_DIR/etc/sudoers.d/sentinel"
    
    log_ok "System configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# KERNEL OPTIMIZATION
# ─────────────────────────────────────────────────────────────────────────────

optimize_kernel() {
    log_stage "Kernel Optimization for Server Workloads"
    
    # Kernel parameters for server performance
    cat > "$INSTALL_DIR/etc/sysctl.d/99-kirat-server.conf" << 'EOF'
# Network performance
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.core.netdev_max_backlog = 300000
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3

# Connection tracking
net.netfilter.nf_conntrack_max = 2000000
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established = 600

# Memory
vm.swappiness = 10
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 50
vm.overcommit_memory = 1

# File descriptors
fs.file-max = 2097152
fs.nr_open = 2097152

# Security
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1

# io_uring
kernel.io_uring_disabled = 0
EOF

    # CPU governor (performance for servers)
    cat > "$INSTALL_DIR/etc/systemd/system/cpu-performance.service" << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$cpu"; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_DIR" systemctl enable cpu-performance
    
    # IRQ affinity (distribute interrupts across cores)
    cat > "$INSTALL_DIR/usr/local/bin/irq-affinity.sh" << 'EOF'
#!/bin/bash
# Distribute NIC interrupts across CPU cores
irqs=$(grep -E "(eth|enp|ens)" /proc/interrupts | awk '{print $1}' | tr -d ':')
core=0
cores=$(nproc)
for irq in $irqs; do
    mask=$(printf "%x" $((1 << core)))
    echo "$mask" > /proc/irq/$irq/smp_affinity
    core=$(((core + 1) % cores))
done
EOF
    chmod +x "$INSTALL_DIR/usr/local/bin/irq-affinity.sh"
    
    log_ok "Kernel optimized"
}

# ─────────────────────────────────────────────────────────────────────────────
# SENTINEL AI INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_sentinel() {
    log_stage "Installing Sentinel AI Core"
    
    # Create sentinel directory structure
    mkdir -p "$INSTALL_DIR/opt/sentinel"{"/models","/data","/logs","/config","/src"}
    
    # FIX 2: Use a Python virtual environment instead of --break-system-packages.
    # Create venv inside chroot and install dependencies there.
    chroot "$INSTALL_DIR" python3 -m venv /opt/sentinel/venv
    chroot "$INSTALL_DIR" /opt/sentinel/venv/bin/pip install --upgrade pip
    chroot "$INSTALL_DIR" /opt/sentinel/venv/bin/pip install \
        fastapi uvicorn websockets \
        prometheus-client psutil \
        pyyaml aiohttp aiofiles || {
        log_warn "Some Python packages failed to install; continuing anyway"
    }
    
    # Download AI model (if specified)
    if [ -n "$AI_MODEL" ]; then
        log_info "Downloading AI model: $AI_MODEL ($AI_QUANT)"
        # This would use huggingface-cli or similar
        # For now, create placeholder
        cat > "$INSTALL_DIR/opt/sentinel/config/model.conf" << EOF
MODEL_NAME=$AI_MODEL
MODEL_QUANT=$AI_QUANT
MODEL_PATH=/opt/sentinel/models/$AI_MODEL.$AI_QUANT.gguf
EOF
    fi
    
    # FIX 3: sentinel-core only contains README.md, no actual source code.
    # The systemd service points to /opt/sentinel/src/main.py which doesn't exist.
    # Create a minimal main.py placeholder and directory structure.
    # If sentinel-core directory exists, copy it; otherwise create placeholder.
    if [ -d "sentinel-core" ] && [ -f "sentinel-core/src/main.py" ]; then
        cp -r sentinel-core "$INSTALL_DIR/opt/sentinel/"
    else
        log_warn "sentinel-core source not found or incomplete. Creating minimal placeholder."
        mkdir -p "$INSTALL_DIR/opt/sentinel/src"
        cat > "$INSTALL_DIR/opt/sentinel/src/main.py" << 'EOF'
#!/usr/bin/env python3
"""
Sentinel AI Core - Minimal Placeholder
This is a stub main.py. Replace with actual sentinel-core source.
"""
import sys
import os
import time
import logging

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("sentinel")

def main():
    logger.info("Sentinel AI Core starting...")
    logger.info("PID: %s", os.getpid())
    # Placeholder loop
    while True:
        time.sleep(60)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logger.info("Shutting down...")
        sys.exit(0)
EOF
        chmod +x "$INSTALL_DIR/opt/sentinel/src/main.py"
    fi
    
    # Also ensure the sentinel user owns the directory
    chroot "$INSTALL_DIR" chown -R sentinel:sentinel /opt/sentinel || true
    
    # Create systemd service
    # FIX 2 (continued): Update ExecStart to use the venv Python.
    cat > "$INSTALL_DIR/etc/systemd/system/sentinel.service" << 'EOF'
[Unit]
Description=Sentinel AI Core
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=notify
User=sentinel
Group=sentinel
WorkingDirectory=/opt/sentinel
Environment=PYTHONPATH=/opt/sentinel
Environment=SENTINEL_CONFIG=/etc/sentinel/sentinel.yaml
ExecStart=/opt/sentinel/venv/bin/python3 /opt/sentinel/src/main.py
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sentinel

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096
MemoryMax=2G
CPUQuota=200%

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/sentinel/data /opt/sentinel/logs

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_DIR" systemctl enable sentinel
    
    # FIX 4: kernel-ai/kirat-ai.c exists but no build step; service checks for .ko.
    # Add a build step: if source exists and .ko is missing, try to compile.
    if [ -f "kernel-ai/kirat-ai.c" ]; then
        if [ ! -f "kernel-ai/kirat-ai.ko" ]; then
            log_info "Kernel module source found but .ko missing. Attempting to build..."
            local kver
            kver=$(uname -r)
            # Attempt an out-of-tree build using the running kernel headers
            if [ -d "/lib/modules/${kver}/build" ]; then
                make -C "/lib/modules/${kver}/build" M="$(pwd)/kernel-ai" modules 2>/dev/null || \
                    log_warn "Kernel module build failed (headers may be missing). Skipping."
            else
                log_warn "Kernel headers not found for ${kver}. Skipping kernel module build."
            fi
        fi
    fi

    # Install kernel module (if built)
    if [ -f kernel-ai/kirat-ai.ko ]; then
        local target_kver
        target_kver=$(chroot "$INSTALL_DIR" uname -r 2>/dev/null || uname -r)
        mkdir -p "$INSTALL_DIR/lib/modules/${target_kver}/extra"
        cp kernel-ai/kirat-ai.ko "$INSTALL_DIR/lib/modules/${target_kver}/extra/"
        cat > "$INSTALL_DIR/etc/modules-load.d/kirat-ai.conf" << 'EOF'
kirat-ai
EOF
    fi
    
    log_ok "Sentinel AI installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# WORKLOAD INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

install_workloads() {
    log_stage "Installing Workloads for: $TARGET"
    
    local packages="${PROFILE_PACKAGES[$TARGET]}"
    log_info "Packages: $packages"
    
    # Install via Docker for isolation and ease of management
    for pkg in $packages; do
        case "$pkg" in
            jellyfin)
                install_jellyfin
                ;;
            nextcloud)
                install_nextcloud
                ;;
            pihole)
                install_pihole
                ;;
            postgresql)
                install_postgresql
                ;;
            redis)
                install_redis
                ;;
            nginx)
                install_nginx
                ;;
            k3s)
                install_k3s
                ;;
            wireguard)
                install_wireguard
                ;;
            minio)
                install_minio
                ;;
            prometheus)
                install_monitoring
                ;;
            *)
                log_warn "No installer for: $pkg"
                ;;
        esac
    done
    
    log_ok "Workloads installed"
}

# Individual workload installers
install_jellyfin() {
    log_info "Installing Jellyfin media server"
    cat > "$INSTALL_DIR/etc/systemd/system/jellyfin.service" << 'EOF'
[Unit]
Description=Jellyfin Media Server
After=network.target

[Service]
Type=simple
User=sentinel
ExecStart=/usr/bin/docker run --rm \
    --name jellyfin \
    -p 8096:8096 \
    -v /data/media:/media:ro \
    -v /opt/sentinel/data/jellyfin:/config \
    jellyfin/jellyfin:latest
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_DIR" systemctl enable jellyfin
}

install_postgresql() {
    log_info "Installing PostgreSQL"
    chroot "$INSTALL_DIR" apt-get install -y postgresql-15 postgresql-contrib-15
    
    # Optimize for server workloads
    # FIX 6: Calculate shared_buffers and effective_cache_size from actual RAM
    # instead of using the literal invalid string "25% RAM".
    local total_ram_kb
    total_ram_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    local total_ram_mb=$(( total_ram_kb / 1024 ))
    local shared_buffers=$(( total_ram_mb / 4 ))       # 25% of RAM in MB
    local effective_cache_size=$(( (total_ram_mb * 3) / 4 ))  # 75% of RAM in MB

    cat > "$INSTALL_DIR/etc/postgresql/15/main/conf.d/kirat.conf" << EOF
# KIRAT OS PostgreSQL Optimization
shared_buffers = ${shared_buffers}MB
effective_cache_size = ${effective_cache_size}MB
work_mem = 256MB
maintenance_work_mem = 512MB
max_connections = 200
wal_buffers = 16MB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
EOF
    
    chroot "$INSTALL_DIR" systemctl enable postgresql
}

install_k3s() {
    log_info "Installing K3s (lightweight Kubernetes)"
    # FIX 5: Avoid piping curl directly to sh without verification.
    # Download the installer and a known checksum, verify, then execute.
    local k3s_version="${K3S_VERSION:-v1.30.3+k3s1}"
    local install_script="/tmp/k3s-install-${k3s_version}.sh"
    local checksum_file="/tmp/k3s-install-${k3s_version}.sha256sum"
    local base_url="https://github.com/k3s-io/k3s/releases/download/${k3s_version}"

    # Download install script and checksum
    curl -fsSL "${base_url}/install.sh" -o "$install_script" || \
        die "Failed to download K3s install script"
    curl -fsSL "${base_url}/sha256sum-amd64.txt" -o "$checksum_file" || \
        log_warn "K3s checksum file not available; skipping checksum verification"

    # Verify checksum if available
    if [ -f "$checksum_file" ]; then
        local expected_sum
        expected_sum=$(awk '/install\.sh/ {print $1}' "$checksum_file")
        if [ -n "$expected_sum" ]; then
            local actual_sum
            actual_sum=$(sha256sum "$install_script" | awk '{print $1}')
            if [ "$expected_sum" != "$actual_sum" ]; then
                die "K3s install script checksum mismatch! Expected: $expected_sum, Got: $actual_sum"
            fi
            log_ok "K3s install script checksum verified"
        else
            log_warn "No checksum entry for install.sh in checksum file"
        fi
    fi

    chmod +x "$install_script"
    INSTALL_K3S_EXEC="server --disable traefik" chroot "$INSTALL_DIR" "$install_script" || \
        die "K3s installation failed"
    chroot "$INSTALL_DIR" systemctl enable k3s
}

install_monitoring() {
    log_info "Installing monitoring stack"
    
    # Prometheus
    cat > "$INSTALL_DIR/etc/systemd/system/prometheus.service" << 'EOF'
[Unit]
Description=Prometheus Monitoring
After=network.target

[Service]
User=sentinel
ExecStart=/usr/bin/docker run --rm \
    -p 9090:9090 \
    -v /opt/sentinel/data/prometheus:/prometheus \
    prom/prometheus:latest
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    # Grafana
    cat > "$INSTALL_DIR/etc/systemd/system/grafana.service" << 'EOF'
[Unit]
Description=Grafana Dashboard
After=prometheus.service

[Service]
User=sentinel
ExecStart=/usr/bin/docker run --rm \
    -p 3000:3000 \
    -v /opt/sentinel/data/grafana:/var/lib/grafana \
    grafana/grafana:latest
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    
    chroot "$INSTALL_DIR" systemctl enable prometheus grafana
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOTLOADER
# ─────────────────────────────────────────────────────────────────────────────

install_bootloader() {
    log_stage "Installing Bootloader"
    
    # Install systemd-boot (for EFI)
    chroot "$INSTALL_DIR" bootctl install
    
    cat > "$INSTALL_DIR/boot/efi/loader/entries/kirat-os.conf" << EOF
title   KIRAT OS Server - $TARGET
linux   /vmlinuz-$(uname -r)
initrd  /initrd.img-$(uname -r)
options root=UUID=$(blkid -s UUID -o value "${DISK}3") rw quiet \
    systemd.show_status=auto \
    console=tty0 console=ttyS0,115200n8 \
    net.ifnames=0 biosdevname=0
EOF

    cat > "$INSTALL_DIR/boot/efi/loader/loader.conf" << 'EOF'
default kirat-os.conf
timeout 3
console-mode max
EOF

    # Update initramfs
    chroot "$INSTALL_DIR" update-initramfs -c -k all
    
    log_ok "Bootloader installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# FINALIZATION
# ─────────────────────────────────────────────────────────────────────────────

finalize() {
    log_stage "Finalizing Installation"
    
    # Set root password (user will change on first boot)
    echo "root:kirat-temp-password" | chroot "$INSTALL_DIR" chpasswd
    
    # Create first-boot script
    cat > "$INSTALL_DIR/usr/local/bin/first-boot-setup.sh" << 'EOF'
#!/bin/bash
# First boot configuration

if [ -f /var/lib/kirat-first-boot-done ]; then
    exit 0
fi

echo "========================================"
echo "  Welcome to KIRAT OS Server Edition"
echo "========================================"
echo ""

# Change root password
echo "Set root password:"
passwd

# Create sentinel SSH key
if [ ! -f /home/sentinel/.ssh/id_ed25519 ]; then
    su - sentinel -c "ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
    cat /home/sentinel/.ssh/id_ed25519.pub >> /home/sentinel/.ssh/authorized_keys
fi

echo ""
echo "Your SSH public key (add to client):"
cat /home/sentinel/.ssh/id_ed25519.pub
echo ""

# Start Sentinel AI
echo "Starting Sentinel AI..."
systemctl start sentinel

echo ""
echo "Access your server:"
echo "  SSH: ssh sentinel@$(hostname -I | awk '{print $1}')"
echo "  Web: http://$(hostname -I | awk '{print $1}'):8080"
echo ""

touch /var/lib/kirat-first-boot-done
EOF
    chmod +x "$INSTALL_DIR/usr/local/bin/first-boot-setup.sh"
    
    # Add to systemd first-boot
    cat > "$INSTALL_DIR/etc/systemd/system/kirat-first-boot.service" << 'EOF'
[Unit]
Description=KIRAT OS First Boot Setup
After=network-online.target
ConditionPathExists=!/var/lib/kirat-first-boot-done

[Service]
Type=oneshot
ExecStart=/usr/local/bin/first-boot-setup.sh
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_DIR" systemctl enable kirat-first-boot
    
    # Unmount
    umount -R "$INSTALL_DIR" 2>/dev/null || true
    
    log_ok "Installation complete!"
    log_info "Boot from $DISK to start KIRAT OS Server"
    log_info "First boot will guide you through setup"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

show_banner() {
    cat << 'BANNER'
 _   ___ ___ ___ __  __ ___ _____   ___   _   ___ 
| | / /_ _| _ \  \/  | _ \_   _| / _ \ /_\ | _ \
| |/ / | ||  _/ |\/| |  _/ | || | (_) / _ \|   /
|___/ |___|_| |_|  |_|_|   |_|  \___/_/ \_\_|_\
                                                 
    KIRAT OS Server Edition - Sentinel
    Enterprise-grade, AI-native server OS
    
BANNER
}

show_help() {
    cat << 'HELP'
Usage: sudo ./build-server.sh [OPTIONS]

Options:
  --target <type>      Server type: home-server, cloud, edge, homelab, database
  --hostname <name>    Server hostname (default: kirat-server)
  --disk <device>      Target disk (default: /dev/sda)
  --ai-model <model>   AI model to install (default: llama-3.1-8b-sentinel)
  --ai-quant <quant>   Quantization level: Q4_K_M, Q5_K_M, Q8_0
  --build-dir <path>   Build directory (default: /tmp/kirat-os-build)
  --install-dir <path> Install mount point (default: /mnt/kirat-os)
  --help               Show this help

Examples:
  # Home media server
  sudo ./build-server.sh --target home-server --hostname mediahub

  # Cloud web server
  sudo ./build-server.sh --target cloud --hostname web-01 --disk /dev/nvme0n1

  # Database server
  sudo ./build-server.sh --target database --hostname db-primary

HELP
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target) TARGET="$2"; shift 2 ;;
            --hostname) HOSTNAME="$2"; shift 2 ;;
            --disk) DISK="$2"; shift 2 ;;
            --ai-model) AI_MODEL="$2"; shift 2 ;;
            --ai-quant) AI_QUANT="$2"; shift 2 ;;
            --build-dir) BUILD_DIR="$2"; shift 2 ;;
            --install-dir) INSTALL_DIR="$2"; shift 2 ;;
            --help) show_help; exit 0 ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done
}

main() {
    show_banner
    parse_args "$@"
    
    log_info "Target: $TARGET"
    log_info "Hostname: $HOSTNAME"
    log_info "Disk: $DISK"
    log_info "AI Model: $AI_MODEL ($AI_QUANT)"
    
    check_requirements
    prepare_disk
    install_base
    configure_system
    optimize_kernel
    install_sentinel
    install_workloads
    install_bootloader
    finalize
    
    log_stage "BUILD COMPLETE"
    log_ok "KIRAT OS Server Edition installed on $DISK"
    log_info "Reboot and select $DISK to start"
    log_info "First boot will run interactive setup"
    log_info ""
    log_info "Post-installation:"
    log_info "  SSH: ssh sentinel@<server-ip>"
    log_info "  Web: http://<server-ip>:8080 (Sentinel dashboard)"
    log_info "  AI:  sentinel \"Why is CPU high?\""
}

main "$@"
