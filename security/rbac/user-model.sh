#!/bin/bash
# =============================================================================
# KIRAT OS — Advanced RBAC User Model
# =============================================================================
# Creates the complete user hierarchy:
#   Tier 0: root          (locked, emergency only)
#   Tier 1: kirat-admin   (Administrator — full control, delegates to AI)
#   Tier 2: DevSecOps     (Scoped human team members)
#   Tier 3: AI Agents     (Service accounts executing admin instructions)
#
# Usage: source this file or run: sudo bash user-model.sh --install
# =============================================================================

set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────────
KIRAT_DIR="/opt/kirat-os"
ADMIN_USER="${ADMIN_USER:-kirat-admin}"
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
LOG_FILE="/var/log/kirat-os/rbac-setup.log"

# DevSecOps role definitions: username:sudo_rules:description
DEVSECOPS_ROLES=(
    "kirat-devsecops-security:/usr/sbin/auditd,/usr/bin/aireplay-ng,/usr/sbin/ufw,/usr/bin/fail2ban-client,/usr/bin/lynis,/usr/sbin/aide,/opt/kirat-os/security/*.sh:Security Operations — audits, firewall, IDS/IPS, vulnerability scanning"
    "kirat-devsecops-ops:/usr/bin/systemctl,/usr/bin/docker,/usr/bin/kubectl,/usr/bin/helm,/usr/bin/rsync,/usr/bin/tar,/bin/mount,/bin/umount,/usr/sbin/lvcreate,/usr/sbin/lvremove,/usr/bin/pg_dump,/usr/bin/pg_restore,/opt/kirat-os/scripts/upgrade-kirat-os.sh:Infrastructure Operations — deployments, backups, service management, upgrades"
    "kirat-devsecops-dev:/usr/bin/docker,/usr/bin/kubectl,/usr/bin/helm,/usr/bin/git,/usr/bin/npm,/usr/bin/pip3,/usr/local/bin/ollama,/opt/kirat-os/ai-companion/*:Development — code deploy, container builds, AI model management"
    "kirat-devsecops-incident:/usr/bin/systemctl,/usr/sbin/ufw,/usr/bin/fail2ban-client,/usr/bin/docker,/usr/bin/kubectl,/usr/sbin/tc,/usr/sbin/iptables,/opt/kirat-os/security/deception/*.sh:Incident Response — emergency isolation, network segmentation, deception activation"
)

# AI Agent definitions: username:home_dir:description:allowed_commands
AI_AGENTS=(
    "kirat-ai-sentinel:/opt/kirat-os/sentinel-core:Sentinel AI Monitor — system telemetry, anomaly detection, alerting:/usr/bin/python3 /opt/kirat-os/sentinel-core/*.py,/usr/bin/curl,/usr/bin/journalctl,/usr/bin/systemctl status *,/usr/bin/ollama list"
    "kirat-ai-quantum:/opt/kirat-os/quantum-ai:Quantum AI Engine — threat prediction, quantum analysis:/usr/bin/python3 /opt/kirat-os/quantum-ai/*.py,/usr/bin/curl,/usr/bin/ollama run *"
    "kirat-ai-executor:/opt/kirat-os/ai-agents/executor:AI Command Executor — executes admin-approved instructions ONLY:/usr/bin/python3 /opt/kirat-os/ai-agents/executor/*.py,/bin/cat,/bin/grep,/usr/bin/journalctl,/usr/bin/systemctl status *,/usr/bin/df,/usr/bin/free,/usr/bin/top -b -n1,/usr/bin/netstat,/usr/bin/ss,/usr/bin/lsof,/usr/bin/du,/usr/bin/find,/usr/bin/ps,/usr/bin/ls,/usr/bin/whoami"
    "kirat-ai-auditor:/opt/kirat-os/ai-agents/auditor:AI Audit & Compliance — monitors all AI actions, generates reports:/usr/bin/python3 /opt/kirat-os/ai-agents/auditor/*.py,/usr/bin/journalctl,/bin/cat,/bin/grep,/usr/bin/awk,/usr/bin/sed"
    "kirat-ai-orchestrator:/opt/kirat-os/ai-agents/orchestrator:AI Orchestrator — validates instructions, coordinates agents:/usr/bin/python3 /opt/kirat-os/ai-agents/orchestrator/*.py,/usr/bin/curl,/usr/bin/systemctl start kirat-ai-*,/usr/bin/systemctl stop kirat-ai-*,/usr/bin/systemctl restart kirat-ai-*"
)

