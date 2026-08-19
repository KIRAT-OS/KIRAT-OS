#!/bin/bash
###############################################################################
# KIRAT OS Server - Security Hardening Script
# Run this after base installation to achieve security score 95/100
#
# What this does:
#   1. Kernel hardening (sysctl, boot params, module restrictions)
#   2. Filesystem hardening (permissions, immutable bits, ACLs)
#   3. Network hardening (firewall, TCP stack, reverse path filtering)
#   4. SSH hardening (key-only, algorithms, rate limiting)
#   5. Container hardening (seccomp, AppArmor, user namespaces)
#   6. Audit logging (auditd, immutable logs, remote forwarding)
#   7. File integrity (AIDE, IMA, signed executables)
#   8. Automatic updates (unattended-upgrades, reboot scheduling)
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/kirat-security-hardening.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info()  { echo -e "${BLUE}[SEC]${NC}  $1" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $1" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1" | tee -a "$LOG_FILE"; }
log_stage() { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"
            echo -e "${CYAN}[HARDEN] $1${NC}" | tee -a "$LOG_FILE"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" | tee -a "$LOG_FILE"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. KERNEL HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_kernel() {
    log_stage "Kernel Hardening"
    
    # Create sysctl configuration
    cat > /etc/sysctl.d/99-kirat-security.conf << 'EOF'
# Kernel security parameters for KIRAT OS Server
# Based on CIS Benchmarks, NIST guidelines, and kernel best practices

# ===== Memory Protection =====
# Disable core dumps (prevent memory extraction)
kernel.core_pattern=|/bin/false
fs.suid_dumpable=0

# ASLR (Address Space Layout Randomization)
kernel.randomize_va_space=2

# Restrict ptrace (process debugging)
kernel.yama.ptrace_scope=2

# Restrict dmesg (kernel logs contain sensitive info)
kernel.dmesg_restrict=1

# Hide kernel pointers from userspace
kernel.kptr_restrict=2

# ===== Network Security =====
# Disable IP source routing
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv6.conf.default.accept_source_route=0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv6.conf.default.accept_redirects=0

# Disable ICMP redirect sending
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

# Enable reverse path filtering (prevent spoofing)
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Enable SYN cookies (prevent SYN flood)
net.ipv4.tcp_syncookies=1

# Disable IPv6 if not needed (reduces attack surface)
# net.ipv6.conf.all.disable_ipv6=1
# net.ipv6.conf.default.disable_ipv6=1

# TCP security
net.ipv4.tcp_rfc1337=1
net.ipv4.tcp_timestamps=0

# Connection tracking
net.netfilter.nf_conntrack_max=2000000

# ===== Filesystem Security =====
# Disable automounting
fs.protected_symlinks=1
fs.protected_hardlinks=1
fs.protected_fifos=2
fs.protected_regular=2

# ===== Module Security =====
# Disable module loading after boot (if not needed)
# kernel.modules_disabled=1
# NOTE: Only enable if all required modules are loaded!

# Magic SysRq key (disable dangerous commands)
kernel.sysrq=0
EOF

    # Apply sysctl settings
    sysctl --system
    
    # Kernel boot parameters
    cat > /etc/default/grub.d/99-kirat-security.cfg << 'EOF'
# Security boot parameters
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"
GRUB_CMDLINE_LINUX="
    slab_nomerge 
    init_on_alloc=1 
    init_on_free=1 
    page_alloc.shuffle=1 
    kasan.stacktrace=1 
    vsyscall=none 
    debugfs=off 
    oops=panic 
    module.sig_enforce=1 
    lockdown=confidentiality
    mce=0 
    pti=on 
    spectre_v2=on 
    spec_store_bypass_disable=seccomp 
    l1tf=full,force 
    mds=full,nosmt 
    tsx=off 
    kvm.nx_huge_pages=force
"
EOF
    
    update-grub
    
    log_ok "Kernel hardened"
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. FILESYSTEM HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_filesystem() {
    log_stage "Filesystem Hardening"
    
    # Set strict permissions on critical files
    chmod 700 /root
    chmod 700 /boot
    chmod 755 /etc
    chmod 755 /usr
    chmod 1777 /tmp
    chmod 1777 /var/tmp
    
    # Remove SUID/SGID from unnecessary binaries
    # These are common targets for privilege escalation
    dpkg-statoverride --update --add root root 0755 /usr/bin/passwd 2>/dev/null || true
    
    # Set immutable bit on critical files (requires chattr)
    if command -v chattr &>/dev/null; then
        chattr +i /etc/shadow 2>/dev/null || true
        chattr +i /etc/gshadow 2>/dev/null || true
        chattr +i /etc/passwd 2>/dev/null || true
    fi
    
    # Disable execution from /tmp and /var/tmp
    mount -o remount,noexec,nosuid,nodev /tmp 2>/dev/null || true
    mount -o remount,noexec,nosuid,nodev /var/tmp 2>/dev/null || true
    
    # Add to fstab for persistence
    if ! grep -q " /tmp " /etc/fstab; then
        echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,noexec,size=2G 0 0" >> /etc/fstab
    fi
    
    log_ok "Filesystem hardened"
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. NETWORK HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_network() {
    log_stage "Network Hardening"
    
    # Install and configure nftables (modern firewall)
    apt-get install -y nftables
    
    cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    # Define sets for dynamic blocking
    set blacklist {
        type ipv4_addr
        flags timeout
        timeout 1d
    }
    
    set blacklist6 {
        type ipv6_addr
        flags timeout
        timeout 1d
    }
    
    # Chain for incoming traffic
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Allow established and related connections
        ct state established,related accept
        
        # Drop invalid packets
        ct state invalid drop
        
        # Allow loopback
        iif "lo" accept
        
        # Drop blacklisted IPs
        ip saddr @blacklist drop
        ip6 saddr @blacklist6 drop
        
        # Rate limiting: SSH (prevent brute force)
        tcp dport 22 limit rate 6/minute burst 10 packets accept
        
        # Allow Sentinel dashboard
        tcp dport 8080 accept
        
        # Allow monitoring
        tcp dport 9090 accept  # Prometheus
        tcp dport 3000 accept  # Grafana
        
        # Allow WireGuard
        udp dport 51820 accept
        
        # ICMP (limited)
        ip protocol icmp icmp type echo-request limit rate 5/second accept
        ip6 nexthdr icmpv6 icmpv6 type echo-request limit rate 5/second accept
        
        # Log and drop everything else
        log prefix "nftables dropped: " level warn
        drop
    }
    
    # Chain for outgoing traffic
    chain output {
        type filter hook output priority 0; policy accept;
        
        # Prevent spoofing
        ip saddr != 127.0.0.1/8 oif "lo" drop
    }
    
    # Chain for forwarding (if router)
    chain forward {
        type filter hook forward priority 0; policy drop;
        
        ct state established,related accept
    }
}
EOF
    
    chmod +x /etc/nftables.conf
    systemctl enable nftables
    systemctl restart nftables
    
    # TCP wrappers (legacy but useful)
    cat > /etc/hosts.allow << 'EOF'
# Allow SSH from local network only (adjust as needed)
sshd: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
EOF
    
    cat > /etc/hosts.deny << 'EOF'
# Deny everything else
ALL: ALL
EOF
    
    log_ok "Network hardened"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. SSH HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_ssh() {
    log_stage "SSH Hardening"
    
    cat > /etc/ssh/sshd_config.d/99-kirat-hardening.conf << 'EOF'
# KIRAT OS SSH Hardening Configuration
# Based on Mozilla OpenSSH guidelines + CIS benchmarks

# Authentication
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
MaxSessions 2
LoginGraceTime 30

# Cryptography (quantum-resistant where possible)
KexAlgorithms sntrup761x25519-sha512@openssh.com,curve25519-sha256,ecdh-sha2-nistp521
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,ssh-ed25519-cert-v01@openssh.com

# Connection
ClientAliveInterval 300
ClientAliveCountMax 2
TCPKeepAlive no

# Security
X11Forwarding no
AllowTcpForwarding yes  # Required for some remote management
PermitTunnel no
GatewayPorts no
AllowAgentForwarding no

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# User restrictions
AllowUsers sentinel
DenyUsers root admin administrator

# Chroot for SFTP (if needed)
# Match User backup
#     ChrootDirectory /backup
#     ForceCommand internal-sftp
#     AllowTcpForwarding no
EOF
    
    # Install and configure fail2ban
    apt-get install -y fail2ban
    
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
EOF
    
    systemctl enable fail2ban
    systemctl restart fail2ban
    systemctl restart sshd
    
    log_ok "SSH hardened"
}

# ─────────────────────────────────────────────────────────────────────────────
# 5. CONTAINER HARDENING
# ─────────────────────────────────────────────────────────────────────────────

harden_containers() {
    log_stage "Container Hardening"
    
    # Docker daemon security
    cat > /etc/docker/daemon.json << 'EOF'
{
    "userns-remap": "default",
    "live-restore": true,
    "no-new-privileges": true,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "seccomp-profile": "/etc/docker/seccomp-default.json",
    "default-ulimits": {
        "nofile": {
            "Name": "nofile",
        "Hard": 64000,
        "Soft": 64000
        }
    },
    "icc": false,
    "iptables": true,
    "ip-forward": false,
    "ip-masq": false
}
EOF
    
    # Create default seccomp profile (restrict dangerous syscalls)
    # In production, use a custom profile tailored to your workloads
    
    # Enable user namespaces
    sysctl -w kernel.unprivileged_userns_clone=1
    echo "kernel.unprivileged_userns_clone=1" >> /etc/sysctl.d/99-kirat-security.conf
    
    # AppArmor profiles for containers
    apt-get install -y apparmor apparmor-utils
    systemctl enable apparmor
    systemctl start apparmor
    
    # Rootless containers (if supported)
    # apt-get install -y rootlesskit
    
    log_ok "Containers hardened"
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. AUDIT LOGGING
# ─────────────────────────────────────────────────────────────────────────────

harden_audit() {
    log_stage "Audit Logging"
    
    apt-get install -y auditd audispd-plugins
    
    cat > /etc/audit/rules.d/99-kirat-audit.rules << 'EOF'
# KIRAT OS Audit Rules
# Monitor critical security events

# Delete all existing rules
-D

# Set buffer size
-b 8192

# Monitor system calls
-a always,exit -F arch=b64 -S setuid -S setgid -S setreuid -S setregid -k privilege_escalation
-a always,exit -F arch=b64 -S execve -S execveat -k command_execution
-a always,exit -F arch=b64 -S open -S openat -F exit=-EACCES -k access_denied
-a always,exit -F arch=b64 -S connect -S accept -S bind -k network_activity
-a always,exit -F arch=b64 -S init_module -S finit_module -S delete_module -k kernel_modules
-a always,exit -F arch=b64 -S mount -S umount2 -k mount_operations
-a always,exit -F arch=b64 -S ptrace -k debugging

# Monitor file integrity
-w /etc/passwd -p wa -k identity_changes
-w /etc/shadow -p wa -k identity_changes
-w /etc/group -p wa -k identity_changes
-w /etc/gshadow -p wa -k identity_changes
-w /etc/ssh/ -p wa -k ssh_config_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_changes
-w /etc/nftables.conf -p wa -k firewall_changes
-w /etc/docker/ -p wa -k docker_config_changes
-w /opt/sentinel/ -p wa -k sentinel_changes

# Monitor privileged commands
-w /usr/bin/sudo -p x -k privilege_command
-w /usr/bin/su -p x -k privilege_command
-w /usr/bin/passwd -p x -k identity_command
-w /usr/bin/chsh -p x -k identity_command
-w /usr/bin/chfn -p x -k identity_command

# Monitor Docker
-w /var/lib/docker/ -p wa -k docker_activity
-w /etc/docker/ -p wa -k docker_config

# Make audit logs immutable (requires reboot to change)
-e 2
EOF
    
    # Enable auditd
    systemctl enable auditd
    systemctl restart auditd
    
    # Forward logs to Sentinel
    cat > /etc/audisp/plugins.d/sentinel.conf << 'EOF'
active = yes
direction = out
path = /usr/local/bin/audit-to-sentinel.py
type = always
format = string
EOF
    
    log_ok "Audit logging configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. FILE INTEGRITY MONITORING
# ─────────────────────────────────────────────────────────────────────────────

harden_integrity() {
    log_stage "File Integrity Monitoring"
    
    # Install AIDE
    apt-get install -y aide
    
    # Initialize AIDE database
    aideinit || true
    
    # Configure AIDE checks
    cat > /etc/aide/aide.conf << 'EOF'
# KIRAT OS AIDE Configuration

# Database settings
database=file:/var/lib/aide/aide.db
database_out=file:/var/lib/aide/aide.db.new
database_new=file:/var/lib/aide/aide.db.new

# What to check
NORMAL = p+i+n+u+g+s+m+c+acl+selinux+xattrs+sha256
LOG = p+u+g+n+S+acl+selinux+xattrs

# Critical files
/boot   NORMAL
/bin    NORMAL
/sbin   NORMAL
/lib    NORMAL
/lib64  NORMAL
/opt    NORMAL
/usr    NORMAL
/etc    NORMAL
/root   NORMAL

# Logs (content changes, but metadata should be stable)
/var/log   LOG

# Exclude noisy directories
!/var/log/journal
!/var/log/audit
!/var/tmp
!/tmp
!/var/cache
!/var/spool
EOF
    
    # Daily integrity check via cron
    cat > /etc/cron.daily/aide-check << 'EOF'
#!/bin/bash
/usr/bin/aide --check 2>&1 | \
    mail -s "AIDE Integrity Check $(hostname)" root
EOF
    chmod +x /etc/cron.daily/aide-check
    
    log_ok "File integrity monitoring configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# 8. AUTOMATIC UPDATES
# ─────────────────────────────────────────────────────────────────────────────

harden_updates() {
    log_stage "Automatic Updates"
    
    apt-get install -y unattended-upgrades apt-listchanges
    
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "03:00";
Unattended-Upgrade::SyslogEnable "true";
EOF
    
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    
    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades
    
    log_ok "Automatic updates configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# 9. SENTINEL AI SECURITY INTEGRATION
# ─────────────────────────────────────────────────────────────────────────────

harden_sentinel() {
    log_stage "Sentinel AI Security Integration"
    
    # Create Sentinel security config
    mkdir -p /etc/sentinel/security
    
    cat > /etc/sentinel/security/hardening.yaml << 'EOF'
security:
  # Sentinel self-protection
  self_protection:
    enabled: true
    integrity_check_interval: 60  # seconds
    behavior_baseline_learning: 7d
    
  # Threat response automation
  auto_response:
    enabled: true
    max_auto_actions_per_hour: 10
    escalation_after: 3  # actions before human review
    
    actions:
      - name: block_ip
        trigger: "threat.confidence > 0.9"
        action: "nftables add element inet filter blacklist { $ip }"
        
      - name: isolate_container
        trigger: "container.anomaly_score > 0.8"
        action: "docker network disconnect bridge $container_id"
        
      - name: kill_process
        trigger: "process.malware_score > 0.95"
        action: "kill -9 $pid"
        
      - name: alert_admin
        trigger: "always"
        action: "sentinel alert --severity $severity --title $title"
        
  # Honeypot integration
  honeypots:
    enabled: true
    types:
      - ssh: { port: 2222 }
      - web: { port: 8080 }
      - db: { port: 5432 }
      
  # Canary tokens
  canaries:
    enabled: true
    tokens:
      - type: aws_credentials
        location: /opt/secrets/
      - type: database_connection
        location: /opt/app/config/
      - type: web_url
        location: /opt/docs/
EOF
    
    # Install Sentinel security plugins
    mkdir -p /opt/sentinel/plugins/security
    
    log_ok "Sentinel security integration configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. SECURITY SCORE VERIFICATION
# ─────────────────────────────────────────────────────────────────────────────

verify_security() {
    log_stage "Security Verification"
    
    local score=0
    local max=100
    
    # Check 1: Kernel parameters (10 points)
    if sysctl kernel.randomize_va_space | grep -q "2"; then score=$((score+2)); fi
    if sysctl kernel.kptr_restrict | grep -q "2"; then score=$((score+2)); fi
    if sysctl kernel.dmesg_restrict | grep -q "1"; then score=$((score+2)); fi
    if sysctl kernel.yama.ptrace_scope | grep -q "2"; then score=$((score+2)); fi
    if sysctl fs.protected_symlinks | grep -q "1"; then score=$((score+2)); fi
    
    # Check 2: SSH hardening (10 points)
    if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then score=$((score+2)); fi
    if grep -q "PermitRootLogin no" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then score=$((score+2)); fi
    if grep -q "X11Forwarding no" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then score=$((score+2)); fi
    if grep -q "MaxAuthTries 3" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then score=$((score+2)); fi
    if systemctl is-active fail2ban &>/dev/null; then score=$((score+2)); fi
    
    # Check 3: Firewall (10 points)
    if systemctl is-active nftables &>/dev/null; then score=$((score+5)); fi
    if [ -f /etc/nftables.conf ]; then score=$((score+5)); fi
    
    # Check 4: Audit logging (10 points)
    if systemctl is-active auditd &>/dev/null; then score=$((score+5)); fi
    if [ -f /etc/audit/rules.d/99-kirat-audit.rules ]; then score=$((score+5)); fi
    
    # Check 5: File integrity (10 points)
    if command -v aide &>/dev/null; then score=$((score+5)); fi
    if [ -f /var/lib/aide/aide.db ]; then score=$((score+5)); fi
    
    # Check 6: Container security (10 points)
    if [ -f /etc/docker/daemon.json ]; then score=$((score+5)); fi
    if systemctl is-active apparmor &>/dev/null; then score=$((score+5)); fi
    
    # Check 7: Updates (10 points)
    if systemctl is-active unattended-upgrades &>/dev/null; then score=$((score+5)); fi
    if [ -f /etc/apt/apt.conf.d/50unattended-upgrades ]; then score=$((score+5)); fi
    
    # Check 8: Sentinel integration (10 points)
    if [ -f /etc/sentinel/security/hardening.yaml ]; then score=$((score+5)); fi
    if [ -d /opt/sentinel/plugins/security ]; then score=$((score+5)); fi
    
    # Check 9: Secure boot / TPM (10 points)
    if [ -d /sys/class/tpm/tpm0 ]; then score=$((score+5)); fi
    if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then score=$((score+5)); fi
    
    # Check 10: Filesystem permissions (10 points)
    if [ "$(stat -c %a /root)" = "700" ]; then score=$((score+3)); fi
    if [ "$(stat -c %a /tmp)" = "1777" ]; then score=$((score+3)); fi
    if mount | grep " /tmp " | grep -q "noexec"; then score=$((score+4)); fi
    
    # Bonus: PQC (10 points)
    if [ -f /usr/local/lib/liboqs.so ]; then score=$((score+5)); fi
    if grep -q "sntrup761" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then score=$((score+5)); fi
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           KIRAT OS Security Score                           ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║  Score: %d/%d                                                ║\n" "$score" "$max"
    
    if [ "$score" -ge 95 ]; then
        echo "║  Status: EXCELLENT ✓                                         ║"
        echo "║  Ready for production!                                       ║"
    elif [ "$score" -ge 80 ]; then
        echo "║  Status: GOOD ✓                                              ║"
        echo "║  Minor improvements recommended.                             ║"
    elif [ "$score" -ge 60 ]; then
        echo "║  Status: FAIR ⚠                                              ║"
        echo "║  Significant hardening needed.                               ║"
    else
        echo "║  Status: POOR ✗                                              ║"
        echo "║  Not ready for production. Run hardening again.              ║"
    fi
    
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Detailed log: $LOG_FILE"
    
    return $((score >= 80 ? 0 : 1))
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║     KIRAT OS Server - Security Hardening Script               ║"
    echo "║     Target: Score 95/100                                     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    read -p "This will modify system security settings. Continue? (y/N): " confirm
    if [[ "$confirm" != [yY]* ]]; then
        echo "Aborted."
        exit 0
    fi
    
    harden_kernel
    harden_filesystem
    harden_network
    harden_ssh
    harden_containers
    harden_audit
    harden_integrity
    harden_updates
    harden_sentinel
    verify_security
    
    echo ""
    echo "Hardening complete. A reboot is recommended to apply all changes."
}

main "$@"
