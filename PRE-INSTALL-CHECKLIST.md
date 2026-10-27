# KIRAT OS — Pre-Installation Checklist
## Complete Step-by-Step Guide Before Installing on Bare Metal

**Use this checklist to ensure everything is ready BEFORE you wipe your disk.**

**Target machine:** New laptop / dedicated server  
**Architecture:** x86_64 (Intel/AMD 64-bit)  
**Minimum requirements:** 4-core CPU, 8GB RAM, 50GB disk  
**Recommended:** 8+ cores, 16GB+ RAM, 100GB+ NVMe SSD

---

## ☐ SECTION 1: Hardware Verification (Do This First)

### 1.1 Run Hardware Compatibility Check
Boot the target machine from the KIRAT OS Live USB (try without installing), open a terminal, and run:

```bash
sudo python3 /opt/kirat-os/scripts/hw-check.py
```

**Expected result:** Score 60+ with no FAIL errors.

**If score < 40:** Do NOT install. Hardware is incompatible.

### 1.2 Verify CPU Architecture
```bash
uname -m
```
**Must return:** `x86_64`  
**If not:** KIRAT OS cannot run on this device.

### 1.3 Check RAM
```bash
free -h
```
**Minimum:** 8GB total  
**Recommended:** 16GB+ for AI features

### 1.4 Check Disk Space
```bash
lsblk -o NAME,SIZE,TYPE,MODEL
```
**Target disk must be:** 50GB minimum, 100GB+ recommended  
**Preferred:** NVMe SSD for best I/O performance

### 1.5 Check Network
```bash
ping -c 3 deb.debian.org
```
**Must have:** Internet access for package downloads and Let's Encrypt  
**Static IP preferred** (set in router/DHCP before install)

---

## ☐ SECTION 2: Data Backup (CRITICAL)

### 2.1 Backup All Personal Data
The KIRAT OS installer **WIPES THE ENTIRE DISK**. There is no dual-boot.

**Before proceeding, back up:**
- [ ] Documents, photos, videos, music
- [ ] Browser bookmarks and passwords
- [ ] SSH keys (`~/.ssh/`)
- [ ] Any cryptocurrency wallets or private keys
- [ ] Business-critical files
- [ ] Any software licenses or product keys

**Backup destinations:**
- External USB drive (encrypted with VeraCrypt or BitLocker)
- Cloud storage (Google Drive, Dropbox, OneDrive)
- Another PC on the network

### 2.2 Export Windows Product Key (if applicable)
If this was a Windows machine, save the product key:
```powershell
# Run in Windows PowerShell Admin before wiping:
wmic path softwarelicensingservice get OA3xOriginalProductKey
```
Save this key somewhere safe.

### 2.3 Note Down MAC Addresses
You may need these for router/DHCP static assignments:
```bash
ip link show
```
Save the MAC addresses of ethernet (`eth0`, `enp*`) and WiFi (`wlan*`, `wlp*`) interfaces.

---

## ☐ SECTION 3: Network Preparation

### 3.1 Decide on Hostname
Choose a hostname for your server:
```
 empire-01       (primary business server)
 kirat-main      (main server)
 vault-01        (secure data vault)
```
**Use only:** lowercase letters, numbers, hyphens. No underscores or spaces.

### 3.2 Prepare Domain Name (Required for Let's Encrypt)
You MUST have a real domain for HTTPS certificates.

**Options:**
- Buy a domain: Namecheap, GoDaddy, Cloudflare (e.g., `mybusiness.com`)
- Use a free subdomain: DuckDNS, No-IP (e.g., `mybusiness.duckdns.org`)

**Before install, configure DNS:**
```
Type: A Record
Name: @  (or your subdomain)
Value: Your server's public IP address
TTL: 300 (5 minutes)
```

**Test DNS resolution:**
```bash
nslookup mybusiness.com
# Should return your server's public IP
```

### 3.3 Configure Router (Port Forwarding)
If behind NAT (home router), forward these ports to your server's internal IP:

