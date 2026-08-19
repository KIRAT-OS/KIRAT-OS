# Secure Boot & Measured Boot Chain
# KIRAT OS Server Security Layer 5
# "Trust starts at power-on. Verify every byte."

## Overview

From the moment power is applied, every piece of code that runs must be
cryptographically verified. Any tampering is detected and the system refuses
to boot.

## Boot Chain of Trust

```
Power On
    ↓
┌─────────────────┐
│   CPU Microcode │  ← Signed by Intel/AMD, verified by CPU
│   (immutable)   │
└─────────────────┘
    ↓
┌─────────────────┐
│   Boot ROM      │  ← Hardware root of trust (CRTMs)
│   (immutable)   │     Core Root of Trust for Measurement
└─────────────────┘
    ↓
┌─────────────────┐
│   TPM 2.0       │  ← Hardware security module
│   (hardware)    │     Stores keys, measures boot, seals data
└─────────────────┘
    ↓
┌─────────────────┐
│   UEFI Firmware │  ← Signed by OEM, verified by Boot ROM
│   (read-only)   │     Measures itself into TPM PCR[0]
└─────────────────┘
    ↓
┌─────────────────┐
│   UEFI Drivers  │  ← Signed by vendor, verified by UEFI
│   (signed)      │     Each measured into TPM PCR[2]
└─────────────────┘
    ↓
┌─────────────────┐
│   Shim/Grub     │  ← Signed by KIRAT OS, verified by UEFI
│   (signed)      │     Measures kernel into TPM PCR[4]
└─────────────────┘
    ↓
┌─────────────────┐
│   Linux Kernel  │  ← Signed by KIRAT OS, verified by Shim
│   (signed)      │     Measures initramfs into TPM PCR[9]
└─────────────────┘
    ↓
┌─────────────────┐
│   Initramfs     │  ← Signed by KIRAT OS, verified by Kernel
│   (signed)      │     Measures rootfs into TPM PCR[10]
└─────────────────┘
    ↓
┌─────────────────┐
│   Root Filesystem│  ← dm-verity hash tree, verified by initramfs
│   (verified)    │     Any corruption detected immediately
└─────────────────┘
    ↓
┌─────────────────┐
│   Sentinel AI   │  ← Runtime attestation, continuous verification
│   (attested)    │     Reports to remote attestation server
└─────────────────┘
```

## TPM 2.0 Usage

### PCR (Platform Configuration Register) Allocation

| PCR | What It Measures | Purpose |
|-----|-----------------|---------|
| 0 | UEFI firmware | Detect firmware tampering |
| 1 | UEFI configuration | Detect config changes |
| 2 | UEFI drivers | Detect malicious drivers |
| 3 | UEFI driver config | Detect driver config changes |
| 4 | Bootloader (GRUB/Shim) | Detect bootloader tampering |
| 5 | Bootloader config | Detect boot option changes |
| 6 | Resume from S4/S5 | Detect hibernation tampering |
| 7 | Secure Boot policy | Detect policy changes |
| 8-9 | Kernel, initramfs | Detect OS tampering |
| 10 | IMA (Integrity Measurement) | Runtime file integrity |
| 11 | BitLocker/LUKS | Disk encryption seal |
| 12-15 | Reserved for applications | Sentinel AI uses PCR[12] |

### Key Hierarchy

```
TPM Endorsement Key (EK) ──▶ Hardware-bound, never leaves TPM
    │
    └──▶ Storage Root Key (SRK) ──▶ Protects other keys
            │
            ├──▶ AI Sealing Key ──▶ Seals Sentinel AI config to PCR state
            │
            ├──▶ Disk Encryption Key ──▶ LUKS key sealed to TPM
            │
            ├──▶ SSH Host Key ──▶ SSH key generated in TPM
            │
            └──▶ Attestation Key (AK) ──▶ Signs TPM quotes
```

## Implementation

### 1. UEFI Secure Boot Setup

```bash
# Generate KIRAT OS Platform Key (PK)
openssl req -new -x509 -newkey rsa:2048 \
    -keyout PK.key -out PK.crt \
    -days 3650 -nodes \
    -subj "/CN=KIRAT OS Platform Key/"

# Generate Key Exchange Key (KEK)
openssl req -new -x509 -newkey rsa:2048 \
    -keyout KEK.key -out KEK.crt \
    -days 3650 -nodes \
    -subj "/CN=KIRAT OS Key Exchange Key/"

# Generate Signature Database Key (DB)
openssl req -new -x509 -newkey rsa:2048 \
    -keyout DB.key -out DB.crt \
    -days 3650 -nodes \
    -subj "/CN=KIRAT OS Signature Database/"

# Sign the bootloader
sbsign --key DB.key --cert DB.crt \
    --output grubx64.efi.signed \
    grubx64.efi

# Enroll keys into firmware
efi-updatevar -f PK.auth PK
efi-updatevar -f KEK.auth KEK
efi-updatevar -f DB.auth db
```

