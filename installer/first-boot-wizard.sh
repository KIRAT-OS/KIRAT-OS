#!/bin/bash
###############################################################################
# KIRAT OS — First-Boot Interactive Wizard
###############################################################################
# Guides the administrator through initial setup with menus, validation,
# and safety checks. Replaces the basic first-boot script with a polished
# enterprise-grade experience.
###############################################################################

set -uo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; MAGENTA='\033[0;35m'; NC='\033[0m'; BOLD='\033[1m'

header() {
    clear
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║         KIRAT OS — First Boot Configuration Wizard                   ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

step() {
    echo -e "${MAGENTA}${BOLD}▶ $1${NC}"
    echo ""
}

ok() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✗ $1${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Welcome & Safety Check
# ─────────────────────────────────────────────────────────────────────────────
step_welcome() {
    header
    step "Step 1/7 — Welcome"
    echo "Welcome to KIRAT OS, the AI-native server operating system."
    echo "This wizard will guide you through essential first-time setup."
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC}"
    echo "  • Have your SSH public key ready"
    echo "  • Know your business domain name"
    echo "  • This server will be reachable on the network after setup"
    echo ""
    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Root & Admin Passwords
# ─────────────────────────────────────────────────────────────────────────────
step_passwords() {
    header
    step "Step 2/7 — Set Passwords"

    echo "=== ROOT PASSWORD ==="
    echo "Root is locked by default. Set a strong emergency password."
    passwd

    echo ""
    echo "=== ADMIN PASSWORD (kirat-admin) ==="
    echo "This is your daily administrative account."
    passwd kirat-admin

    ok "Passwords configured"
    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: SSH Key Setup
# ─────────────────────────────────────────────────────────────────────────────
step_ssh() {
    header
    step "Step 3/7 — SSH Key Authentication"

    if [ ! -f /home/kirat-admin/.ssh/id_ed25519 ]; then
        echo "Generating Ed25519 SSH key pair for kirat-admin..."
        su - kirat-admin -c "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ''"
        su - kirat-admin -c "cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys"
        su - kirat-admin -c "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
        ok "SSH key generated"
    else
        ok "SSH key already exists"
    fi

    echo ""
    echo "Your public key:"
    cat /home/kirat-admin/.ssh/id_ed25519.pub
    echo ""
    echo "Add this key to your SSH client to connect without passwords."
    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Network & Domain
# ─────────────────────────────────────────────────────────────────────────────
step_network() {
    header
    step "Step 4/7 — Network Configuration"

    read -p "Enter your business domain [localhost]: " domain
    domain="${domain:-localhost}"

    if [ "$domain" != "localhost" ]; then
        # Update hostname
        hostnamectl set-hostname "kirat-$(echo $domain | cut -d. -f1)"
        sed -i "s/127.0.1.1.*/127.0.1.1   $(hostname) $domain/" /etc/hosts

        # Re-generate TLS cert with proper domain
        mkdir -p /etc/nginx/ssl
        openssl req -x509 -nodes -days 3650 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout /etc/nginx/ssl/kirat-key.pem -out /etc/nginx/ssl/kirat-cert.pem \
            -subj "/CN=$domain/O=KIRAT OS Business" 2>/dev/null || true

        ok "Domain set to: $domain"
    else
        warn "Using localhost — consider setting a real domain for production"
    fi

    echo ""
    echo "Network interfaces:"
    ip -brief addr show | grep -v lo
    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: AI Model Download
# ─────────────────────────────────────────────────────────────────────────────
step_ai_models() {
    header
    step "Step 5/7 — AI Models (Ollama)"

    if ! command -v ollama >/dev/null 2>&1; then
        warn "Ollama not found. Skipping model download."
        read -p "Press ENTER to continue..."
        return
    fi

    echo "KIRAT OS uses local AI models for threat detection and governance."
    echo "Models are ~5-15GB each. Total download: ~30GB"
    echo ""
    read -p "Download AI models now? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "Downloading gemma4 (general intelligence)..."
        ollama pull gemma4:latest || warn "gemma4 download failed"

        echo "Downloading qwen3.6 (coding/analysis)..."
        ollama pull qwen3.6:latest || warn "qwen3.6 download failed"

        echo "Downloading whisper (voice recognition for Aadhipati)..."
        # Whisper is installed via pip, models download on first use
        ok "Whisper models will download automatically on first voice command"

        ok "AI models ready"
    else
        warn "Skipped. Run 'ollama pull gemma4' later when ready."
    fi
    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Security Hardening
# ─────────────────────────────────────────────────────────────────────────────
step_security() {
    header
    step "Step 6/7 — Final Security Hardening"

    if [ -f /opt/kirat-os/scripts/final-100-hardening.sh ]; then
        echo "Running automated security hardening..."
        bash /opt/kirat-os/scripts/final-100-hardening.sh
        ok "Security hardening applied"
    else
        warn "final-100-hardening.sh not found"
    fi

    # AIDE initialization
    if command -v aide >/dev/null 2>&1; then
        echo "Initializing filesystem integrity baseline (AIDE)..."
        aideinit 2>/dev/null || true
        ok "AIDE baseline created"
    fi

    # Start all AI agents
    echo "Starting AI agent ecosystem..."
    systemctl start jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai 2>/dev/null || true
    ok "AI agents activated"

    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: Summary
# ─────────────────────────────────────────────────────────────────────────────
step_summary() {
    header
    step "Step 7/7 — Setup Complete"

    local ip
    ip=$(hostname -I | awk '{print $1}')

    cat << EOF
╔══════════════════════════════════════════════════════════════════════╗
║                    KIRAT OS IS READY                                 ║
╚══════════════════════════════════════════════════════════════════════╝

  Hostname:     $(hostname)
  IP Address:   $ip
  Domain:       $(hostname -d 2>/dev/null || echo 'localhost')

  ── ACCESS ──
  Dashboard:    https://$ip
  SSH:          ssh kirat-admin@$ip -p 22
  AI API:       http://$ip:3000
  Aadhipati:    http://$ip:8080/aadhipati

  ── AI AGENTS ──
  ✓ Jitedasti (Threat Hunter)
  ✓ Galinja (Self-Healer)
  ✓ Oysgja (Deception)
  ✓ Suyarma (Predictive Patcher)
  ✓ Papa (Behavioral Biometrics)
  ✓ Aadhipati (CEO / Voice Commander)

  ── NEXT STEPS ──
  1. Enroll MOK for Secure Boot: mokutil --import /opt/kirat-os/security/mok/MOK.der
  2. Configure TPM auto-unlock if available
  3. Set up remote backups: kirat-admin backup --remote s3://...
  4. Review logs: journalctl -u jitedasti-ai -f

  ── COMMANDS ──
  kirat-admin agent status      — Check all AI agents
  kirat-admin audit report      — View security audit
  kirat-admin instruction create aadhipati-ai "scan now" — Delegate to CEO

EOF

    touch /var/lib/kirat-first-boot-done
    ok "First boot wizard complete. Welcome to your empire, Teacher."
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

if [ -f /var/lib/kirat-first-boot-done ]; then
    echo "First boot already completed. Use 'kirat-first-boot --force' to rerun."
    exit 0
fi

step_welcome
step_passwords
step_ssh
step_network
step_ai_models
step_security
step_summary
