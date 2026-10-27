import re

with open('install-native.sh', 'r', encoding='utf-8') as f:
    content = f.read()

# Fix 1: Remove the duplicate galinja-ai heredoc block that overwrites the good one
bad_galinja = '''    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-galinja-ai" << 'EOF'
# Galinja-AI — emergency incident response only

EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-galinja-ai"'''

good_galinja = '''    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-galinja-ai"'''

if bad_galinja in content:
    content = content.replace(bad_galinja, good_galinja, 1)
    print("[FIXED] Removed duplicate galinja-ai block")
else:
    print("[WARN] Could not find duplicate galinja-ai block")

# Fix 2: Fix healer-ai systemctl stop * wildcard
old_healer = "healer-ai ALL=(root) NOPASSWD: /usr/sbin/ufw, /bin/systemctl restart nginx, /bin/systemctl restart ssh, /bin/systemctl restart docker, /bin/systemctl stop *"
new_healer = "healer-ai ALL=(root) NOPASSWD: /usr/sbin/ufw, /bin/systemctl restart nginx, /bin/systemctl restart ssh, /bin/systemctl restart docker, /bin/systemctl stop jitedasti-ai, /bin/systemctl stop galinja-ai, /bin/systemctl stop oysgja-ai, /bin/systemctl stop suyarma-ai, /bin/systemctl stop papa-ai, /bin/systemctl stop aadhipati-ai, /bin/systemctl stop sentinel, /bin/systemctl stop nginx, /bin/systemctl stop ssh, /bin/systemctl stop docker, /bin/systemctl stop ollama"

if old_healer in content:
    content = content.replace(old_healer, new_healer, 1)
    print("[FIXED] Replaced healer-ai systemctl stop * wildcard")
else:
    print("[WARN] Could not find healer-ai wildcard line")

# Fix 3: Remove duplicate # AI Agent groups comment
old_groups = "    # AI Agent groups\n    # AI Agent groups"
new_groups = "    # AI Agent groups"

if old_groups in content:
    content = content.replace(old_groups, new_groups, 1)
    print("[FIXED] Removed duplicate # AI Agent groups comment")
else:
    print("[WARN] Could not find duplicate AI Agent groups comment")

# Verify no more systemctl stop * wildcards remain
if 'systemctl stop *' in content:
    print("[CRIT] systemctl stop * still found in file!")
    for i, line in enumerate(content.split('\n'), 1):
        if 'systemctl stop *' in line:
            print(f"  Line {i}: {line.strip()}")
else:
    print("[OK] No systemctl stop * wildcards remain")

with open('install-native.sh', 'w', encoding='utf-8') as f:
    f.write(content)

print("[DONE] install-native.sh patched successfully")