### 2. Kernel Signing

```bash
# Sign kernel with DB key
sbsign --key DB.key --cert DB.crt \
    --output vmlinuz-signed \
    vmlinuz

# Verify signature
sbverify --cert DB.crt vmlinuz-signed
```

### 3. Initramfs Signing

```bash
# Create signed initramfs
cpio -o < initramfs-files | gzip > initramfs.gz
openssl dgst -sha256 -sign DB.key \
    -out initramfs.gz.sig \
    initramfs.gz

# In initramfs, verify before use
openssl dgst -sha256 -verify DB.pub \
    -signature initramfs.gz.sig \
    initramfs.gz
```

### 4. dm-verity (Root Filesystem Integrity)

```bash
# Create verity hash tree for root filesystem
veritysetup format \
    /dev/mapper/root-fs \
    /dev/mapper/root-hash \
    --hash=sha256 \
    --data-block-size=4096 \
    --hash-block-size=4096 \
    > rootfs.verity.txt

# Extract root hash
ROOT_HASH=$(grep "Root hash:" rootfs.verity.txt | awk '{print $3}')

# Boot with dm-verity
# Kernel command line:
# root=/dev/mapper/root-verity
# dm-mod.create="root-verity,,,ro,0 $(blockdev --getsz /dev/sda3) verity 1 /dev/sda3 /dev/sda3 4096 4096 $(cat rootfs.verity.txt | grep -E "Data blocks|Hash blocks|Hash algorithm|Salt|Root hash")"
```

### 5. TPM Sealed Disk Encryption

```bash
# Generate LUKS key sealed to TPM PCR state
systemd-cryptenroll \
    --tpm2-device=auto \
    --tpm2-pcrs=0+2+7+12 \
    /dev/nvme0n1p3

# What this means:
# - Disk key is sealed in TPM
# - Only unseals if PCR[0,2,7,12] match expected values
# - If firmware, bootloader, or Sentinel AI changes → key stays locked
# - Attacker can't decrypt disk even with physical access

# Unlock at boot
systemd-cryptsetup attach root /dev/nvme0n1p3 \
    - tpm2-device=auto
```

### 6. IMA (Integrity Measurement Architecture)

```bash
# Enable IMA in kernel
ima_policy="tcb"
ima_appraise="enforce"
ima_hash="sha256"

# IMA measures every file executed
# Measurements stored in TPM PCR[10]
# Audit log at /sys/kernel/security/ima/ascii_runtime_measurements

# Example log entry:
# 10 3a9f... ima-ng sha256:7c8d... /usr/bin/nginx
#  ^ PCR    ^ template   ^ file hash      ^ file path

# Verify file integrity
ima_verify -f /usr/bin/nginx
# Compares current hash with IMA log
```

### 7. Remote Attestation

```python
# sentinel-core/src/security/remote_attestation.py

class RemoteAttestation:
    """Prove to remote verifier that this system is trustworthy."""
    
    def generate_quote(self):
        """Generate TPM quote with PCR measurements."""
        # 1. Read PCR values from TPM
        pcrs = tpm2_pcrread sha256:0,1,2,3,4,5,6,7,8,9,10,12
        
        # 2. Create TPM quote (signed by AK)
        quote = tpm2_quote \
            -c ak.ctx \
            -l sha256:0,1,2,3,4,5,6,7,8,9,10,12 \
            -m quote.msg \
            -s quote.sig \
            -f pcrs.yaml
            
        # 3. Include IMA log
        ima_log = read_file("/sys/kernel/security/ima/ascii_runtime_measurements")
        
        # 4. Include Sentinel AI integrity hash
        sentinel_hash = compute_sentinel_hash()
        
        return {
            "quote": quote,
            "ima_log": ima_log,
            "sentinel_hash": sentinel_hash,
            "timestamp": now(),
            "nonce": generate_nonce()  # Prevent replay
        }
        
    def verify_with_remote(self, attestation_server):
        """Send quote to remote attestation server for verification."""
        quote = self.generate_quote()
        
        response = requests.post(
            f"{attestation_server}/verify",
            json=quote,
            cert=(self.mtls_cert, self.mtls_key)
        )
        
        if response.json()["trusted"]:
            return True
        else:
            # System is untrusted! Possible tampering.
            self.panic("REMOTE ATTESTATION FAILED")
            return False
```

## Measured Boot Verification Script

