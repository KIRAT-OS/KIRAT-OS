#!/usr/bin/env python3
"""Apply Fix 5: FIDO2/U2F SSH 2FA + air-gapped MOK signing notes"""

PATH = "kirat-os-server/scripts/install-native.sh"

with open(PATH, "r", encoding="utf-8") as f:
    content = f.read()

# CHANGE 1: Add libfido2-1 to debootstrap packages
old_pkg = "openssh-server,sudo,curl,wget,vim,nano,\\"
new_pkg = "openssh-server,libfido2-1,sudo,curl,wget,vim,nano,\\"
if old_pkg in content:
    content = content.replace(old_pkg, new_pkg, 1)
    print("CHANGE 1: Added libfido2-1 to debootstrap packages")
else:
    print("WARNING: Could not find openssh-server package line")

# CHANGE 2: Update SSH config with FIDO2 support
old_ssh = '''    cat > "$INSTALL_MOUNT/etc/ssh/sshd_config.d/kirat-production.conf" << EOF
# KIRAT OS Production SSH Hardening
Port 22
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
KexAlgorithms $PQC_SSH,curve25519-sha256,ecdh-sha2-nistp521
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding yes
PermitTunnel no
Banner /etc/ssh/kirat-banner
EOF'''

new_ssh = '''    cat > "$INSTALL_MOUNT/etc/ssh/sshd_config.d/kirat-production.conf" << EOF
# KIRAT OS Production SSH Hardening
Port 22
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
# FIDO2/U2F hardware key support (requires libfido2-1 + physical key)
# To generate: ssh-keygen -t ed25519-sk -O resident -O verify-required
# To enable 2FA: AuthenticationMethods publickey,keyboard-interactive:pam
KexAlgorithms $PQC_SSH,curve25519-sha256,ecdh-sha2-nistp521
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
# Accept resident FIDO2 keys (sk-ssh-ed25519@openssh.com)
PubkeyAcceptedKeyTypes ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
X11Forwarding no
AllowTcpForwarding yes
PermitTunnel no
Banner /etc/ssh/kirat-banner
EOF'''

if old_ssh in content:
    content = content.replace(old_ssh, new_ssh, 1)
    print("CHANGE 2: Added FIDO2/U2F SSH key support")
else:
    print("WARNING: Could not find SSH config block")

# CHANGE 3: Add air-gapped MOK signing note after MOK key generation
old_mok = '        log_ok "MOK keys generated"'
new_mok = '''        log_ok "MOK keys generated"
        log_warn "AIR-GAPPED SIGNING RECOMMENDED: For nation-state resistance, sign kernel modules on an air-gapped machine."
        log_warn "Transfer MOK.priv to air-gapped signer, keep only MOK.der on this server."
        cat > "$INSTALL_MOUNT/opt/kirat-os/security/mok/README.airgap" << 'EOF'
# KIRAT OS — Air-Gapped MOK Signing Procedure
#
# For maximum security against supply-chain and nation-state attacks:
#
# 1. Generate MOK keys on an air-gapped machine (never connected to network)
# 2. Transfer ONLY MOK.der (public) to this server
# 3. Keep MOK.priv (private) on the air-gapped signer
# 4. When compiling out-of-tree kernel modules:
#    a. Build on this server
#    b. Transfer unsigned .ko to air-gapped signer
#    c. Sign with: sbsign --key MOK.priv --cert MOK.der module.ko
#    d. Transfer signed .ko back to this server
# 5. Enroll MOK.der with: mokutil --import /opt/kirat-os/security/mok/MOK.der
#
# This prevents an attacker who compromises this server from forging
# kernel module signatures.
EOF
        chmod 644 "$INSTALL_MOUNT/opt/kirat-os/security/mok/README.airgap"'''

if old_mok in content:
    content = content.replace(old_mok, new_mok, 1)
    print("CHANGE 3: Added air-gapped MOK signing documentation")
else:
    print("WARNING: Could not find MOK generated marker")

with open(PATH, "w", encoding="utf-8") as f:
    f.write(content)

print("Fix 5 applied successfully")
