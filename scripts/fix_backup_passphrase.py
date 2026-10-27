#!/usr/bin/env python3
"""Add backup GPG passphrase generation to stage8"""

PATH = "kirat-os-server/scripts/install-native.sh"

with open(PATH, "r", encoding="utf-8") as f:
    content = f.read()

old_marker = '    log_ok "KIRAT OS components configured"'
new_marker = '''    # Backup encryption passphrase — GPG symmetric AES256
    log_info "Generating backup encryption passphrase..."
    BACKUP_PASS=$(openssl rand -base64 32)
    mkdir -p "$INSTALL_MOUNT/opt/kirat-os/security"
    printf '%s' "$BACKUP_PASS" > "$INSTALL_MOUNT/opt/kirat-os/security/backup-passphrase"
    chmod 600 "$INSTALL_MOUNT/opt/kirat-os/security/backup-passphrase"
    chroot "$INSTALL_MOUNT" chown root:root /opt/kirat-os/security/backup-passphrase
    log_ok "Backup encryption passphrase generated (GPG AES256)"

    log_ok "KIRAT OS components configured"'''

if old_marker in content:
    content = content.replace(old_marker, new_marker, 1)
    print("Added backup passphrase generation in stage8")
else:
    print("WARNING: Could not find stage8 marker")

with open(PATH, "w", encoding="utf-8") as f:
    f.write(content)
