#!/usr/bin/env python3
"""Apply Fix 3: Ed25519 admin signature verification"""

import sys

PATH = "kirat-os-server/scripts/install-native.sh"

with open(PATH, "r", encoding="utf-8") as f:
    content = f.read()

# ── CHANGE 1: Add python3-cryptography to debootstrap ──
old_pkg = "python3,python3-pip,python3-venv,python3-dev,\\"
new_pkg = "python3,python3-pip,python3-venv,python3-dev,python3-cryptography,\\"
if old_pkg in content:
    content = content.replace(old_pkg, new_pkg, 1)
    print("CHANGE 1: Added python3-cryptography to debootstrap")
else:
    print("WARNING: Could not find python3-dev package line")

# ── CHANGE 2: Add Ed25519 key generation after Tier 1 setup ──
old_tier1 = '    log_ok "Tier 1 (kirat-admin): Full sudo + AI delegation"'
new_tier1 = '''    log_ok "Tier 1 (kirat-admin): Full sudo + AI delegation"

    # ── ED25519 KEYPAIR — admin signs all AI instructions ──
    log_info "Generating admin Ed25519 signing keypair..."
    mkdir -p "$INSTALL_MOUNT/opt/kirat-os/security"
    chroot "$INSTALL_MOUNT" python3 -c "
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
import base64

priv = Ed25519PrivateKey.generate()
pub = priv.public_key()

priv_bytes = priv.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption()
)
with open('/opt/kirat-os/security/admin.key', 'w') as f:
    f.write(base64.b64encode(priv_bytes).decode())

pub_bytes = pub.public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw
)
with open('/opt/kirat-os/security/admin.pub', 'wb') as f:
    f.write(pub_bytes)
"
    chmod 600 "$INSTALL_MOUNT/opt/kirat-os/security/admin.key"
    chroot "$INSTALL_MOUNT" chown root:root /opt/kirat-os/security/admin.key
    chmod 644 "$INSTALL_MOUNT/opt/kirat-os/security/admin.pub"
    chroot "$INSTALL_MOUNT" chown root:root /opt/kirat-os/security/admin.pub
    log_ok "Admin Ed25519 keypair generated (/opt/kirat-os/security/admin.pub)"'''
if old_tier1 in content:
    content = content.replace(old_tier1, new_tier1, 1)
    print("CHANGE 2: Added Ed25519 key generation in stage3b")
else:
    print("WARNING: Could not find Tier 1 log_ok line")

# ── CHANGE 3: Replace placeholder in executor-run.sh ──
old_placeholder = '''# Verify admin signature (placeholder — integrate with real signing)
if [ -z "$ADMIN_SIG" ]; then
    echo "ERROR: Missing admin signature" >&2
    exit 1
fi'''
new_verifier = '''# Verify admin Ed25519 signature
ADMIN_PUBKEY="/opt/kirat-os/security/admin.pub"
if [ ! -f "$ADMIN_PUBKEY" ]; then
    echo "ERROR: Admin public key not found" >&2
    exit 1
fi

python3 -c "
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
from cryptography.exceptions import InvalidSignature

with open('$ADMIN_PUBKEY', 'rb') as f:
    pubkey = Ed25519PublicKey.from_public_bytes(f.read())

sig_b64 = '$ADMIN_SIG'
try:
    sig = base64.b64decode(sig_b64)
except Exception:
    print('ERROR: Invalid base64 signature', file=sys.stderr)
    sys.exit(1)

message = '$CMD'.encode('utf-8')
try:
    pubkey.verify(sig, message)
except InvalidSignature:
    print('ERROR: Ed25519 signature verification failed', file=sys.stderr)
    sys.exit(1)
" || exit 1'''
if old_placeholder in content:
    content = content.replace(old_placeholder, new_verifier, 1)
    print("CHANGE 3: Replaced placeholder with Ed25519 verification in executor-run.sh")
else:
    print("WARNING: Could not find placeholder block in executor-run.sh")

# ── CHANGE 4: Update kirat-admin CLI to sign instructions ──
old_cli = '''                FILE="/opt/kirat-os/security/rbac/instructions/$(date +%s)-$(openssl rand -hex 4).json"
                cat > "$FILE" << INSTR
{"agent":"$AGENT","command":"$COMMAND","admin_signature":"$(whoami)-$(date -Iseconds)","created":"$(date -Iseconds)"}
INSTR'''
new_cli = '''                FILE="/opt/kirat-os/security/rbac/instructions/$(date +%s)-$(openssl rand -hex 4).json"
                # Sign command with admin Ed25519 private key
                SIGNATURE=$(python3 -c "
import base64, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

with open('/opt/kirat-os/security/admin.key', 'r') as f:
    key_b64 = f.read().strip()
priv_bytes = base64.b64decode(key_b64)
priv = Ed25519PrivateKey.from_private_bytes(priv_bytes)

message = sys.argv[1].encode('utf-8')
sig = priv.sign(message)
print(base64.b64encode(sig).decode())
" "$COMMAND")
                cat > "$FILE" << INSTR
{"agent":"$AGENT","command":"$COMMAND","admin_signature":"$SIGNATURE","created":"$(date -Iseconds)"}
INSTR'''
if old_cli in content:
    content = content.replace(old_cli, new_cli, 1)
    print("CHANGE 4: Updated kirat-admin CLI to sign with Ed25519")
else:
    print("WARNING: Could not find kirat-admin CLI instruction create block")

with open(PATH, "w", encoding="utf-8") as f:
    f.write(content)

print("Fix 3 applied successfully")
