#!/bin/bash
# KIRAT OS — Unattended install launcher with auto-retry (WSL2 host)
# Handles flaky network by retrying the entire install up to 3 times.
# Must be run with sudo-capable user inside Debian WSL2.
set -u

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DISK_IMG="${KIRAT_DISK_IMG:-/mnt/d/kimi/workspace/kirat-os-vm-test/kirat-os-test-disk.img}"
TARGET_DISK="${KIRAT_TEST_DISK:-/dev/vda}"
MIRROR="${DEB_MIRROR:-http://ftp.hk.debian.org/debian}"
MAX_ATTEMPTS=3

log() { echo "[LAUNCHER] $*"; }

reset_disk() {
    log "Resetting virtual disk to factory blank..."
    umount -R /mnt/kirat-os-root 2>/dev/null || true
    sudo cryptsetup close kirat-data 2>/dev/null || true
    sudo cryptsetup close kirat-root  2>/dev/null || true
    sleep 1
    sudo qemu-nbd --disconnect /dev/nbd0 2>/dev/null || true
    sleep 2
    rm -f "$DISK_IMG"
    qemu-img create -f raw "$DISK_IMG" 60G >/dev/null
    sudo qemu-nbd -f raw --connect=/dev/nbd0 "$DISK_IMG" || return 1
    sleep 2
    # vda aliases: vda passes validation; vdaN resolve to nbd0pN when
    # the kernel creates partition nodes during partitioning.
    ln -sf /dev/nbd0   /dev/vda
    ln -sf /dev/nbd0p1 /dev/vda1
    ln -sf /dev/nbd0p2 /dev/vda2
    ln -sf /dev/nbd0p3 /dev/vda3
    return 0
}

cd "$PROJECT_DIR" || exit 1
log "Project: $PROJECT_DIR"
log "Mirror:  $MIRROR"

for attempt in $(seq 1 $MAX_ATTEMPTS); do
    log "═══ INSTALL ATTEMPT $attempt of $MAX_ATTEMPTS ═══"
    reset_disk || { log "disk reset failed"; continue; }

    if sudo KIRAT_TEST_DISK="$TARGET_DISK" DEB_MIRROR="$MIRROR" \
        python3 scripts/vm-test/auto-install-test.py; then
        log "INSTALL SUCCEEDED on attempt $attempt 🛡️"
        exit 0
    fi
    log "Attempt $attempt failed — retrying in 10s..."
    sleep 10
done

log "ALL $MAX_ATTEMPTS ATTEMPTS FAILED — see /tmp/kirat-auto-install.log"
exit 1
