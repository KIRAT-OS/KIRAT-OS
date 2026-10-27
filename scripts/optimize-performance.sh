#!/bin/bash
###############################################################################
# KIRAT OS — Performance Optimizer
###############################################################################
# Tunes kernel parameters, I/O schedulers, swap, and AI agent resource limits
# based on detected hardware profile.
###############################################################################

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${CYAN}[OPT]${NC}   $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
DISK_TYPE="unknown"

# Detect disk type
if [ -d /sys/block/sda ]; then
    if cat /sys/block/sda/queue/rotational 2>/dev/null | grep -q '0'; then
        DISK_TYPE="ssd"
    else
        DISK_TYPE="hdd"
    fi
elif [ -d /sys/block/nvme0n1 ]; then
    DISK_TYPE="nvme"
fi

log_info "Detected: ${RAM_GB}GB RAM, ${DISK_TYPE} storage"

# ─────────────────────────────────────────────────────────────────────────────
# KERNEL TUNING
# ─────────────────────────────────────────────────────────────────────────────
log_info "Applying kernel performance tuning..."

cat > /etc/sysctl.d/99-kirat-performance.conf << EOF
# KIRAT OS Performance Tuning — Auto-generated

# Memory
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
vm.overcommit_memory=1

# Network
net.core.somaxconn=65535
net.core.netdev_max_backlog=500000
net.ipv4.tcp_max_syn_backlog=65535
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_tw_reuse=1
net.ipv4.ip_local_port_range=1024 65535
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3
EOF

# Apply based on RAM profile
if [ "$RAM_GB" -ge 32 ]; then
    cat >> /etc/sysctl.d/99-kirat-performance.conf << 'EOF'
# High-RAM optimizations (32GB+)
net.core.rmem_max=268435456
net.core.wmem_max=268435456
net.ipv4.tcp_rmem=4096 87380 268435456
net.ipv4.tcp_wmem=4096 65536 268435456
vm.nr_hugepages=128
EOF
elif [ "$RAM_GB" -ge 16 ]; then
    cat >> /etc/sysctl.d/99-kirat-performance.conf << 'EOF'
# Medium-RAM optimizations (16GB+)
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
EOF
else
    cat >> /etc/sysctl.d/99-kirat-performance.conf << 'EOF'
# Low-RAM optimizations (8GB)
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF
fi

sysctl --system >/dev/null 2>&1
log_ok "Kernel parameters tuned"

# ─────────────────────────────────────────────────────────────────────────────
# I/O SCHEDULER
# ─────────────────────────────────────────────────────────────────────────────
log_info "Configuring I/O scheduler..."

for disk in /sys/block/sd* /sys/block/nvme*n* /sys/block/vd* /sys/block/hd*; do
    [ -e "$disk" ] || continue
    dev=$(basename "$disk")

    case "$DISK_TYPE" in
        nvme|ssd)
            echo none > "$disk/queue/scheduler" 2>/dev/null || true
            echo 2 > "$disk/queue/iosched/fifo_batch" 2>/dev/null || true
            ;;
        hdd)
            echo mq-deadline > "$disk/queue/scheduler" 2>/dev/null || true
            ;;
    esac

    # Enable NCQ for SSDs
    if [ "$DISK_TYPE" != "hdd" ]; then
        echo 31 > "$disk/queue/iosched/quantum" 2>/dev/null || true
    fi
done

log_ok "I/O scheduler configured for $DISK_TYPE"

# ─────────────────────────────────────────────────────────────────────────────
# SWAP OPTIMIZATION
# ─────────────────────────────────────────────────────────────────────────────
log_info "Optimizing swap..."

if [ "$RAM_GB" -ge 32 ]; then
    # Large RAM: minimal swap, zswap enabled
    fallocate -l 4G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null || true
    swapon /swapfile 2>/dev/null || true
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    echo 1 > /sys/module/zswap/parameters/enabled 2>/dev/null || true
    log_ok "4GB swap + zswap enabled"
