#!/usr/bin/env python3
"""
KIRAT OS — Unattended VM Test Installer (pty driver)

Drives scripts/install-native.sh inside the Debian Live VM by answering
every interactive prompt through a pseudo-terminal. Test-only credentials,
clearly marked — CHANGE THEM before any real deployment.

Run inside the VM terminal:
    sudo python3 scripts/vm-test/auto-install-test.py

Or with overrides:
    sudo KIRAT_TEST_LUKS="my-pass-here" python3 scripts/vm-test/auto-install-test.py
"""

import os
import pty
import re
import select
import signal
import sys
import time

# ── Test-only credentials (VM DISPOSABLE ENVIRONMENT ONLY) ──
LUKS_PASS = os.environ.get("KIRAT_TEST_LUKS", "KiratTest-LUKS-2026!")
ROOT_PASS = os.environ.get("KIRAT_TEST_ROOT", "KiratRoot-2026!")
ADMIN_PASS = os.environ.get("KIRAT_TEST_ADMIN", "KiratAdmin-2026!")
TARGET_DISK = os.environ.get("KIRAT_TEST_DISK", "/dev/sda")
INSTALLER = os.environ.get("KIRAT_INSTALLER", "scripts/install-native.sh")

if len(LUKS_PASS) < 12:
    print("[DRIVER] ERROR: test LUKS passphrase must be >= 12 chars")
    sys.exit(2)

# ── Prompt state machine (ordered) ──
# (regex, response, description)
PROMPTS = [
    (r"to confirm destruction:\s*$", TARGET_DISK + "\n", "disk confirm"),
    (r"Enter strong LUKS passphrase.*:\s*$", LUKS_PASS + "\n", "LUKS pass 1"),
    (r"Confirm LUKS passphrase:\s*$", LUKS_PASS + "\n", "LUKS pass 2"),
    (r"New password:\s*$", None, "root password"),          # response set at runtime
    (r"Retype new password:\s*$", None, "root retype"),
    (r"New password:\s*$", None, "admin password"),          # 2nd occurrence
    (r"Retype new password:\s*$", None, "admin retype"),
    (r"empty for no passphrase.*:\s*$", "\n", "ssh-keygen pass (empty)"),
    (r"same passphrase again:\s*$", "\n", "ssh-keygen confirm"),
    (r"\[Y/n\]:\s*$", "n\n", "skip 30GB model download in test"),
]
# Fix responses for the password rounds (root then admin)
PROMPTS[3] = (PROMPTS[3][0], ROOT_PASS + "\n", PROMPTS[3][2])
PROMPTS[4] = (PROMPTS[4][0], ROOT_PASS + "\n", PROMPTS[4][2])
PROMPTS[5] = (PROMPTS[5][0], ADMIN_PASS + "\n", PROMPTS[5][2])
PROMPTS[6] = (PROMPTS[6][0], ADMIN_PASS + "\n", PROMPTS[6][2])

RETRY_RE = re.compile(r"Try again\.")

OVERALL_TIMEOUT = 90 * 60   # 90 minutes
PROMPT_TIMEOUT = 20 * 60    # 20 min between prompts (debootstrap can be slow)

LOGFILE = "/tmp/kirat-auto-install.log"


def main():
    env = dict(os.environ)
    env.update({
        "TARGET_DISK": TARGET_DISK,
        "HOSTNAME": "test-kirat",
        "USERNAME": "kirat-admin",
        "DEBIAN_FRONTEND": "noninteractive",
    })

    print("[DRIVER] Starting unattended KIRAT OS install (test credentials)")
    print("[DRIVER] Disk: {} | Log: {}".format(TARGET_DISK, LOGFILE))

    log = open(LOGFILE, "w", buffering=1)

    pid, fd = pty.fork()
    if pid == 0:  # child
        os.execvpe("bash", ["bash", INSTALLER, "--disk", TARGET_DISK,
                            "--hostname", "test-kirat"], env)
        os._exit(127)

    start = time.time()
    last_activity = time.time()
    buf = ""
    step = 0
    status = None

    def respond(data):
        nonlocal last_activity
        time.sleep(0.4)  # let pty settle; avoids PAM input flush races
        os.write(fd, data.encode())
        last_activity = time.time()

    try:
        while True:
            if time.time() - start > OVERALL_TIMEOUT:
                print("\n[DRIVER] FAIL: overall timeout (90m)")
                status = "timeout"
                break
            if step < len(PROMPTS) and time.time() - last_activity > PROMPT_TIMEOUT:
                print("\n[DRIVER] FAIL: no prompt seen for 20m at step {}/{}".format(step, len(PROMPTS)))
                status = "stall"
                break

            r, _, _ = select.select([fd], [], [], 1)
            if fd in r:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break  # child closed pty
                if not chunk:
                    break
                text = chunk.decode(errors="replace")
                sys.stdout.write(text)
                sys.stdout.flush()
                log.write(text)
                buf += text
                if len(buf) > 20000:
                    buf = buf[-10000:]
                last_activity = time.time()

            # LUKS mismatch loop: step back and re-answer
            if step in (2, 3) and RETRY_RE.search(buf):
                buf = ""
                step = 1
                print("\n[DRIVER] LUKS retry detected, re-sending passphrase")
                respond(LUKS_PASS + "\n")
                continue

            if step < len(PROMPTS):
                regex, answer, desc = PROMPTS[step]
                if re.search(regex, buf):
                    print("\n[DRIVER] >> answering: {}".format(desc))
                    log.write("\n[DRIVER] >> answering: {}\n".format(desc))
                    buf = ""
                    respond(answer)
                    step += 1

        # reap child
        try:
            _, wstatus = os.waitpid(pid, os.WNOHANG)
            if _ == 0:
                os.kill(pid, signal.SIGTERM)
                time.sleep(2)
                os.waitpid(pid, 0)
        except ChildProcessError:
            pass
    finally:
        log.close()
        os.close(fd)

    if status is None:
        status = "completed"
    print("\n[DRIVER] Install session ended: {}".format(status))
    print("[DRIVER] Full log saved at {}".format(LOGFILE))
    sys.exit(0 if status == "completed" else 1)


if __name__ == "__main__":
    main()