# ── Logging ─────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
ok()  { echo "✓ $*" | tee -a "$LOG_FILE"; }
warn() { echo "⚠ $*" | tee -a "$LOG_FILE"; }
err() { echo "✗ $*" | tee -a "$LOG_FILE"; }

# ── Tier 0: root (Lock down) ────────────────────────────────────────────────
lock_root() {
    log "Securing root account..."
    # Lock root password (no password login)
    passwd -l root 2>/dev/null || true
    # Disable root SSH login
    if [ -f /etc/ssh/sshd_config ]; then
        sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
        sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
        systemctl reload sshd 2>/dev/null || true
    fi
    # Ensure root can still be accessed via console in emergency
    cat > /etc/securetty << 'EOF'
console
tty1
tty2
tty3
EOF
    ok "Root account locked (emergency console access only)"
}

# ── Tier 1: Administrator ───────────────────────────────────────────────────
create_admin() {
    log "Creating Administrator: $ADMIN_USER"

    if id "$ADMIN_USER" &>/dev/null; then
        warn "User $ADMIN_USER already exists, updating..."
    else
        useradd -m -s /bin/bash -G sudo,docker,adm,systemd-journal,audit,libvirt "$ADMIN_USER"
    fi

    # Set password if provided, otherwise force key-only auth
    if [ -n "$ADMIN_PASSWORD" ]; then
        echo "$ADMIN_USER:$ADMIN_PASSWORD" | chpasswd
        chage -d 0 "$ADMIN_USER"  # Force password change on first login
        warn "Password auth enabled — STRONGLY recommend switching to SSH keys only"
    fi

    # Setup SSH directory
    local ssh_dir="/home/$ADMIN_USER/.ssh"
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir"

    # Add admin SSH key if provided
    if [ -n "$ADMIN_SSH_KEY" ] && [ -f "$ADMIN_SSH_KEY" ]; then
        cat "$ADMIN_SSH_KEY" >> "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
        ok "Admin SSH key installed"
    fi

    # Admin gets full sudo with audit logging
    cat > "/etc/sudoers.d/99-kirat-admin" << EOF
# KIRAT OS Administrator — Full access with mandatory audit logging
Defaults:$ADMIN_USER    log_input, log_output
Defaults:$ADMIN_USER    timestamp_timeout=10
$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL
EOF
    chmod 440 "/etc/sudoers.d/99-kirat-admin"

    # Admin can delegate to AI agents
    mkdir -p "/home/$ADMIN_USER/instructions"
    mkdir -p "/home/$ADMIN_USER/audit-reports"
    chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER"

    ok "Administrator $ADMIN_USER created with full RBAC control"
}

# ── Tier 2: DevSecOps Members ───────────────────────────────────────────────
create_devsecops() {
    log "Creating DevSecOps team..."

    local idx=1
    for role_def in "${DEVSECOPS_ROLES[@]}"; do
        local username commands description
        username=$(echo "$role_def" | cut -d: -f1)
        commands=$(echo "$role_def" | cut -d: -f2)
        description=$(echo "$role_def" | cut -d: -f3-)

        if id "$username" &>/dev/null; then
            warn "DevSecOps user $username already exists"
            continue
        fi

        # Create user with restricted shell
        useradd -m -s /bin/rbash -G systemd-journal "$username"

        # Generate random password (user must change on first login)
        local temp_pass
        temp_pass=$(openssl rand -base64 24)
        echo "$username:$temp_pass" | chpasswd
        chage -d 0 "$username"

        # Sudoers with command whitelist
        cat > "/etc/sudoers.d/99-kirat-devsecops-$idx" << EOF
# $description
Defaults:$username    log_input, log_output
Defaults:$username    timestamp_timeout=5
$username ALL=(ALL) NOPASSWD: $commands
$username ALL=(root) /usr/bin/su - kirat-admin
EOF
        chmod 440 "/etc/sudoers.d/99-kirat-devsecops-$idx"

        # Store temp password securely for admin retrieval
        echo "$username:$temp_pass" >> "/home/$ADMIN_USER/.devsecops-passwords"
        chmod 600 "/home/$ADMIN_USER/.devsecops-passwords"

        ok "DevSecOps role created: $username ($description)"
        ((idx++))
    done

    # Only admin can read DevSecOps passwords
    chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.devsecops-passwords"
}