elif [ "$RAM_GB" -ge 16 ]; then
    fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null || true
    swapon /swapfile 2>/dev/null || true
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    log_ok "8GB swap enabled"
else
    fallocate -l 8G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
    chmod 600 /swapfile
    mkswap /swapfile 2>/dev/null || true
    swapon /swapfile 2>/dev/null || true
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
    log_warn "8GB swap enabled (low RAM system)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CPU GOVERNOR
# ─────────────────────────────────────────────────────────────────────────────
log_info "Setting CPU governor..."

if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null || true
    done
    log_ok "CPU governor set to performance"
else
    log_warn "CPU frequency scaling not available"
fi

# ─────────────────────────────────────────────────────────────────────────────
# AI AGENT RESOURCE LIMITS
# ─────────────────────────────────────────────────────────────────────────────
log_info "Configuring AI agent resource limits..."

if [ "$RAM_GB" -ge 32 ]; then
    # High profile: all agents get full resources
    sed -i 's/MemoryMax=1G/MemoryMax=2G/g' /etc/systemd/system/jitedasti-ai.service 2>/dev/null || true
    sed -i 's/MemoryMax=1G/MemoryMax=2G/g' /etc/systemd/system/galinja-ai.service 2>/dev/null || true
    sed -i 's/MemoryMax=2G/MemoryMax=4G/g' /etc/systemd/system/aadhipati-ai.service 2>/dev/null || true
    sed -i 's/CPUQuota=100%/CPUQuota=200%/g' /etc/systemd/system/jitedasti-ai.service 2>/dev/null || true
elif [ "$RAM_GB" -ge 16 ]; then
    # Medium profile: balanced
    sed -i 's/MemoryMax=2G/MemoryMax=1G/g' /etc/systemd/system/jitedasti-ai.service 2>/dev/null || true
    sed -i 's/MemoryMax=4G/MemoryMax=2G/g' /etc/systemd/system/aadhipati-ai.service 2>/dev/null || true
else
    # Low profile: restrict AI agents
    sed -i 's/MemoryMax=.*/MemoryMax=512M/g' /etc/systemd/system/jitedasti-ai.service 2>/dev/null || true
    sed -i 's/MemoryMax=.*/MemoryMax=512M/g' /etc/systemd/system/galinja-ai.service 2>/dev/null || true
    sed -i 's/MemoryMax=.*/MemoryMax=1G/g' /etc/systemd/system/aadhipati-ai.service 2>/dev/null || true
    log_warn "AI agent memory restricted due to low RAM"
fi

systemctl daemon-reload 2>/dev/null || true
log_ok "AI agent resource limits configured"

# ─────────────────────────────────────────────────────────────────────────────
# NGINX PERFORMANCE
# ─────────────────────────────────────────────────────────────────────────────
log_info "Tuning Nginx..."

cat > /etc/nginx/conf.d/99-performance.conf << 'EOF'
# KIRAT OS Nginx Performance
core_worker_processes auto;
worker_connections 65535;
use epoll;
multi_accept on;
sendfile on;
tcp_nopush on;
tcp_nodelay on;
keepalive_timeout 65;
keepalive_requests 1000;
client_max_body_size 50M;
EOF

nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
log_ok "Nginx tuned"

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  KIRAT OS Performance Optimization Complete${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Profile:      $([ $RAM_GB -ge 32 ] && echo 'HIGH' || ([ $RAM_GB -ge 16 ] && echo 'MEDIUM' || echo 'LOW'))"
echo "  RAM:          ${RAM_GB}GB"
echo "  Storage:      ${DISK_TYPE}"
echo "  I/O Scheduler: $([ "$DISK_TYPE" = 'hdd' ] && echo 'mq-deadline' || echo 'none (NVMe/SSD)')"
echo "  CPU Governor: performance"
echo "  Swap:         $(free -h | grep Swap | awk '{print $2}')"
echo ""
echo "  Reboot recommended for all changes to take full effect."
echo ""
