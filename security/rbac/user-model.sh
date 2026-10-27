#!/bin/bash
# KIRAT OS — retired alternate RBAC/bootstrap implementation.
#
# This file formerly installed a second executor using a forgeable static
# SHA-256 "signature" and shell-based command execution. It is intentionally
# non-functional: sourcing or executing it must never create users, services,
# CLIs, or another command execution path.
#
# Canonical instruction flow:
#   security/rbac/ed25519-sign.py  — signed, expiring instruction envelopes
#   security/rbac/executor-run.sh  — exact allowlist and atomic replay defense
# Account/bootstrap provisioning belongs to the reviewed native installer.

set -u

message='DEPRECATED: security/rbac/user-model.sh is disabled. Use the canonical Ed25519 signer/executor; do not install the legacy hash/shell execution framework.'
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' "$message" >&2
    exit 1
fi
printf '%s\n' "$message" >&2
return 1
