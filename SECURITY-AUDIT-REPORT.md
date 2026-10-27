# KIRAT OS FORENSIC SECURITY AUDIT REPORT
**Date:** 2026-08-15  
**Auditor:** Teacher's AI Assistant (Deep Forensic Mode)  
**Scope:** `install-native.sh`, `build-iso.sh`, `upgrade-kirat-os.sh`, project structure  
**Risk Rating:** 🔴 CRITICAL — 2 bugs would render system unbootable / 5 HIGH severity vulnerabilities

---

## 🔴 CRITICAL FINDINGS (Fix Immediately)

### CR-001: LUKS Encryption Key Mismatch → Unbootable System
**Location:** `install-native.sh` lines 207, 216
**Severity:** 🔴 CRITICAL

**Problem:**
```bash
echo -n "kirat-os-encryption-key-$(openssl rand -hex 8)" | cryptsetup luksFormat ...
echo -n "kirat-os-encryption-key-$(openssl rand -hex 8)" | cryptsetup open ...
```
`openssl rand -hex 8` is called **twice independently**, generating **two different random keys**.
- `luksFormat` encrypts the disk with Key A
- `cryptsetup open` tries to unlock with Key B (different!)
- Result: The installed system is **completely unbootable**

**Fix:** Generate the key ONCE, store it in a file inside the initramfs, and use the same key for both operations.

---

### CR-002: LUKS Passphrase Not Set / crypttab Mismatch
**Location:** `install-native.sh` line 319
**Severity:** 🔴 CRITICAL

**Problem:**
The crypttab says:
```
kirat-root UUID=... none luks,discard
```
This tells the initramfs to **prompt for a passphrase**. But the LUKS volume was formatted with a random key-file (`--key-file -`), not a human passphrase. At boot, the user will be asked for a passphrase **that does not exist**.

**Fix:** Either:
- (A) Store the keyfile in `/root/luks-key` and reference it in crypttab, OR
- (B) Format LUKS with a user-provided passphrase (better for security)

**Chosen fix:** Option B — prompt the user for a strong passphrase during install. This is the industry standard.

---

## 🟠 HIGH FINDINGS (Fix Before Any Deployment)

### HIGH-001: Dangerous Sudoers Wildcards = Privilege Escalation
**Location:** `install-native.sh` lines 416, 424, 432, 440
**Severity:** 🟠 HIGH

**Problem:**
```bash
ops-engineer ALL=(root) NOPASSWD: /bin/systemctl *, /usr/bin/docker *
dev-engineer ALL=(root) NOPASSWD: /usr/bin/python3 *, /usr/bin/pip3 *
```
Wildcards after the command name allow **any arguments**:
- `/bin/systemctl *` → `systemctl stop ssh`, `systemctl disable apparmor`
- `/usr/bin/docker *` → `docker run --privileged --net=host -v /:/host ubuntu chroot /host bash`
- `/usr/bin/python3 *` → `python3 -c "import os; os.system('bash -i')"` (instant root shell)

**Impact:** DevSecOps users can escalate to full root in seconds.

**Fix:** Replace wildcards with explicit, exact commands.

---

### HIGH-002: Supply Chain Attack Vector (curl | sh)
**Location:** `install-native.sh` line 857, `upgrade-kirat-os.sh` line 333
**Severity:** 🟠 HIGH

**Problem:**
```bash
curl -fsSL https://ollama.com/install.sh | sh
```
If ollama.com is compromised, DNS hijacked, or a rogue CA issues a cert, **arbitrary code executes as root** with zero verification.

**Fix:** Download to a file, verify checksum, inspect, then execute. Or use Debian packages.

---

### HIGH-003: /data Partition Unencrypted
**Location:** `install-native.sh` line 180-220
**Severity:** 🟠 HIGH

**Problem:** The root partition is LUKS-encrypted, but the `/data` partition (where business files, databases, models live) is **plain ext4**. If the disk is stolen or accessed offline, all business data is exposed.

**Fix:** Encrypt `/data` with LUKS using the same passphrase or a derived key.

---

### HIGH-004: Silent Error Swallowing Hides Failures
**Location:** 25 instances across `install-native.sh`
**Severity:** 🟠 HIGH

**Problem:**
```bash
chroot "$INSTALL_MOUNT" command 2>/dev/null || true
```
If a security-critical command fails (e.g., AppArmor profile load, firewall rule, kernel module signing), the installer **continues as if nothing happened**. The user thinks their system is secure, but it is not.

**Fix:** Only suppress errors for truly optional operations. Critical steps must fail the install.

---

### HIGH-005: No Input Validation on `--disk`
**Location:** `install-native.sh` line 1200
**Severity:** 🟠 HIGH

