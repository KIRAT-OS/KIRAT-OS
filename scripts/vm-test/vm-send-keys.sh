#!/bin/bash
# KIRAT OS — Type text into the VM console from a file (immune to shell mangling)
# Usage: bash vm-send-keys.sh   (reads /mnt/d/kimi/workspace/kirat-os-vm-test/next-keys.txt)
KEYS_FILE="/mnt/d/kimi/workspace/kirat-os-vm-test/next-keys.txt"
TYPER="/mnt/d/kimi/workspace/kirat-os-server/scripts/vm-test/qemu-type.py"

if [ ! -f "$KEYS_FILE" ]; then
    echo "No keys file: $KEYS_FILE"
    exit 1
fi
python3 "$TYPER" "$(cat "$KEYS_FILE")"
rm -f "$KEYS_FILE"
echo "keys sent and file cleared"
