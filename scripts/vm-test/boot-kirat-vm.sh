#!/bin/bash
# KIRAT OS — Boot the installed VM with QEMU monitor for remote control
exec qemu-system-x86_64 \
    -enable-kvm -cpu host \
    -m 8192 -smp 4 \
    -hda /mnt/d/kimi/workspace/kirat-os-vm-test/kirat-os-test-disk.img \
    -boot c \
    -vga std -usb -device usb-tablet \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device e1000,netdev=net0 \
    -monitor unix:/tmp/kirat-mon.sock,server,nowait \
    -name kirat-os-production-test