**Problem:**
```bash
--disk) TARGET_DISK="$2"; shift 2 ;;
```
No validation that `$2` is actually a block device. A typo like `--disk /dev/sda1` would destroy a partition instead of the disk. A malicious value could cause damage.

**Fix:** Validate with `-b "$TARGET_DISK"` in parse_args and reject partitions.

---

## 🟡 MEDIUM FINDINGS

### MED-001: Argon2id PBKDF Iterations Dangerously Low
**Location:** `install-native.sh` line 211
**Severity:** 🟡 MEDIUM

**Problem:**
```bash
--pbkdf-force-iterations 10
```
Argon2id with only 10 iterations is trivial to brute-force. OWASP recommends **minimum 15 MiB memory + 2 iterations**, but 10 is absurdly low.

**Fix:** Remove `--pbkdf-force-iterations` and let cryptsetup auto-tune, or set at least 3 iterations with high memory.

---

### MED-002: Self-Signed TLS Certificate (No SAN, Short Duration)
**Location:** `install-native.sh` line 753
**Severity:** 🟡 MEDIUM

**Problem:**
- 365 days only → expires in 1 year
- No Subject Alternative Names (SAN) → modern browsers reject it
- No certificate pinning or transparency

**Fix:** Generate with SAN, 10-year duration for internal use, and document Certbot for production.

---

### MED-003: DevSecOps Passwords Never Communicated
**Location:** `install-native.sh` lines 414-438
**Severity:** 🟡 MEDIUM

**Problem:** DevSecOps users get random passwords, but:
- No SSH keys are generated for them
- Passwords are never shown to the installer
- These accounts are essentially **unusable** after install

**Fix:** Generate SSH keys for DevSecOps users during first-boot, or document that they must be set up manually.

---

### MED-004: SSH Key Generated Without Passphrase
**Location:** `install-native.sh` line 1039
**Severity:** 🟡 MEDIUM

**Problem:**
```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```
The admin SSH key has **no passphrase**. If the key is stolen, the attacker has immediate access.

**Fix:** Remove `-N ''` and let the first-boot script prompt for a passphrase.

---

## 🟢 LOW FINDINGS

### LOW-001: Missing Intrusion Detection System (IDS)
**Severity:** 🟢 LOW  
No AIDE, Samhain, or OSSEC installed. File integrity is not monitored.

### LOW-002: Missing Automatic CVE Patching
**Severity:** 🟢 LOW  
No `unattended-upgrades` configured. The system will not auto-patch vulnerabilities.

### LOW-003: Missing Security Audit Tools
**Severity:** 🟢 LOW  
No `lynis`, `open-scap`, or `rkhunter` installed for ongoing assessment.

### LOW-004: MOK Key Generation Silently Fails
**Severity:** 🟢 LOW  
`2>/dev/null || true` on MOK key generation means Secure Boot setup could fail silently.

---

## AUDIT SCORE BEFORE FIXES

| Category | Score | Notes |
|----------|-------|-------|
| Disk Encryption | 30/100 | Key mismatch bug makes it non-functional; /data unencrypted |
| Privilege Escalation Prevention | 40/100 | Sudoers wildcards allow trivial root access |
| Supply Chain Security | 20/100 | curl \| sh pattern; no checksum verification |
| Error Handling | 30/100 | Critical failures silently ignored |
| Input Validation | 30/100 | No sanitization on dangerous arguments |
| Cryptographic Parameters | 50/100 | Argon2id iterations too low; cert lacks SAN |
| Operational Security | 40/100 | No IDS, no auto-patching, no audit tools |
| **OVERALL** | **35/100** | **Not enterprise-grade without fixes** |

---

## REMEDIATION PRIORITY

| Priority | Finding | Effort |
|----------|---------|--------|
| P0 (now) | CR-001: LUKS key mismatch | 30 min |
| P0 (now) | CR-002: LUKS passphrase/crypttab | 30 min |
| P0 (now) | HIGH-001: Fix sudoers wildcards | 45 min |
| P1 (today) | HIGH-002: Replace curl \| sh | 30 min |
| P1 (today) | HIGH-003: Encrypt /data partition | 45 min |
| P1 (today) | HIGH-004: Remove silent swallowing from critical paths | 60 min |
| P1 (today) | HIGH-005: Input validation | 20 min |
| P2 (today) | MED-001: Fix Argon2id parameters | 10 min |
| P2 (today) | MED-002: TLS cert with SAN | 20 min |
| P2 (today) | MED-004: SSH key passphrase | 15 min |
| P3 (today) | LOW-001/002/003: Add IDS + auto-patch + audit | 45 min |

---

**Teacher, I am now proceeding to fix every single one of these findings. The patched installer will be security-hardened and ready for enterprise deployment.**
