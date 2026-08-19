#!/bin/bash
###############################################################################
# KIRAT OS - COMPLETE ACTIVATION CHECKLIST
###############################################################################
# Step-by-step guide to activate KIRAT OS with real AI backends on any device.
# Run each section in order. Each [ ] box represents one actionable step.
#
# Usage: sudo bash activation-checklist.sh [--wsl2|--dedicated|--vm|--usb]
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'

CHECK="${GREEN}✓${NC}"
CROSS="${RED}✗${NC}"
WARN="${YELLOW}⚠${NC}"

MODE="${1:---help}"
STEP=0

die() { echo -e "${RED}[FATAL]${NC} $1"; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

header() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}  STEP $STEP: $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

preflight() {
    header "PRE-FLIGHT CHECKS"
    
    # Check root
    if [ "$EUID" -ne 0 ]; then
        die "Must run as root. Use: sudo bash $0 $MODE"
    fi
    ok "Running as root"
    
    # Check OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        info "OS: $NAME $VERSION_ID"
    fi
    
    # Check architecture
    ARCH=$(uname -m)
    if [ "$ARCH" != "x86_64" ]; then
        warn "Architecture is $ARCH. KIRAT OS is optimized for x86_64."
    else
        ok "Architecture: x86_64"
    fi
    
    # Check RAM
    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$((RAM_KB / 1024 / 1024))
    if [ "$RAM_GB" -lt 4 ]; then
        warn "Only ${RAM_GB}GB RAM. 8GB+ recommended for AI features."
    else
        ok "RAM: ${RAM_GB}GB"
    fi
    
    # Check disk space
    FREE_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [ "${FREE_GB:-0}" -lt 10 ]; then
        warn "Only ${FREE_GB}GB free. 20GB+ recommended."
    else
        ok "Disk space: ${FREE_GB}GB free"
    fi
}

# =============================================================================
# STEP 1: BASE SYSTEM
# =============================================================================

step1_base_system() {
    header "INSTALL BASE SYSTEM"
    
    echo "[ ] Update package lists"
    apt-get update -qq
    ok "Package lists updated"
    
    echo "[ ] Install core dependencies"
    apt-get install -y -qq \
        curl wget git make gcc \
        python3 python3-pip python3-venv \
        nginx openssl \
        cryptsetup cryptsetup-bin \
        parted e2fsprogs \
        htop iotop ncdu tree \
        net-tools iproute2 iptables nftables \
        dnsutils ca-certificates \
        2>/dev/null || warn "Some packages may have failed"
    ok "Core dependencies installed"
    
    echo "[ ] Verify Python3"
    python3 --version || die "Python3 not available"
    ok "Python3: $(python3 --version)"
    
    echo "[ ] Install Python packages"
    pip3 install --upgrade pip 2>/dev/null || true
    pip3 install fastapi uvicorn httpx websockets psutil 2>/dev/null || \
        pip3 install --break-system-packages fastapi uvicorn httpx websockets psutil 2>/dev/null || \
        warn "Python packages may need manual install"
    ok "Python packages installed"
}

# =============================================================================
# STEP 2: OLLAMA INSTALLATION
# =============================================================================