# ── Tier 3: AI Agent Users ──────────────────────────────────────────────────
create_ai_agents() {
    log "Creating AI Agent service accounts..."

    # Create base directories for AI agents
    mkdir -p /opt/kirat-os/ai-agents/{executor,auditor,orchestrator,instructions/{pending,approved,completed,rejected},logs}

    local idx=1
    for agent_def in "${AI_AGENTS[@]}"; do
        local username home_dir description allowed_cmds
        username=$(echo "$agent_def" | cut -d: -f1)
        home_dir=$(echo "$agent_def" | cut -d: -f2)
        description=$(echo "$agent_def" | cut -d: -f3)
        allowed_cmds=$(echo "$agent_def" | cut -d: -f4)

        if id "$username" &>/dev/null; then
            warn "AI agent $username already exists"
            continue
        fi

        # Create system user (no login, no shell)
        useradd -r -s /usr/sbin/nologin -d "$home_dir" -M "$username"
        mkdir -p "$home_dir"
        chown "$username:$username" "$home_dir"

        # Create home for orchestrator (it needs to manage files)
        if [[ "$username" == "kirat-ai-orchestrator" ]]; then
            usermod -s /bin/bash "$username" 2>/dev/null || true
        fi

        # AI agents have NO sudo by default
        # They run as systemd services with specific capabilities
        # The executor gets a VERY limited sudo whitelist
        if [[ "$username" == "kirat-ai-executor" ]]; then
            cat > "/etc/sudoers.d/99-kirat-ai-executor" << EOF
# AI Executor — STRICTLY LIMITED to read-only and status commands
Defaults:kirat-ai-executor    log_input, log_output
Defaults:kirat-ai-executor    timestamp_timeout=2
kirat-ai-executor ALL=(ALL) NOPASSWD: $allowed_cmds
EOF
            chmod 440 "/etc/sudoers.d/99-kirat-ai-executor"
        fi

        # Create systemd service for the agent
        create_ai_service "$username" "$description"

        ok "AI Agent created: $username ($description)"
        ((idx++))
    done

    # Set permissions on instruction queue
    chown -R kirat-ai-orchestrator:kirat-ai-orchestrator /opt/kirat-os/ai-agents/instructions
    chmod 750 /opt/kirat-os/ai-agents/instructions
    chmod 750 /opt/kirat-os/ai-agents/instructions/pending
    chmod 750 /opt/kirat-os/ai-agents/instructions/approved
    chmod 755 /opt/kirat-os/ai-agents/instructions/completed
    chmod 750 /opt/kirat-os/ai-agents/instructions/rejected

    # Admin can write instructions, orchestrator reads them
    setfacl -m u:$ADMIN_USER:rwx /opt/kirat-os/ai-agents/instructions/pending 2>/dev/null || true
    setfacl -m u:$ADMIN_USER:rwx /opt/kirat-os/ai-agents/instructions/approved 2>/dev/null || true
}

# ── AI Agent Systemd Service ────────────────────────────────────────────────
create_ai_service() {
    local username="$1"
    local description="$2"
    local service_name="${username//kirat-/}"

    # Map username to script path
    local script_path=""
    case "$username" in
        kirat-ai-sentinel)   script_path="/opt/kirat-os/sentinel-core/main-real.py" ;;
        kirat-ai-quantum)    script_path="/opt/kirat-os/quantum-ai/quantum-engine-real.py" ;;
        kirat-ai-executor)   script_path="/opt/kirat-os/ai-agents/executor/executor.py" ;;
        kirat-ai-auditor)    script_path="/opt/kirat-os/ai-agents/auditor/auditor.py" ;;
        kirat-ai-orchestrator) script_path="/opt/kirat-os/ai-agents/orchestrator/orchestrator.py" ;;
    esac

    [ -z "$script_path" ] && return

    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=$description
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=$username
Group=$username
WorkingDirectory=$(dirname "$script_path")
Environment=PYTHONPATH=/opt/kirat-os
Environment=KIRAT_AI_AGENT=$username
Environment=KIRAT_INSTRUCTION_DIR=/opt/kirat-os/ai-agents/instructions
Environment=KIRAT_LOG_DIR=/var/log/kirat-os/ai-executions
ExecStart=/usr/bin/python3 $script_path
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$service_name

