#!/usr/bin/env python3
"""Create and verify canonical Ed25519-signed KIRAT instruction envelopes.

Signed fields: instruction_id, issuer, target, command, issued_at, expiry, nonce.
No legacy hash envelope is accepted. Verification is fail-closed and enforces
issue age, expiry, and a maximum signed lifetime; replay state belongs to the
executor so that it can claim IDs atomically before running commands.
"""

import base64
import binascii
from datetime import datetime, timezone
import json
import os
import re
import sys
import tempfile

try:
    import nacl.exceptions
    import nacl.signing
    HAS_NACL = True
except ImportError:
    HAS_NACL = False

KEY_DIR = os.environ.get("KIRAT_RBAC_DIR", "/opt/kirat-os/security/rbac")
PRIV_KEY_PATH = os.path.join(KEY_DIR, ".admin-ed25519-secret")
PUB_KEY_PATH = os.path.join(KEY_DIR, "admin-ed25519.pub")
SIGNED_FIELDS = ("instruction_id", "issuer", "target", "command",
                 "issued_at", "expiry", "nonce")
ENVELOPE_FIELDS = set(SIGNED_FIELDS) | {"admin_signature", "signature_alg"}
MAX_INSTRUCTION_AGE = int(os.environ.get("KIRAT_MAX_INSTRUCTION_AGE", "300"))
MAX_INSTRUCTION_TTL = int(os.environ.get("KIRAT_MAX_INSTRUCTION_TTL", "3600"))
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
NONCE_RE = re.compile(r"^[A-Fa-f0-9]{32,128}$")
TIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class InstructionError(ValueError):
    pass


def utc_now():
    return datetime.now(timezone.utc)


def parse_time(value, field):
    if not isinstance(value, str) or not TIME_RE.fullmatch(value):
        raise InstructionError(f"{field} must be RFC 3339 UTC with whole seconds")
    try:
        return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc)
    except ValueError as exc:
        raise InstructionError(f"Invalid {field}") from exc


def validate_instruction(instruction):
    if not isinstance(instruction, dict):
        raise InstructionError("Instruction must be a JSON object")
    missing = [field for field in SIGNED_FIELDS if field not in instruction]
    if missing:
        raise InstructionError("Missing signed fields: " + ", ".join(missing))
    for field in SIGNED_FIELDS:
        if not isinstance(instruction[field], str) or not instruction[field]:
            raise InstructionError(f"{field} must be a non-empty string")
    if not ID_RE.fullmatch(instruction["instruction_id"]):
        raise InstructionError("Invalid instruction_id")
    if not NONCE_RE.fullmatch(instruction["nonce"]):
        raise InstructionError("Nonce must be 32-128 hexadecimal characters")
    if len(instruction["issuer"]) > 128 or len(instruction["target"]) > 128:
        raise InstructionError("Issuer/target is too long")
    if len(instruction["command"]) > 4096 or "\n" in instruction["command"] \
            or "\r" in instruction["command"]:
        raise InstructionError("Invalid command length or line break")
    return {field: instruction[field] for field in SIGNED_FIELDS}


def canonical_payload(instruction):
    signed = validate_instruction(instruction)
    return json.dumps(signed, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def validate_times(instruction, now=None):
    issued = parse_time(instruction["issued_at"], "issued_at")
    expiry = parse_time(instruction["expiry"], "expiry")
    now = now or utc_now()
    if expiry <= issued:
        raise InstructionError("expiry must be after issued_at")
    if (expiry - issued).total_seconds() > MAX_INSTRUCTION_TTL:
        raise InstructionError("Instruction lifetime exceeds policy")
    if (now - issued).total_seconds() > MAX_INSTRUCTION_AGE:
        raise InstructionError("Instruction is stale")
    if (issued - now).total_seconds() > 30:
        raise InstructionError("issued_at is too far in the future")
    if now >= expiry:
        raise InstructionError("Instruction has expired")


def atomic_write(path, data, mode):
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def ensure_keypair():
    if not HAS_NACL:
        raise InstructionError("PyNaCl is required")
    os.makedirs(KEY_DIR, mode=0o700, exist_ok=True)
    os.chmod(KEY_DIR, 0o700)
    private_exists = os.path.exists(PRIV_KEY_PATH)
    public_exists = os.path.exists(PUB_KEY_PATH)
    if private_exists and public_exists:
        return
    if private_exists != public_exists:
        raise InstructionError("Incomplete keypair; refusing to replace a key")
    signing_key = nacl.signing.SigningKey.generate()
    atomic_write(PRIV_KEY_PATH, signing_key.encode(), 0o600)
    atomic_write(PUB_KEY_PATH, signing_key.verify_key.encode(), 0o644)
    print(f"[OK] Ed25519 keypair generated in {KEY_DIR}")


def load_json(path):
    with open(path, "r", encoding="utf-8") as stream:
        value = json.load(stream)
    if not isinstance(value, dict):
        raise InstructionError("Instruction must be a JSON object")
    return value


def sign_instruction(json_path):
    ensure_keypair()
    instruction = load_json(json_path)
    if set(instruction) != set(SIGNED_FIELDS):
        raise InstructionError("Unsigned input must contain exactly the seven signed fields")
    payload = canonical_payload(instruction)
    validate_times(instruction)
    with open(PRIV_KEY_PATH, "rb") as stream:
        signing_key = nacl.signing.SigningKey(stream.read())
    signature = signing_key.sign(payload).signature
    envelope = dict(instruction)
    envelope["signature_alg"] = "Ed25519"
    envelope["admin_signature"] = base64.b64encode(signature).decode("ascii")
    atomic_write(json_path,
                 (json.dumps(envelope, indent=2, ensure_ascii=False,
                             allow_nan=False) + "\n").encode("utf-8"), 0o600)
    print(f"[OK] Signed instruction: {instruction['instruction_id']}")
    return envelope


def verify_instruction(json_path, now=None):
    try:
        if not HAS_NACL:
            raise InstructionError("PyNaCl is required")
        if not os.path.isfile(PUB_KEY_PATH):
            raise InstructionError("Ed25519 public key is missing")
        instruction = load_json(json_path)
        if set(instruction) != ENVELOPE_FIELDS:
            raise InstructionError("Envelope has missing or unexpected unsigned fields")
        if instruction["signature_alg"] != "Ed25519":
            raise InstructionError("Unsupported signature algorithm")
        payload = canonical_payload(instruction)
        validate_times(instruction, now=now)
        try:
            signature = base64.b64decode(instruction["admin_signature"],
                                         validate=True)
        except (binascii.Error, ValueError) as exc:
            raise InstructionError("Malformed signature") from exc
        if len(signature) != 64:
            raise InstructionError("Malformed signature length")
        with open(PUB_KEY_PATH, "rb") as stream:
            verify_key = nacl.signing.VerifyKey(stream.read())
        verify_key.verify(payload, signature)
        print(f"[OK] Signature and freshness valid: {instruction['instruction_id']}")
        return True
    except (InstructionError, OSError, ValueError, json.JSONDecodeError,
            nacl.exceptions.BadSignatureError) as exc:
        print(f"[FAIL] Instruction rejected: {exc}", file=sys.stderr)
        return False


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "genkey":
        ensure_keypair()
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "sign":
        sign_instruction(sys.argv[2])
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "verify":
        return 0 if verify_instruction(sys.argv[2]) else 1
    print("Usage: ed25519-sign.py <genkey|sign|verify> [instruction.json]",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (InstructionError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