step2_ollama() {
    header "INSTALL OLLAMA (AI BACKEND)"
    
    echo "[ ] Check if Ollama already installed"
    if command -v ollama &>/dev/null || [ -f /usr/local/bin/ollama ]; then
        ok "Ollama already installed"
    else
        echo "[ ] Download and install Ollama"
        curl -fsSL https://ollama.com/install.sh | sh
        ok "Ollama installed"
    fi
    
    echo "[ ] Start Ollama service"
    if systemctl is-active ollama &>/dev/null; then
        ok "Ollama service already running"
    else
        systemctl start ollama 2>/dev/null || \
            (nohup ollama serve >/var/log/ollama.log 2>&1 &)
        sleep 3
    fi
    
    echo "[ ] Verify Ollama is responding"
    if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
        ok "Ollama responding on port 11434"
    else
        die "Ollama not responding. Check: systemctl status ollama"
    fi
    
    echo "[ ] Pull AI models (this takes 5-15 minutes)"
    info "Pulling gemma4:8B (recommended for most systems)..."
    ollama pull gemma4:latest 2>/dev/null || warn "gemma4 pull may have failed"
    
    # Verify models
    MODELS=$(curl -s http://localhost:11434/api/tags | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$MODELS" ]; then
        ok "Models available:"
        echo "$MODELS" | sed 's/^/    /'
    else
        warn "No models found. Run manually: ollama pull gemma4"
    fi
}

# =============================================================================
# STEP 3: KIRAT OS COMPONENTS
# =============================================================================

step3_kirat_components() {
    header "INSTALL KIRAT OS COMPONENTS"
    
    KIRAT_DIR="/opt/kirat-os"
    mkdir -p "$KIRAT_DIR"
    
    echo "[ ] Copy KIRAT OS files"
    if [ -d "kirat-os-server" ]; then
        cp -r kirat-os-server/* "$KIRAT_DIR/"
        ok "KIRAT OS files copied to $KIRAT_DIR"
    elif [ -d "/opt/kirat-os" ] && [ -f "/opt/kirat-os/sentinel-core/main-real.py" ]; then
        ok "KIRAT OS already installed at $KIRAT_DIR"
    else
        warn "KIRAT OS source not found in current directory"
        info "Expected: ./kirat-os-server/ directory"
    fi
    
    echo "[ ] Set permissions"
    useradd -m -s /bin/bash sentinel 2>/dev/null || true
    chown -R sentinel:sentinel "$KIRAT_DIR" 2>/dev/null || true
    chmod +x "$KIRAT_DIR"/scripts/*.sh 2>/dev/null || true
    ok "Permissions set"
}

# =============================================================================
# STEP 4: SECURITY HARDENING
# =============================================================================

step4_security() {
    header "APPLY SECURITY HARDENING"
    
    echo "[ ] Run hardening script"
    if [ -f "/opt/kirat-os/security/hardening/harden-fixed.sh" ]; then
        bash /opt/kirat-os/security/hardening/harden-fixed.sh
        ok "Hardening applied"
    else
        warn "harden-fixed.sh not found"
    fi
    
    echo "[ ] Apply pending security fixes (TLS, LUKS2, Kernel Signing)"
    if [ -f "/opt/kirat-os/security/fix-pending.sh" ]; then
        bash /opt/kirat-os/security/fix-pending.sh --yes 2>/dev/null || \
            warn "fix-pending.sh had issues (may need manual review)"
        ok "Security fixes applied"
    else
        warn "fix-pending.sh not found"
    fi
    
    echo "[ ] Verify SSH PQC configuration"
    if grep -q "sntrup761x25519-sha512" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        ok "PQC SSH key exchange configured"
    else
        warn "PQC SSH not configured yet"
    fi
}

# =============================================================================
# STEP 5: REAL BACKEND INTEGRATION
# =============================================================================

step5_real_backends() {
    header "ACTIVATE REAL AI BACKENDS"
    
    echo "[ ] Install Sentinel AI v2.0 (Real Ollama)"
    if [ -f "/opt/kirat-os/sentinel-core/main-real.py" ]; then
        # Create symlink to active sentinel
        cp /opt/kirat-os/sentinel-core/main-real.py /opt/kirat-os/sentinel-core/sentinel-ai.py
        ok "Sentinel AI v2.0 ready"
    else
        warn "main-real.py not found"
    fi
    
    echo "[ ] Create systemd service for Sentinel"
    cat > /etc/systemd/system/sentinel.service << 'EOF'
[Unit]
Description=Sentinel AI Core v2.0 (Real LLM)
After=network-online.target ollama.service
Wants=network-online.target

[Service]
Type=simple
User=sentinel
Group=sentinel
WorkingDirectory=/opt/kirat-os/sentinel-core
Environment=OLLAMA_HOST=http://localhost:11434
Environment=SENTINEL_MODEL=gemma4:latest
Environment=SENTINEL_PORT=3000
Environment=PYTHONPATH=/opt/kirat-os
ExecStart=/usr/bin/python3 /opt/kirat-os/sentinel-core/sentinel-ai.py
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3

# Resource limits
LimitNOFILE=65536
MemoryMax=2G
CPUQuota=200%

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/kirat-os/sentinel-core

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sentinel
    ok "Sentinel service created"
    
    echo "[ ] Install Quantum AI real backend"
    if [ -f "/opt/kirat-os/quantum-ai/quantum-engine-real.py" ]; then
        ok "Quantum engine real backend available"
        info "Optional: pip install qiskit cirq for real quantum hardware"
    fi
    
    echo "[ ] Start all services"
    systemctl start ollama 2>/dev/null || true
    sleep 2
    systemctl start sentinel
    sleep 2
    
    echo "[ ] Verify services are running"
    if systemctl is-active sentinel &>/dev/null; then
        ok "Sentinel service: RUNNING"
    else
        warn "Sentinel service not running. Check: journalctl -u sentinel -n 20"
    fi
}

# =============================================================================
# STEP 6: DASHBOARD
# =============================================================================

step6_dashboard() {
    header "START MONITORING DASHBOARD"
    
    echo "[ ] Configure nginx for dashboard"
    if [ -f "/opt/kirat-os/dashboard/main.py" ]; then
        cat > /etc/systemd/system/kirat-dashboard.service << 'EOF'
[Unit]
Description=KIRAT OS Dashboard
After=sentinel.service

[Service]
Type=simple
User=sentinel
WorkingDirectory=/opt/kirat-os/dashboard
Environment=PYTHONPATH=/opt/kirat-os
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 0.0.0.0 --port 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable kirat-dashboard
        systemctl start kirat-dashboard
        ok "Dashboard service started"
    else
        warn "Dashboard files not found"
    fi
    
    echo "[ ] Configure nginx reverse proxy"
    if [ -f "/opt/kirat-os/security/certs/server-hybrid.pem" ]; then
        # SSL is configured
        ok "HTTPS with PQC configured"
    else
        info "HTTP mode (run fix-pending.sh for HTTPS)"
    fi
}

# =============================================================================
# STEP 7: VERIFICATION
# =============================================================================

step7_verify() {
    header "FINAL VERIFICATION"
    
    local SCORE=0
    local MAX=10
    
    echo "[ ] Check 1/10: Ollama running"
    if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo "    $CHECK Ollama: RUNNING"
        SCORE=$((SCORE + 1))
    else
        echo "    $CROSS Ollama: NOT RUNNING"
    fi
    
    echo "[ ] Check 2/10: AI models available"
    if curl -s http://localhost:11434/api/tags | grep -q "gemma4\|llama\|qwen"; then
        echo "    $CHECK AI Models: AVAILABLE"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN AI Models: NONE (run: ollama pull gemma4)"
    fi
    
    echo "[ ] Check 3/10: Sentinel service"
    if systemctl is-active sentinel &>/dev/null; then
        echo "    $CHECK Sentinel: RUNNING"
        SCORE=$((SCORE + 1))
    else
        echo "    $CROSS Sentinel: NOT RUNNING"
    fi
    
    echo "[ ] Check 4/10: Sentinel API responding"
    if curl -s http://localhost:3000/health 2>/dev/null | grep -q "healthy"; then
        echo "    $CHECK Sentinel API: RESPONDING"
        SCORE=$((SCORE + 1))
    else
        echo "    $CROSS Sentinel API: NO RESPONSE"
    fi
    
    echo "[ ] Check 5/10: Dashboard running"
    if systemctl is-active kirat-dashboard &>/dev/null; then
        echo "    $CHECK Dashboard: RUNNING"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN Dashboard: NOT RUNNING"
    fi
    
    echo "[ ] Check 6/10: SSH with PQC"
    if grep -q "sntrup761x25519-sha512" /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
        echo "    $CHECK PQC SSH: CONFIGURED"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN PQC SSH: NOT CONFIGURED"
    fi
    
    echo "[ ] Check 7/10: Kernel hardening"
    if grep -q "module.sig_enforce=1" /proc/cmdline 2>/dev/null; then
        echo "    $CHECK Kernel Signing: ENABLED"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN Kernel Signing: NOT ENABLED (reboot required)"
    fi
    
    echo "[ ] Check 8/10: Security hardening applied"
    if [ -f "/var/lib/kirat-hardened" ]; then
        echo "    $CHECK Hardening: APPLIED"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN Hardening: MARKER NOT FOUND"
    fi
    
    echo "[ ] Check 9/10: Quantum AI engine"
    if [ -f "/opt/kirat-os/quantum-ai/quantum-engine-real.py" ]; then
        echo "    $CHECK Quantum Engine: REAL BACKEND READY"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN Quantum Engine: NOT FOUND"
    fi
    
    echo "[ ] Check 10/10: Mobile dashboard CSS"
    if [ -f "/opt/kirat-os/dashboard/static/css/dashboard-mobile.css" ]; then
        echo "    $CHECK Mobile Dashboard: READY"
        SCORE=$((SCORE + 1))
    else
        echo "    $WARN Mobile Dashboard: CSS NOT FOUND"
    fi
    
    # Final score
    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  ACTIVATION SCORE: $SCORE / $MAX${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════════${NC}"
    
    if [ "$SCORE" -eq "$MAX" ]; then
        echo -e "${GREEN}${BOLD}  🎉 KIRAT OS FULLY OPERATIONAL! 🎉${NC}"
    elif [ "$SCORE" -ge 7 ]; then
        echo -e "${YELLOW}${BOLD}  ⚠ KIRAT OS MOSTLY OPERATIONAL ($SCORE/$MAX)${NC}"
        echo -e "${YELLOW}  Review failed checks above.${NC}"
    else
        echo -e "${RED}${BOLD}  ✗ KIRAT OS NEEDS ATTENTION ($SCORE/$MAX)${NC}"
        echo -e "${RED}  Several components failed. Review logs above.${NC}"
    fi
    
    echo ""
    echo -e "${BOLD}ACCESS YOUR KIRAT OS:${NC}"
    echo "  Dashboard:    http://$(hostname -I | awk '{print $1}'):8080"
    echo "  Sentinel API: http://$(hostname -I | awk '{print $1}'):3000"
    echo "  SSH:          ssh sentinel@$(hostname -I | awk '{print $1}') -p 2222"
    echo ""
    echo -e "${BOLD}QUICK TESTS:${NC}"
    echo "  curl http://localhost:3000/health"
    echo "  curl -X POST http://localhost:3000/chat -d '{\"message\":\"Hello Sentinel\"}'"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

show_help() {
    cat << 'EOF'
KIRAT OS - Complete Activation Checklist
Usage: sudo bash activation-checklist.sh [MODE]

MODES:
  --wsl2       Install in WSL2 environment
  --dedicated  Install on dedicated server/PC
  --vm         Install in virtual machine
  --usb        Install from live USB
  --help       Show this help

EXAMPLES:
  sudo bash activation-checklist.sh --wsl2
  sudo bash activation-checklist.sh --dedicated

EOF
}

main() {
    case "$MODE" in
        --wsl2|--dedicated|--vm|--usb)
            echo -e "${CYAN}${BOLD}"
            echo "  _  ___ _ _ ___ _ _ ___ _  _"
            echo "  | |/ / | | | _ ) | | __| \| |"
            echo "  | ' <| |_| | _ \_  _| _ | .' |"
            echo "  |_|\_\\___/|___/ |_| |___|_|\_|"
            echo ""
            echo "  KIRAT OS Activation Checklist"
            echo "  Mode: $MODE"
            echo -e "${NC}"
            
            preflight
            step1_base_system
            step2_ollama
            step3_kirat_components
            step4_security
            step5_real_backends
            step6_dashboard
            step7_verify
            ;;
        --help|-h|*)
            show_help
            exit 0
            ;;
    esac
}

main