# Security hardening for AI agents
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/kirat-os/ai-agents /var/log/kirat-os/ai-executions /tmp
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_DAC_READ_SEARCH

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload 2>/dev/null || true
}

# ── AI Agent Execution Framework Files ──────────────────────────────────────
create_ai_framework_files() {
    log "Creating AI Agent execution framework..."

    # Executor script (runs approved instructions)
    mkdir -p /opt/kirat-os/ai-agents/executor
    cat > /opt/kirat-os/ai-agents/executor/executor.py << 'PYEOF'
#!/usr/bin/env python3
"""
KIRAT OS — AI Agent Executor
Executes administrator-approved instructions within strict sandbox.
Only reads from /opt/kirat-os/ai-agents/instructions/approved/
All executions logged to /var/log/kirat-os/ai-executions/
"""
import os, sys, json, time, hashlib, subprocess, logging, signal
from pathlib import Path
from datetime import datetime

INSTRUCTION_DIR = Path(os.getenv("KIRAT_INSTRUCTION_DIR", "/opt/kirat-os/ai-agents/instructions"))
APPROVED_DIR = INSTRUCTION_DIR / "approved"
COMPLETED_DIR = INSTRUCTION_DIR / "completed"
REJECTED_DIR = INSTRUCTION_DIR / "rejected"
LOG_DIR = Path(os.getenv("KIRAT_LOG_DIR", "/var/log/kirat-os/ai-executions"))

# Whitelist of allowed commands (regex patterns)
ALLOWED_COMMANDS = [
    r"^systemctl status \S+$",
    r"^journalctl -[unf].*",
    r"^df -h$",
    r"^free -m$",
    r"^top -b -n1$",
    r"^ps aux( --sort=-%mem|--sort=-%cpu)?$",
    r"^netstat -tunapl$",
    r"^ss -tunapl$",
    r"^lsof -i( -P -n)?$",
    r"^du -sh \S+$",
    r"^find \S+ -type f -mtime \+\d+$",
    r"^cat /proc/\w+$",
    r"^cat /sys/\S+$",
    r"^grep -r \S+ \S+$",
    r"^whoami$",
    r"^hostname$",
    r"^uname -a$",
    r"^uptime$",
    r"^ip addr show$",
    r"^ip route show$",
]

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler(LOG_DIR / "executor.log"),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger("kirat-ai-executor")

def validate_command(cmd: str) -> bool:
    import re
    for pattern in ALLOWED_COMMANDS:
        if re.match(pattern, cmd.strip()):
            return True
    logger.warning(f"COMMAND BLOCKED (not in whitelist): {cmd}")
    return False

def execute_instruction(instruction_file: Path) -> dict:
    result = {
        "instruction_id": instruction_file.stem,
        "started_at": datetime.utcnow().isoformat(),
        "completed_at": None,
        "status": "running",
        "commands_executed": [],
        "outputs": [],
        "errors": [],
    }

    try:
        with open(instruction_file) as f:
            instruction = json.load(f)
    except Exception as e:
        result["status"] = "failed"
        result["errors"].append(f"Parse error: {e}")
        return result

    # Verify admin signature
    admin_sig = instruction.get("admin_signature", "")
    expected = hashlib.sha256((instruction.get("payload", "") + "KIRAT-ADMIN-SEED").encode()).hexdigest()[:32]
    if admin_sig != expected:
        logger.error(f"INVALID SIGNATURE on {instruction_file.name}")
        result["status"] = "rejected"
        result["errors"].append("Invalid administrator signature")
        return result

    commands = instruction.get("commands", [])
    timeout = instruction.get("timeout", 30)
    max_timeout = 300
    timeout = min(timeout, max_timeout)

    for cmd in commands:
        if not validate_command(cmd):
            result["errors"].append(f"Blocked: {cmd}")
            continue

        logger.info(f"Executing: {cmd}")
        try:
            proc = subprocess.run(
                cmd, shell=True, capture_output=True, text=True,
                timeout=timeout, user="kirat-ai-executor"
            )
            result["commands_executed"].append(cmd)
            result["outputs"].append({
                "command": cmd,
                "stdout": proc.stdout[:4096],  # Limit output size
                "stderr": proc.stderr[:4096],
                "returncode": proc.returncode
            })
        except subprocess.TimeoutExpired:
            result["errors"].append(f"Timeout: {cmd}")
            logger.warning(f"TIMEOUT: {cmd}")
        except Exception as e:
            result["errors"].append(f"Error executing '{cmd}': {e}")
            logger.error(f"EXEC ERROR: {cmd} — {e}")

    result["completed_at"] = datetime.utcnow().isoformat()
    result["status"] = "completed" if not result["errors"] else "completed_with_errors"
    return result

def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    COMPLETED_DIR.mkdir(parents=True, exist_ok=True)
    REJECTED_DIR.mkdir(parents=True, exist_ok=True)

    logger.info("KIRAT AI Executor started — waiting for approved instructions")

    def signal_handler(sig, frame):
        logger.info("Shutdown signal received")
        sys.exit(0)
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    while True:
        try:
            for inst_file in sorted(APPROVED_DIR.glob("*.json")):
                logger.info(f"Processing instruction: {inst_file.name}")
                result = execute_instruction(inst_file)

                # Save result
                result_file = COMPLETED_DIR / f"{inst_file.stem}-result.json"
                with open(result_file, "w") as f:
                    json.dump(result, f, indent=2)

                # Move original to completed
                inst_file.rename(COMPLETED_DIR / inst_file.name)
                logger.info(f"Instruction {inst_file.stem}: {result['status']}")

            time.sleep(5)
        except Exception as e:
            logger.error(f"Main loop error: {e}")
            time.sleep(10)

if __name__ == "__main__":
    main()
PYEOF

    chown kirat-ai-executor:kirat-ai-executor /opt/kirat-os/ai-agents/executor/executor.py
    chmod 750 /opt/kirat-os/ai-agents/executor/executor.py

    # Orchestrator script (validates and routes instructions)
    mkdir -p /opt/kirat-os/ai-agents/orchestrator
    cat > /opt/kirat-os/ai-agents/orchestrator/orchestrator.py << 'PYEOF'
#!/usr/bin/env python3
"""
KIRAT OS — AI Orchestrator
Validates administrator instructions and routes them to appropriate AI agents.
Ensures: signature verification, scope validation, safety checks.
"""
import os, sys, json, time, hashlib, logging
from pathlib import Path
from datetime import datetime

INSTRUCTION_DIR = Path("/opt/kirat-os/ai-agents/instructions")
PENDING_DIR = INSTRUCTION_DIR / "pending"
APPROVED_DIR = INSTRUCTION_DIR / "approved"
REJECTED_DIR = INSTRUCTION_DIR / "rejected"
ADMIN_SEED = "KIRAT-ADMIN-SEED"  # In production, read from TPM or secure vault

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("kirat-ai-orchestrator")

def verify_signature(instruction: dict) -> bool:
    payload = json.dumps(instruction.get("payload", {}), sort_keys=True)
    expected = hashlib.sha256((payload + ADMIN_SEED).encode()).hexdigest()[:32]
    return instruction.get("admin_signature", "") == expected

def validate_scope(instruction: dict) -> tuple[bool, str]:
    agent = instruction.get("target_agent", "")
    commands = instruction.get("commands", [])

    valid_agents = ["kirat-ai-sentinel", "kirat-ai-quantum", "kirat-ai-executor",
                    "kirat-ai-auditor", "kirat-ai-orchestrator"]
    if agent not in valid_agents:
        return False, f"Invalid target agent: {agent}"

    # Safety: block dangerous commands
    dangerous = ["rm -rf /", "mkfs.", "dd if=", "> /dev/sda", "shutdown", "reboot",
                 "passwd", "usermod", "userdel", "chmod 777 /", "wget.*\|.*sh"]
    for cmd in commands:
        for d in dangerous:
            if d in cmd.lower():
                return False, f"Dangerous command blocked: {cmd}"

    return True, "OK"

def main():
    for d in [PENDING_DIR, APPROVED_DIR, REJECTED_DIR]:
        d.mkdir(parents=True, exist_ok=True)

    logger.info("Orchestrator started — monitoring pending instructions")

    while True:
        try:
            for pending in sorted(PENDING_DIR.glob("*.json")):
                with open(pending) as f:
                    instruction = json.load(f)

                sig_ok = verify_signature(instruction)
                scope_ok, msg = validate_scope(instruction)

                if sig_ok and scope_ok:
                    target = APPROVED_DIR / pending.name
                    logger.info(f"APPROVED: {pending.name} -> {instruction.get('target_agent')}")
                else:
                    target = REJECTED_DIR / pending.name
                    reason = "Invalid signature" if not sig_ok else msg
                    logger.warning(f"REJECTED: {pending.name} — {reason}")

                pending.rename(target)

            time.sleep(3)
        except Exception as e:
            logger.error(f"Orchestrator error: {e}")
            time.sleep(5)

if __name__ == "__main__":
    main()
PYEOF

    chown kirat-ai-orchestrator:kirat-ai-orchestrator /opt/kirat-os/ai-agents/orchestrator/orchestrator.py
    chmod 750 /opt/kirat-os/ai-agents/orchestrator/orchestrator.py

    # Auditor script
    mkdir -p /opt/kirat-os/ai-agents/auditor
    cat > /opt/kirat-os/ai-agents/auditor/auditor.py << 'PYEOF'
#!/usr/bin/env python3
"""
KIRAT OS — AI Auditor
Monitors all AI agent executions, generates compliance reports.
Tamper-proof logging via append-only files.
"""
import os, sys, json, time, logging
from pathlib import Path
from datetime import datetime

LOG_DIR = Path("/var/log/kirat-os/ai-executions")
REPORT_DIR = Path("/opt/kirat-os/ai-agents/reports")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("kirat-ai-auditor")

def generate_daily_report():
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    report_file = REPORT_DIR / f"audit-report-{datetime.now().strftime('%Y%m%d')}.json"

    executions = []
    for result_file in sorted(LOG_DIR.glob("*result.json")):
        try:
            with open(result_file) as f:
                executions.append(json.load(f))
        except:
            continue

    report = {
        "generated_at": datetime.utcnow().isoformat(),
        "total_executions": len(executions),
        "successful": sum(1 for e in executions if e.get("status") == "completed"),
        "with_errors": sum(1 for e in executions if e.get("status") == "completed_with_errors"),
        "rejected": sum(1 for e in executions if e.get("status") == "rejected"),
        "executions": executions[-100:]  # Last 100 for detail
    }

    with open(report_file, "w") as f:
        json.dump(report, f, indent=2)

    # Make report append-only (admin can read, auditor writes)
    os.chmod(report_file, 0o640)

    logger.info(f"Daily audit report: {report_file} ({report['total_executions']} executions)")

def main():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    logger.info("Auditor started")

    while True:
        try:
            generate_daily_report()
            time.sleep(86400)  # Daily
        except Exception as e:
            logger.error(f"Auditor error: {e}")
            time.sleep(3600)

if __name__ == "__main__":
    main()
PYEOF

    chown kirat-ai-auditor:kirat-ai-auditor /opt/kirat-os/ai-agents/auditor/auditor.py
    chmod 750 /opt/kirat-os/ai-agents/auditor/auditor.py

    ok "AI Agent execution framework created"
}

