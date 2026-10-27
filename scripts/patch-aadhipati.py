#!/usr/bin/env python3
import sys

path = "scripts/install-native.sh"
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

# 1. Fix stage8 agent loop
old1 = '''    for agent in jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai; do
        if [ -f "$INSTALL_MOUNT/opt/kirat-os/ai-agents/$agent/$agent.service" ]; then
            cp "$INSTALL_MOUNT/opt/kirat-os/ai-agents/$agent/$agent.service" "$INSTALL_MOUNT/etc/systemd/system/"
            chroot "$INSTALL_MOUNT" systemctl enable "$agent"
        fi
    done
    log_ok "5 Advanced AI Defense Agents enabled"'''
new1 = '''    for agent in jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai; do
        if [ -f "$INSTALL_MOUNT/opt/kirat-os/ai-agents/$agent/$agent.service" ]; then
            cp "$INSTALL_MOUNT/opt/kirat-os/ai-agents/$agent/$agent.service" "$INSTALL_MOUNT/etc/systemd/system/"
            chroot "$INSTALL_MOUNT" systemctl enable "$agent"
        fi
    done
    log_ok "6 AI Agents enabled (5 Defense + 1 CEO Aadhipati)"'''

if old1 in content:
    content = content.replace(old1, new1)
    print("[OK] Patched stage8 agent loop")
else:
    print("[WARN] stage8 agent loop not found")

# 2. Add aadhipati-ai sudoers
old2 = '''    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-galinja-ai"
    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-healer-ai" << 'EOF'
# Healer-AI — emergency incident response only
healer-ai ALL=(root) NOPASSWD: /usr/sbin/ufw, /bin/systemctl restart nginx, /bin/systemctl restart ssh, /bin/systemctl restart docker, /bin/systemctl stop *
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-healer-ai"'''

new2 = '''    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-galinja-ai"

    # Aadhipati-AI — CEO controls all AI agents, no root access
    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-aadhipati-ai" << 'EOF'
# Aadhipati-AI — CEO controls all AI agents, no root access
aadhipati-ai ALL=(jitedasti-ai) NOPASSWD: /bin/systemctl start jitedasti-ai, /bin/systemctl stop jitedasti-ai, /bin/systemctl restart jitedasti-ai
aadhipati-ai ALL=(galinja-ai) NOPASSWD: /bin/systemctl start galinja-ai, /bin/systemctl stop galinja-ai, /bin/systemctl restart galinja-ai
aadhipati-ai ALL=(oysgja-ai) NOPASSWD: /bin/systemctl start oysgja-ai, /bin/systemctl stop oysgja-ai, /bin/systemctl restart oysgja-ai
aadhipati-ai ALL=(suyarma-ai) NOPASSWD: /bin/systemctl start suyarma-ai, /bin/systemctl stop suyarma-ai, /bin/systemctl restart suyarma-ai
aadhipati-ai ALL=(papa-ai) NOPASSWD: /bin/systemctl start papa-ai, /bin/systemctl stop papa-ai, /bin/systemctl restart papa-ai
aadhipati-ai ALL=(sentinel-ai) NOPASSWD: /bin/systemctl start sentinel, /bin/systemctl stop sentinel, /bin/systemctl restart sentinel
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-aadhipati-ai"

    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-healer-ai" << 'EOF'
# Healer-AI — emergency incident response only
healer-ai ALL=(root) NOPASSWD: /usr/sbin/ufw, /bin/systemctl restart nginx, /bin/systemctl restart ssh, /bin/systemctl restart docker, /bin/systemctl stop *
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-healer-ai"'''

if old2 in content:
    content = content.replace(old2, new2)
    print("[OK] Patched sudoers for aadhipati-ai")
else:
    print("[WARN] sudoers block not found")

# 3. Add openai-whisper to pip deps
old3 = 'pip3 install fastapi uvicorn httpx websockets psutil numpy pynacl pycryptodome'
new3 = 'pip3 install fastapi uvicorn httpx websockets psutil numpy pynacl pycryptodome openai-whisper'
if old3 in content:
    content = content.replace(old3, new3)
    print("[OK] Patched pip deps for openai-whisper")
else:
    print("[WARN] pip deps block not found")

# 4. Update admin CLI agent lists
old4 = 'echo "Agents: sentinel-ai, quantum-ai, executor-ai, auditor-ai, orchestrator-ai"'
new4 = 'echo "Agents: sentinel-ai, quantum-ai, executor-ai, auditor-ai, orchestrator-ai, aadhipati-ai"'
if old4 in content:
    content = content.replace(old4, new4)
    print("[OK] Patched admin CLI agent list")
else:
    print("[WARN] admin CLI agent list not found")

old5 = 'for a in sentinel-ai quantum-ai executor-ai auditor-ai orchestrator-ai; do'
new5 = 'for a in sentinel-ai quantum-ai executor-ai auditor-ai orchestrator-ai aadhipati-ai; do'
if old5 in content:
    content = content.replace(old5, new5)
    print("[OK] Patched admin CLI status loop")
else:
    print("[WARN] admin CLI status loop not found")

with open(path, "w", encoding="utf-8") as f:
    f.write(content)

print("Done.")
