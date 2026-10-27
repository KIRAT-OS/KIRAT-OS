#!/usr/bin/env python3
"""
KIRAT OS — QEMU keyboard injector (types text into the VM via monitor socket)

Usage: python3 qemu-type.py "text to type" [delay_between_keys]
Special: the string \n sends Enter (ret).
"""
import socket
import sys
import time

SOCK = "/tmp/kirat-mon.sock"

KEYMAP = {}
for c in "abcdefghijklmnopqrstuvwxyz":
    KEYMAP[c] = c
    KEYMAP[c.upper()] = "shift-" + c
for d in "0123456789":
    KEYMAP[d] = d
KEYMAP.update({
    "-": "minus", "_": "shift-minus", ".": "dot", "/": "slash",
    "@": "shift-2", "!": "shift-1", ":": "shift-semicolon",
    "=": "equal", " ": "spc", "+": "shift-equal", ",": "comma",
    "?": "shift-slash", "'": "apostrophe", '"': "shift-apostrophe",
    ">": "shift-dot", "<": "shift-comma", ";": "semicolon",
    "~": "shift-grave_accent", "|": "shift-backslash", "*": "shift-8",
    "&": "shift-7", "(": "shift-9", ")": "shift-0", "$": "shift-4",
})


def send(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    try:
        # drain banner/prompt
        s.settimeout(0.3)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
        s.sendall((cmd + "\n").encode())
        time.sleep(0.15)
        try:
            s.recv(4096)
        except socket.timeout:
            pass
    finally:
        s.close()


def type_text(text, delay=0.3):
    text = text.replace("\\n", "\n")  # literal backslash-n from shell = Enter
    text = text.replace("{ctrl-c}", "\x01")
    for ch in text:
        if ch == "\x01":
            send("sendkey ctrl-c")
            time.sleep(0.4)
            continue
        if ch == "\n":
            send("sendkey ret")
            time.sleep(0.4)
            continue
        key = KEYMAP.get(ch)
        if key is None:
            raise ValueError("unmappable char: %r" % ch)
        send("sendkey " + key)
        time.sleep(delay)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    type_text(sys.argv[1])
    print("typed:", sys.argv[1])