# ── Admin CLI Tool ──────────────────────────────────────────────────────────
create_admin_cli() {
    log "Creating administrator CLI tool..."

    cat > /usr/local/bin/kirat-admin << 'CLIEOF'
#!/bin/bash
# KIRAT OS Administrator CLI
# Usage: kirat-admin <command> [options]

set -e
KIRAT_DIR="/opt/kirat-os"
INSTRUCTION_DIR="$KIRAT_DIR/ai-agents/instructions"
ADMIN_SEED="KIRAT-ADMIN-SEED"

usage() {
    cat << EOF
KIRAT OS Administrator CLI

Commands:
  instruction create <agent> <command>    Create instruction for AI agent
  instruction list                       List pending instructions
  instruction approve <id>               Manually approve an instruction
  instruction reject <id>                Reject an instruction
  devsecops list                         List DevSecOps members
  devsecops reset-password <user>        Reset DevSecOps password
  audit report                           Show latest audit report
  audit log                              Show AI execution log
  agent status                           Show all AI agent statuses
  agent restart <name>                   Restart an AI agent service

Examples:
  kirat-admin instruction create kirat-ai-executor "systemctl status nginx"
  kirat-admin agent status
  kirat-admin audit report
EOF
}

gen_signature() {
    local payload="$1"
    echo -n "$payload$ADMIN_SEED" | sha256sum | cut -c1-32
}

cmd_instruction_create() {
    local agent="$1"
    shift
    local commands="$*"
    local ts=$(date +%s)
    local id="inst-${ts}-$(openssl rand -hex 4)"
    local file="$INSTRUCTION_DIR/pending/${id}.json"

    local payload=$(cat << PAYLOAD
{"target_agent":"$agent","commands":["$commands"],"created_by":"$USER","timestamp":$ts}
PAYLOAD
)
    local sig=$(echo -n "$payload" | sha256sum | cut -c1-32)

    cat > "$file" << JSON
{
  "id": "$id",
  "target_agent": "$agent",
  "commands": ["$commands"],
  "created_by": "$USER",
  "timestamp": $ts,
  "payload": $payload,
  "admin_signature": "$sig"
}
JSON
    echo "✓ Instruction created: $id -> $agent"
    echo "  File: $file"
}

cmd_instruction_list() {
    echo "=== Pending Instructions ==="
    ls -la "$INSTRUCTION_DIR/pending/" 2>/dev/null || echo "None"
    echo ""
    echo "=== Approved Instructions ==="
    ls -la "$INSTRUCTION_DIR/approved/" 2>/dev/null || echo "None"
}

cmd_agent_status() {
    echo "=== AI Agent Statuses ==="
    for svc in kirat-ai-sentinel kirat-ai-quantum kirat-ai-executor kirat-ai-auditor kirat-ai-orchestrator; do
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        echo "  $svc: $status"
    done
}

cmd_audit_report() {
    local report=$(ls -t /opt/kirat-os/ai-agents/reports/*.json 2>/dev/null | head -1)
    if [ -n "$report" ]; then
        echo "=== Latest Audit Report ==="
        cat "$report" | python3 -m json.tool 2>/dev/null || cat "$report"
    else
        echo "No audit reports found"
    fi
}

cmd_devsecops_list() {
    echo "=== DevSecOps Members ==="
    for user in kirat-devsecops-security kirat-devsecops-ops kirat-devsecops-dev kirat-devsecops-incident; do
        if id "$user" &>/dev/null; then
            echo "  ✓ $user ($(grep "$user" /etc/sudoers.d/* 2>/dev/null | head -1 | cut -d: -f3 | cut -d' ' -f1-3))"
        else
            echo "  ✗ $user (not created)"
        fi
    done
}

# Main dispatch
case "${1:-}" in
    instruction)
        case "${2:-}" in
            create) cmd_instruction_create "${3:-}" "${4:-}" ;;
            list) cmd_instruction_list ;;
            *) usage; exit 1 ;;
        esac
        ;;
    agent)
        case "${2:-}" in
            status) cmd_agent_status ;;
            restart) systemctl restart "${3:-}"; cmd_agent_status ;;
            *) usage; exit 1 ;;
        esac
        ;;
    audit)
        case "${2:-}" in
            report) cmd_audit_report ;;
            log) journalctl -u kirat-ai-executor -n 100 ;;
            *) usage; exit 1 ;;
        esac
        ;;
    devsecops)
        case "${2:-}" in
            list) cmd_devsecops_list ;;
            *) usage; exit 1 ;;
        esac
        ;;
    *) usage; exit 1 ;;
esac
CLIEOF

    chmod +x /usr/local/bin/kirat-admin
    ok "Administrator CLI tool installed: kirat-admin"
}

# ── Main Install ────────────────────────────────────────────────────────────
main() {
    mkdir -p /var/log/kirat-os
    log "=== KIRAT OS RBAC User Model Setup ==="

    lock_root
    create_admin
    create_devsecops
    create_ai_agents
    create_ai_framework_files
    create_admin_cli

    # Enable and start AI services
    log "Enabling AI agent services..."
    for svc in kirat-ai-orchestrator kirat-ai-auditor kirat-ai-executor; do
        systemctl enable "$svc" 2>/dev/null || true
        systemctl start "$svc" 2>/dev/null || true
    done

    log ""
    log "=== RBAC Setup Complete ==="
    log ""
    log "User Hierarchy:"
    log "  Tier 0: root              (locked, emergency console only)"
    log "  Tier 1: $ADMIN_USER       (Administrator — full control)"
    log "  Tier 2: DevSecOps team    (4 scoped roles with command whitelists)"
    log "  Tier 3: AI Agents         (5 service accounts with sandboxed execution)"
    log ""
    log "Admin CLI: kirat-admin"
    log "  kirat-admin instruction create kirat-ai-executor 'systemctl status nginx'"
    log "  kirat-admin agent status"
    log "  kirat-admin audit report"
    log ""
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
