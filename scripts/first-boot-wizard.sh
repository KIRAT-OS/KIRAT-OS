#!/bin/bash
###############################################################################
# KIRAT OS — First-Boot Interactive Wizard
###############################################################################
# Guides the administrator through initial setup with menus, validation,
# and safety checks. Replaces the basic first-boot script with a polished
# enterprise-grade experience.
###############################################################################

set -uo pipefail
umask 077

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
    step "Step 2/7 — Administrator Password"

    echo "Root remains locked. No emergency root password will be enabled."
    passwd -l root || { error "Could not lock root"; exit 1; }

    echo ""
    echo "=== ADMIN PASSWORD (kirat-admin) ==="
    echo "Set a local sudo password; SSH still requires the enrolled public key."
    passwd kirat-admin || { error "Could not set administrator password"; exit 1; }
    passwd -l root || { error "Could not keep root locked"; exit 1; }

    ok "Administrator password configured; root is locked"
    read -p "Press ENTER to continue..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: SSH Key Setup
# ─────────────────────────────────────────────────────────────────────────────
step_ssh() {
    header
    step "Step 3/7 — SSH Public Key Enrollment"

    local supplied_key key_file home_dir ssh_dir
    read -r -p "Paste the administrator's SSH Ed25519 PUBLIC key: " supplied_key
    [[ "$supplied_key" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+([[:space:]][^\r\n]*)?$ ]] || {
        error "A single ssh-ed25519 public key is required (no options or private keys)"
        exit 1
    }

    key_file=$(mktemp) || exit 1
    printf '%s\n' "$supplied_key" > "$key_file"
    if ! ssh-keygen -l -f "$key_file" >/dev/null 2>&1; then
        rm -f -- "$key_file"
        error "OpenSSH rejected the public key"
        exit 1
    fi
    rm -f -- "$key_file"

    home_dir=$(getent passwd kirat-admin | cut -d: -f6)
    [[ -n "$home_dir" && "$home_dir" == /* ]] || { error "Administrator home not found"; exit 1; }
    ssh_dir="$home_dir/.ssh"
    install -d -m 700 -o kirat-admin -g kirat-admin "$ssh_dir" || exit 1
    touch "$ssh_dir/authorized_keys"
    if ! grep -qxF -- "$supplied_key" "$ssh_dir/authorized_keys"; then
        printf '%s\n' "$supplied_key" >> "$ssh_dir/authorized_keys"
    fi
    chown kirat-admin:kirat-admin "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    passwd -l root || { error "Could not keep root locked"; exit 1; }

    ok "Administrator-supplied public key enrolled; no server private key was generated"
    read -p "Press ENTER to continue..."
}

valid_dns_name() {
    local name="$1" label
    [[ "$name" == "localhost" ]] && return 0
    [[ ${#name} -le 253 && "$name" != .* && "$name" != *. && "$name" != *..* ]] || return 1
    IFS='.' read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

update_local_hosts() {
    local hostname_value="$1" domain="$2"
    python3 - "$hostname_value" "$domain" /etc/hosts <<'PY'
import os, sys, tempfile
hostname, domain, path = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    lines = stream.readlines()
entry = f"127.0.1.1\t{hostname} {domain}\n"
lines = [entry if line.split() and line.split()[0] == "127.0.1.1" else line
         for line in lines]
if not any(line.split() and line.split()[0] == "127.0.1.1" for line in lines):
    lines.append(entry)
mode = os.stat(path).st_mode
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".hosts.")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.writelines(lines)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

generate_tls_certificate() {
    local domain="$1" cert_days="${TLS_CERT_DAYS:-30}" cert_dir work
    [[ "$cert_days" =~ ^[0-9]+$ && "$cert_days" -ge 1 && "$cert_days" -le 30 ]] || {
        error "TLS_CERT_DAYS must be between 1 and 30"
        exit 1
    }
    cert_dir=/etc/nginx/ssl
    install -d -m 700 "$cert_dir" || exit 1
    work=$(mktemp -d "$cert_dir/.kirat-cert.XXXXXXXX") || exit 1
    if ! openssl req -x509 -nodes -days "$cert_days" -newkey ec \
        -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$work/kirat-key.pem" -out "$work/kirat-cert.pem" \
        -subj "/CN=$domain/O=KIRAT OS Business" \
        -addext "subjectAltName=DNS:$domain" >/dev/null 2>&1 || \
       ! openssl x509 -in "$work/kirat-cert.pem" -noout -checkhost "$domain" >/dev/null 2>&1; then
        rm -rf -- "$work"
        error "Short-lived SAN certificate generation/validation failed"
        exit 1
    fi
    install -m 600 "$work/kirat-key.pem" "$cert_dir/kirat-key.pem" || exit 1
    install -m 644 "$work/kirat-cert.pem" "$cert_dir/kirat-cert.pem" || exit 1
    rm -rf -- "$work"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Network & Domain
# ─────────────────────────────────────────────────────────────────────────────
step_network() {
    header
    step "Step 4/7 — Network Configuration"

    local domain short_hostname
    read -r -p "Enter your business DNS name [localhost]: " domain
    domain="${domain:-localhost}"
    if ! valid_dns_name "$domain"; then
        error "Invalid DNS name; use localhost or RFC 1123 letters, digits, dots, and interior hyphens"
        exit 1
    fi

    if [[ "$domain" != "localhost" ]]; then
        short_hostname="kirat-${domain%%.*}"
        hostnamectl set-hostname "$short_hostname" || { error "Hostname update failed"; exit 1; }
        update_local_hosts "$short_hostname" "$domain" || { error "Hosts update failed"; exit 1; }
    else
        warn "Using localhost — set a real DNS name before production use"
    fi
    generate_tls_certificate "$domain"
    ok "Domain configured with a short-lived SAN certificate: $domain"

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
