#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — Ed25519 Admin Signature System for AI Agent Instructions
================================================================================
Every instruction delegated from kirat-admin to an AI agent must be signed
with Ed25519. The executor verifies the signature before running any command.

Key Management:
  - Private key: /opt/kirat-os/security/rbac/.admin-ed25519-secret
    (chmod 600, owned by root)
  - Public key:  /opt/kirat-os/security/rbac/admin-ed25519.pub
    (chmod 644, distributed to agents)

Usage:
  python3 ed25519-sign.py sign <instruction.json>
  python3 ed25519-sign.py verify <instruction.json>
  python3 ed25519-sign.py genkey
================================================================================
"""

import sys
import os
import json
import base64

try:
    import nacl.signing
    import nacl.exceptions
    HAS_NACL = True
except ImportError:
    HAS_NACL = False

KEY_DIR = "/opt/kirat-os/security/rbac"
PRIV_KEY_PATH = os.path.join(KEY_DIR, ".admin-ed25519-secret")
PUB_KEY_PATH = os.path.join(KEY_DIR, "admin-ed25519.pub")


def ensure_keypair():
    """Generate Ed25519 keypair if it doesn't exist."""
    if not HAS_NACL:
        print("ERROR: PyNaCl not installed. Run: pip install pynacl")
        sys.exit(1)

    os.makedirs(KEY_DIR, mode=0o750, exist_ok=True)

    if os.path.exists(PRIV_KEY_PATH) and os.path.exists(PUB_KEY_PATH):
        return

    signing_key = nacl.signing.SigningKey.generate()
    verify_key = signing_key.verify_key

    with open(PRIV_KEY_PATH, "wb") as f:
        f.write(signing_key.encode())
    os.chmod(PRIV_KEY_PATH, 0o600)

    with open(PUB_KEY_PATH, "wb") as f:
        f.write(verify_key.encode())
    os.chmod(PUB_KEY_PATH, 0o644)

    print(f"[OK] Ed25519 keypair generated")
    print(f"     Private: {PRIV_KEY_PATH} (600)")
    print(f"     Public:  {PUB_KEY_PATH} (644)")


def sign_instruction(json_path: str) -> dict:
    """Sign an AI agent instruction JSON file."""
    ensure_keypair()

    with open(PRIV_KEY_PATH, "rb") as f:
        signing_key = nacl.signing.SigningKey(f.read())

    with open(json_path, "r") as f:
        instruction = json.load(f)

    # Canonical JSON for deterministic signing
    payload = json.dumps(instruction, sort_keys=True, separators=(",", ":")).encode("utf-8")
    signature = signing_key.sign(payload)

    instruction["admin_signature"] = base64.b64encode(signature.signature).decode("ascii")
    instruction["signature_alg"] = "Ed25519"
    instruction["signed_at"] = __import__("datetime").datetime.utcnow().isoformat() + "Z"

    with open(json_path, "w") as f:
        json.dump(instruction, f, indent=2)

    print(f"[OK] Signed: {json_path}")
    print(f"     Signature: {instruction['admin_signature'][:32]}...")
    return instruction


def verify_instruction(json_path: str) -> bool:
    """Verify an AI agent instruction signature."""
    if not HAS_NACL:
        print("ERROR: PyNaCl not installed")
        return False

    if not os.path.exists(PUB_KEY_PATH):
        print(f"ERROR: Public key not found: {PUB_KEY_PATH}")
        return False

    with open(PUB_KEY_PATH, "rb") as f:
        verify_key = nacl.signing.VerifyKey(f.read())

    with open(json_path, "r") as f:
        instruction = json.load(f)

    sig_b64 = instruction.pop("admin_signature", None)
    instruction.pop("signature_alg", None)
    instruction.pop("signed_at", None)

    if not sig_b64:
        print("ERROR: No signature found in instruction")
        return False

    signature = base64.b64decode(sig_b64)
    payload = json.dumps(instruction, sort_keys=True, separators=(",", ":")).encode("utf-8")

    try:
        verify_key.verify(payload, signature)
        print(f"[OK] Signature VALID for: {json_path}")
        return True
    except nacl.exceptions.BadSignatureError:
        print(f"[FAIL] Signature INVALID for: {json_path}")
        return False


def main():
    if len(sys.argv) < 2:
        print("Usage:")
        print("  python3 ed25519-sign.py genkey")
        print("  python3 ed25519-sign.py sign <instruction.json>")
        print("  python3 ed25519-sign.py verify <instruction.json>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "genkey":
        ensure_keypair()
    elif cmd == "sign" and len(sys.argv) == 3:
        sign_instruction(sys.argv[2])
    elif cmd == "verify" and len(sys.argv) == 3:
        verify_instruction(sys.argv[2])
    else:
        print("Unknown command")
        sys.exit(1)


if __name__ == "__main__":
    main()