```bash
#!/bin/bash
# /usr/local/bin/verify-boot-chain.sh

# Verify entire boot chain integrity

echo "=== KIRAT OS Boot Chain Verification ==="

# 1. Verify TPM is present and active
if [ ! -d /sys/class/tpm/tpm0 ]; then
    echo "FAIL: TPM not detected"
    exit 1
fi
echo "[OK] TPM active"

# 2. Read PCR values
for pcr in 0 1 2 3 4 5 6 7 8 9 10 12; do
    value=$(tpm2_pcrread sha256:$pcr | grep -oP 'sha256:\s+\K[0-9a-f]+')
    echo "[PCR $pcr] $value"
done

# 3. Compare with golden values (stored in TPM NVRAM)
echo "Comparing with golden measurements..."
for pcr in 0 4 9 10; do
    current=$(tpm2_pcrread sha256:$pcr | grep -oP 'sha256:\s+\K[0-9a-f]+')
    golden=$(tpm2_nvread -C o 0x01$pcr 2>/dev/null || echo "NOT_SET")
    
    if [ "$golden" = "NOT_SET" ]; then
        echo "[WARN] PCR $pcr: Golden value not set (first boot?)"
        # Store current as golden
        tpm2_nvdefine -C o 0x01$pcr -s 32 -a "ownerread|ownerwrite|extend"
        echo "$current" | xxd -r -p | tpm2_nvwrite -C o 0x01$pcr -i -
    elif [ "$current" = "$golden" ]; then
        echo "[OK] PCR $pcr: Matches golden value"
    else
        echo "[FAIL] PCR $pcr: MISMATCH!"
        echo "  Current: $current"
        echo "  Golden:  $golden"
        echo "  Possible tampering detected!"
        
        # Alert Sentinel AI
        sentinel alert --severity critical \
            --title "Boot Chain Tampering Detected" \
            --message "PCR $pcr mismatch. System may be compromised."
        
        # Optional: halt boot
        # echo "Halting boot for investigation."
        # exit 1
    fi
done

# 4. Verify kernel signature
if sbverify --cert /etc/secureboot/db.crt /boot/vmlinuz; then
    echo "[OK] Kernel signature valid"
else
    echo "[FAIL] Kernel signature invalid!"
    sentinel alert --severity critical --title "Kernel signature invalid"
fi

# 5. Verify dm-verity
if veritysetup verify /dev/mapper/root-fs /dev/mapper/root-hash; then
    echo "[OK] Root filesystem integrity verified"
else
    echo "[FAIL] Root filesystem corrupted!"
    sentinel alert --severity critical --title "Root filesystem corrupted"
fi

# 6. Verify Sentinel AI integrity
sentinel_hash=$(sentinel self hash)
golden_sentinel=$(cat /var/lib/sentinel/.integrity_hash 2>/dev/null || echo "NOT_SET")

if [ "$golden_sentinel" = "NOT_SET" ]; then
    echo "[WARN] Sentinel hash not set (first boot?)"
    echo "$sentinel_hash" > /var/lib/sentinel/.integrity_hash
elif [ "$sentinel_hash" = "$golden_sentinel" ]; then
    echo "[OK] Sentinel AI integrity verified"
else
    echo "[FAIL] Sentinel AI modified!"
    sentinel alert --severity critical --title "Sentinel AI integrity failure"
fi

echo "=== Verification Complete ==="
```

## Recovery from Compromise

```
Scenario: Attacker modifies kernel, PCR[8] changes, disk key won't unseal

Recovery Process:
1. Boot from KIRAT OS Recovery USB (signed, trusted)
2. Enter recovery passphrase (stored in hardware security module)
3. TPM releases disk key (recovery path uses different PCR policy)
4. System boots in recovery mode
5. Sentinel AI analyzes what changed
6. Admin reviews and approves new PCR values
7. Re-seal disk key with new PCR values
8. Normal boot resumes

Without recovery key: Disk is cryptographically unrecoverable.
```

## Implementation Checklist

- [ ] Enable TPM 2.0 in BIOS/UEFI
- [ ] Set UEFI admin password
- [ ] Enable Secure Boot
- [ ] Enroll KIRAT OS keys (PK, KEK, DB)
- [ ] Sign bootloader, kernel, initramfs
- [ ] Enable dm-verity for root filesystem
- [ ] Seal LUKS key to TPM PCRs
- [ ] Enable IMA in enforce mode
- [ ] Configure remote attestation server
- [ ] Set up golden PCR values
- [ ] Test recovery procedure
- [ ] Document key backup and recovery

## Verification Commands

```bash
# Check Secure Boot status
mokutil --sb-state
# Expected: SecureBoot enabled

# Check TPM
tpm2_getcap properties-fixed | grep -A5 "TPM2_PT_MANUFACTURER"

# Read PCR values
tpm2_pcrread sha256:0,1,2,3,4,5,6,7,8,9,10

# Verify kernel signature
sbverify --list /boot/vmlinuz

# Check IMA log
head /sys/kernel/security/ima/ascii_runtime_measurements

# Verify dm-verity
veritysetup status /dev/mapper/root-verity

# Test remote attestation
sentinel attest --server https://attestation.kirat-os.local
```