| Port | Protocol | Service | Required? |
|------|----------|---------|-----------|
| 22 | TCP | SSH (move to non-standard port after install) | Yes |
| 80 | TCP | HTTP (for Let's Encrypt validation) | Yes |
| 443 | TCP | HTTPS (dashboard + API) | Yes |
| 8080 | TCP | Dashboard (internal) | No |
| 3000 | TCP | Sentinel API (internal) | No |

**After install, change SSH to non-standard port (e.g., 2222) for security.**

### 3.4 Set Static IP (Router/DHCP)
In your router admin panel:
1. Find DHCP/static lease settings
2. Assign your server's MAC address to a fixed IP
3. Note this IP — you'll use it for SSH access

---

## ☐ SECTION 4: BIOS/UEFI Configuration

### 4.1 Enter BIOS/UEFI Setup
Restart the target machine and press the BIOS key during boot:
- Dell: F2
- HP: F10 or Esc
- Lenovo: F1 or F2
- ASUS: F2 or Del
- Acer: F2 or Del
- MSI: Del
- Custom: Usually F2, F10, F12, or Del

### 4.2 Configure Boot Order
- [ ] Move USB drive to **first** in boot priority
- [ ] Disable "Fast Boot" if present (can interfere with USB detection)

### 4.3 Configure Disk Controller
- [ ] Set SATA mode to **AHCI** (NOT RAID/Intel RST)
  - If currently RAID: **WARNING** — changing to AHCI may affect existing Windows install. Only do this if wiping disk anyway.

### 4.4 Configure for UEFI (Recommended)
- [ ] Ensure boot mode is **UEFI** (not Legacy/CSM)
- [ ] If dual UEFI+Legacy exists, select **UEFI Only**

### 4.5 Secure Boot (Optional for Install)
- [ ] **Disable Secure Boot** during installation (easiest)
  - OR: Keep enabled and enroll MOK after install (advanced)

### 4.6 Virtualization
- [ ] Enable **Intel VT-x** or **AMD-V** (if you plan to run VMs on KIRAT OS)
- [ ] Enable **Intel VT-d** or **AMD-Vi** (IOMMU) for PCI passthrough

### 4.7 Save and Exit
Press F10 (usually) to save BIOS settings and reboot.

---

## ☐ SECTION 5: Physical Security Preparation

### 5.1 Prepare FIDO2 Hardware Key (Optional but Recommended)
**Buy:** YubiKey 5 NFC or YubiKey 5 Nano (~$50)  
**Alternative:** Any FIDO2/U2F certified key

**After KIRAT OS install, you'll:**
1. Generate `sk-ssh-ed25519` key on the YubiKey
2. Configure SSH to require the key for login
3. Remove password-only SSH access

### 5.2 Prepare Air-Gapped Machine (Optional, Advanced)
For maximum security (nation-state resistance):
- Prepare a second old laptop/PC that will NEVER connect to internet
- This machine will hold your MOK private key for kernel module signing
- Transfer signed modules via USB between air-gapped and KIRAT OS server

### 5.3 Physical Location
- [ ] Server will be in a well-ventilated area
- [ ] Power supply is stable (consider UPS)
- [ ] Ethernet cable is long enough to reach router/switch
- [ ] Consider Kensington lock if in shared space

---

## ☐ SECTION 6: Installation Media Preparation

### 6.1 Build or Download ISO
**Option A: Build yourself (recommended)**
```bash
# In WSL2 or Linux build machine:
cd kirat-os-server/scripts
sudo bash build-iso.sh --output ~/kirat-os-2.0.0.iso --include-installer
```

**Option B: Use pre-built ISO** (if you have one)

### 6.2 Write ISO to USB
**Windows (Rufus):**
1. Download Rufus from https://rufus.ie
2. Insert USB drive (16GB+ required)
3. Open Rufus → Select USB drive → Select `kirat-os-2.0.0.iso`
4. Partition scheme: **GPT** (for UEFI) or **MBR** (for BIOS)
5. Target system: **UEFI (non-CSM)** or **BIOS/UEFI**
6. Click **START** → Confirm erase
7. Wait 5-15 minutes

**Linux:**
```bash
sudo dd if=kirat-os-2.0.0.iso of=/dev/sdX bs=4M status=progress
sync
```
**Replace `/dev/sdX` with your USB device (NOT a partition like /dev/sdX1)**

### 6.3 Verify USB Write
**Windows:**
```powershell
# Compare checksums
Get-FileHash kirat-os-2.0.0.iso -Algorithm SHA256
# Then check USB contents match
```

**Linux:**
```bash
sha256sum kirat-os-2.0.0.iso
# Compare with .sha256 file
```

### 6.4 Label the USB
Write "KIRAT OS 2.0.0 - Bootable" on the USB stick with a marker.

---

## ☐ SECTION 7: Account & Password Planning

### 7.1 Prepare Strong Passwords
You will create these during installation. Prepare them NOW on paper (not on the machine being wiped):

| Account | Purpose | Password Requirements |
|---------|---------|----------------------|
| `root` | Emergency only | 20+ chars, mixed case, numbers, symbols |
| `kirat-admin` | Full admin | 16+ chars, mixed case, numbers, symbols |
| Disk encryption | LUKS passphrase | 8+ words OR 32+ random chars |
| Business email | Let's Encrypt | Your existing email |

**Password generator:** `openssl rand -base64 32` (run on another machine)

### 7.2 Save Passwords Securely
- Write on paper, store in physical safe
- OR use a password manager (Bitwarden, KeePassXC) on your phone
- **NEVER** save passwords in plain text files on the server itself

---

## ☐ SECTION 8: Post-Install Preparation

### 8.1 Prepare Monitoring Checklist
After install, you'll run these commands. Have them ready:

```bash
# Verify all services
systemctl status ollama sentinel kirat-dashboard nginx postgresql redis-server

# Verify AI agents
systemctl status jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai

# Verify security
sudo bash /opt/kirat-os/scripts/verify-security.sh

# Run activation checklist
sudo bash /opt/kirat-os/activation-checklist.sh --dedicated
```

### 8.2 Prepare First-Boot Tasks
Immediately after install and first boot:

1. [ ] Log in as `kirat-admin` via SSH
2. [ ] Change password (forced on first login)
3. [ ] Pull Ollama AI model: `ollama pull gemma4:latest`
4. [ ] Test dashboard: `curl http://localhost:8080/api/health`
5. [ ] Enroll MOK for Secure Boot (if UEFI): `sudo mokutil --import /opt/kirat-os/security/mok/MOK.der`
6. [ ] Configure TPM auto-unlock (optional): `sudo clevis luks bind -d /dev/nvme0n1p2 tpm2`
7. [ ] Set up FIDO2 SSH key (if you have YubiKey)
8. [ ] Update DNS A record if IP changed
9. [ ] Test Let's Encrypt: `sudo certbot renew --dry-run`
10. [ ] Run first security scan: `sudo lynis audit system`

---

## ☐ SECTION 9: Emergency Preparedness

### 9.1 Prepare Recovery USB
Create a SECOND USB with:
- KIRAT OS Live ISO (same as install USB)
- OR: Debian Live ISO (fallback)
- OR: SystemRescue ISO (https://www.system-rescue.org)

### 9.2 Document Your Setup
Write down on paper:
- [ ] Server IP address (static)
- [ ] Hostname
- [ ] Domain name
- [ ] SSH port (default 22, change to 2222 after hardening)
- [ ] Dashboard URL: `https://yourdomain.com` or `http://server-ip:8080`
- [ ] LUKS passphrase hint (not the actual passphrase!)

### 9.3 Prepare Remote Access (for headless server)
If installing on a server without monitor:
- [ ] Ensure IPMI/iDRAC/iLO is configured (enterprise servers)
- [ ] OR: Connect via serial console (USB-to-serial adapter)
- [ ] OR: Temporarily connect a monitor and keyboard for install

---

## ☐ SECTION 10: Final Go/No-Go Decision

**Before inserting the USB and powering on, answer these:**

- [ ] All personal data backed up to external drive?
- [ ] Windows product key saved (if applicable)?
- [ ] Target disk has 50GB+ free?
- [ ] Internet connection available?
- [ ] Domain name purchased and DNS A record configured?
- [ ] Router ports 22, 80, 443 forwarded?
- [ ] BIOS set to boot from USB first?
- [ ] SATA mode set to AHCI?
- [ ] Passwords prepared and written down securely?
- [ ] Recovery USB prepared?
- [ ] Hardware check passed (score 60+)?

### 🟢 ALL CHECKED? PROCEED TO INSTALL.
### 🔴 ANY UNCHECKED? FIX BEFORE PROCEEDING.

---

## Quick Reference: Installation Commands

```bash
# Boot from USB → Select "Install KIRAT OS"

# In installer, you'll be asked for:
#   Disk: /dev/nvme0n1 (or your disk)
#   Hostname: empire-01
#   Domain: mybusiness.com
#   Business email: admin@mybusiness.com
#   Encryption passphrase: [your strong passphrase]
#   root password: [emergency password]
#   kirat-admin password: [main admin password]

# After install completes, remove USB and reboot.
# First boot will:
#   - Expand filesystem
#   - Start all services
#   - Pull AI models
#   - Attempt Let's Encrypt

# Access your server:
ssh kirat-admin@your-server-ip

# Access dashboard:
https://yourdomain.com  (after DNS propagates)
# OR
http://your-server-ip:8080  (temporary, HTTP only)
```

---

**Date prepared:** _______________  
**Prepared by:** _______________  
**Target machine:** _______________  
**Hostname:** _______________  
**Domain:** _______________  

**KIRAT OS v2.0.0-ENTERPRISE — Ready to build your empire.** 🛡️
