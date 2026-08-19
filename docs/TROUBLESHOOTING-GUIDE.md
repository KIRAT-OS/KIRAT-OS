# KIRAT OS — Troubleshooting Guide
## WSL2 Build Environment & ISO Creation

**For:** Windows 10 + Intel i7-10870H + 32GB RAM + 40GB free space
**Last updated:** 2026-08-18

---

## Category A: WSL2 Setup Errors

### Error A1: "The requested operation requires elevation"
**Cause:** PowerShell not running as Administrator  
**Fix:**
```powershell
# Close PowerShell. Right-click Start → "Windows PowerShell (Admin)" or "Terminal (Admin)"
# Then re-run the setup script
```

### Error A2: "WSL2 is not installed" or `wsl: command not found`
**Cause:** WSL not enabled in Windows  
**Fix (Manual):**
```powershell
# In Admin PowerShell:
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart

# Restart PC, then:
wsl --set-default-version 2
wsl --install -d Debian
```
**Alternative (Windows Store):** Search "Debian" in Microsoft Store → Install → Launch.

### Error A3: "Virtualization is not enabled"
**Cause:** Intel VT-x/AMD-V disabled in BIOS  
**Fix:**
1. Restart PC, enter BIOS (press F2/Del/F10 during boot)
2. Find "Virtualization Technology" or "Intel VT-x" or "AMD-V"
3. Set to **Enabled**
4. Save and exit

### Error A4: "WSL register distribution failed: 0x800701bc"
**Cause:** WSL kernel not updated  
**Fix:**
```powershell
wsl --update
wsl --shutdown
# Then retry Debian installation
```

### Error A5: Debian install hangs at "Installing, this may take a few minutes..."
**Cause:** Slow network or WSL initial setup  
**Fix:**
```powershell
# Wait up to 30 minutes. If still stuck:
wsl --unregister Debian
wsl --install -d Debian

# Alternative: Install from Microsoft Store instead of command line
```

---

## Category B: Disk Space Errors

### Error B1: "No space left on device" during ISO build
**Cause:** WSL2 virtual disk is full (default is often 256GB but can fill up)  
**Check space:**
```bash
# Inside WSL2 Debian:
df -h /
du -sh ~/kirat-build
```
**Fix 1 - Clean apt cache:**
```bash
sudo apt-get clean
sudo apt-get autoremove -y
```
**Fix 2 - Expand WSL2 disk:**
```powershell
# In Windows PowerShell Admin:
wsl --shutdown
# Then manually expand the VHDX (advanced - see Microsoft docs)
```
**Fix 3 - Free up Windows space first:**
```powershell
# Disk Cleanup
cleanmgr /c

# Empty Recycle Bin
# Uninstall unused programs
# Clear Downloads folder
```
**You need at least 15GB free INSIDE WSL2 and 20GB free on Windows C: drive.**

### Error B2: "The file size exceeds the limit allowed"
**Cause:** WSL2 default disk limit  
**Fix:**
```powershell
# Check current WSL config
cat $env:USERPROFILE\.wslconfig

# Create/edit .wslconfig to increase disk:
# In PowerShell:
@"
[wsl2]
memory=16GB
processors=8
swap=8GB
localhostForwarding=true
"@ | Out-File -Encoding UTF8 $env:USERPROFILE\.wslconfig

wsl --shutdown
# Restart WSL2
```

---

## Category C: Package/Dependency Errors

### Error C1: "debootstrap: command not found"
**Fix:**
```bash
sudo apt-get update
sudo apt-get install -y debootstrap
```

### Error C2: "E: Unable to locate package grub-efi-amd64-bin"
**Cause:** Missing universe/multiverse repositories  
**Fix:**
```bash
sudo apt-get install -y software-properties-common
sudo add-apt-repository universe
sudo add-apt-repository multiverse
sudo apt-get update
sudo apt-get install -y grub-pc-bin grub-efi-amd64-bin xorriso squashfs-tools
```

### Error C3: "debootstrap failed" or "Failed getting release file"
**Cause:** Network issues or bad Debian mirror  
**Fix 1 - Check internet:**
```bash
ping -c 3 deb.debian.org
```
**Fix 2 - Use a different mirror:**
```bash
# Edit build-iso.sh or run with custom mirror:
sudo bash build-iso.sh --mirror http://ftp.us.debian.org/debian
```
**Fix 3 - If behind corporate proxy:**
```bash
export http_proxy=http://your-proxy:port
export https_proxy=http://your-proxy:port
sudo -E bash build-iso.sh
```

### Error C4: "Permission denied" when running build-iso.sh
**Fix:**
```bash
chmod +x build-iso.sh
sudo bash build-iso.sh
# NEVER run as root without sudo - the script checks for it
```

---

## Category D: ISO Build Failures

### Error D1: "grub-mkrescue: command not found"
**Fix:**
```bash
sudo apt-get install -y grub-pc-bin grub-efi-amd64-bin xorriso
```

### Error D2: "xorriso: FAILURE: Cannot find path"
**Cause:** Build directory structure incomplete  
**Fix:**
```bash
# Clean and retry
cd ~/kirat-build/scripts
rm -rf /tmp/kirat-os-iso-build*
sudo bash build-iso.sh --output ~/kirat-os-2.0.0.iso --include-installer
```

### Error D3: ISO builds but is very small (< 100MB)
**Cause:** debootstrap didn't complete, packages missing  
**Fix:**
```bash
# Check build log
tail -100 ~/kirat-build.log

# Usually means network failed during package download
# Retry with stable network connection
```

### Error D4: "mksquashfs: command not found"
**Fix:**
```bash
sudo apt-get install -y squashfs-tools
```

### Error D5: Build completes but ISO won't boot
**Cause:** Missing EFI bootloader files  
**Check:**
```bash
# Mount ISO and check structure
mkdir -p /tmp/iso-check
sudo mount -o loop ~/kirat-os-2.0.0.iso /tmp/iso-check
ls -la /tmp/iso-check/efi/boot/
# Should see: bootx64.efi, grubx64.efi
sudo umount /tmp/iso-check
```
**Fix:** Ensure `shim-signed` and `grub-efi-amd64-signed` packages are installed on build machine.

---

## Category E: Windows-Specific Issues

### Error E1: Windows Defender blocks PowerShell script
**Fix:**
```powershell
# Temporarily allow (safe - this is your own script)
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
# Then run your script
```
**Or:** Right-click `Setup-WSL2-Build.ps1` → Properties → Check "Unblock" → Apply.

### Error E2: Antivirus deletes/quarantines build files
**Cause:** Some AV flags debootstrap or grub files as suspicious  
**Fix:**
1. Add `C:\Users\#RAI\Documents\kimi\workspace\` to antivirus exclusions
2. Or temporarily disable real-time protection during build
3. Or add WSL2 path to exclusions: `\\wsl$\Debian`

### Error E3: Rufus fails to write ISO to USB
**Cause:** USB drive is write-protected, too small, or corrupted  
**Fix:**
```
1. USB must be 16GB or larger
2. Back up USB contents - it will be ERASED
3. Try a different USB port (USB 3.0 preferred)
4. In Rufus: Partition scheme = GPT, Target system = UEFI (non-CSM)
5. If still failing: Format USB as FAT32 first, then try again
```

### Error E4: "The process cannot access the file" when copying ISO
**Cause:** Windows has ISO file locked  
**Fix:**
```powershell
# Close any file explorer windows showing the ISO
# Or restart explorer:
taskkill /f /im explorer.exe
start explorer.exe
```

---

## Category F: Boot & Installation Errors

### Error F1: "Operating System not found" when booting from USB
**Cause:** BIOS not set to boot from USB  
**Fix:**
1. Enter BIOS (F2/Del/F10 during power-on)
2. Find "Boot Order" or "Boot Priority"
3. Move USB drive to #1 position
4. Disable "Secure Boot" temporarily if needed
5. Save and exit

### Error F2: "Secure Boot violation" when booting ISO
**Fix:**
```
1. Enter BIOS
2. Find "Secure Boot" → Set to "Disabled"
3. OR: Set "OS Type" to "Other OS" (not Windows)
4. Save and exit
5. After KIRAT OS install, you can re-enable Secure Boot + enroll MOK
```

### Error F3: "Kernel panic" or "initramfs" error during install
**Cause:** Disk controller mode incompatible  
**Fix:**
```
1. Enter BIOS
2. Find "SATA Mode" or "Storage Configuration"
3. Change from RAID/Intel RST to AHCI
4. WARNING: This may affect Windows if dual-booting
5. Save and exit
```

### Error F4: Installer says "disk is too small"
**Cause:** Target disk < 50GB  
**Fix:** KIRAT OS requires minimum 50GB disk. Use a larger disk or partition.

### Error F5: "LUKS format failed" during disk encryption setup
**Cause:** Disk may be in use or has existing partitions  
**Fix:**
```bash
# In installer, choose "Advanced" disk mode
# Or manually wipe disk first:
sudo wipefs -a /dev/nvme0n1
# WARNING: This erases ALL data on the disk
```

---

## Category G: First-Boot & Activation Errors

### Error G1: "Ollama service failed to start"
**Fix:**
```bash
# Check status
systemctl status ollama

# If not installed:
curl -fsSL https://ollama.com/install.sh | sh

# Start manually:
systemctl start ollama
# Or: ollama serve &

# Pull model:
ollama pull gemma4:latest
```

### Error G2: "certbot: command not found" or Let's Encrypt fails
**Cause:** DOMAIN was set to localhost  
**Fix:**
```bash
# If you used --domain localhost, Let's Encrypt is skipped (expected)
# For real domain, re-run installer with real domain:
# sudo bash install-native.sh --disk /dev/nvme0n1 --hostname empire-01 --domain mybusiness.com
```

### Error G3: "Permission denied" on AI agent systemd services
**Fix:**
```bash
# Fix permissions
sudo chown -R root:root /opt/kirat-os/ai-agents
sudo chmod +x /opt/kirat-os/ai-agents/*/main.py
sudo systemctl daemon-reload
sudo systemctl restart jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai
```

### Error G4: Dashboard shows "OFFLINE" and no metrics
**Fix:**
```bash
# Check if dashboard is running
systemctl status kirat-dashboard

# Restart:
sudo systemctl restart kirat-dashboard

# Check logs:
journalctl -u kirat-dashboard -n 50
```

---

## Quick Diagnostic Commands

```bash
# Check all services
systemctl status ollama sentinel kirat-dashboard nginx postgresql redis-server

# Check disk space
df -h

# Check memory
free -h

# Check AI agent logs
journalctl -u jitedasti-ai -n 20
journalctl -u galinja-ai -n 20

# Check network ports
ss -tulpn

# Check security status
sudo bash /opt/kirat-os/scripts/verify-security.sh

# Check activation score
sudo bash /opt/kirat-os/activation-checklist.sh --dedicated
```

---

## Recovery: If Everything Breaks

```bash
# 1. Boot from KIRAT OS USB again
# 2. Select "Rescue Mode" from GRUB menu
# 3. Mount your installed system:
mkdir /mnt/rescue
mount /dev/mapper/kirat-root /mnt/rescue
mount /dev/nvme0n1p2 /mnt/rescue/boot   # adjust partition

# 4. Chroot into system
chroot /mnt/rescue

# 5. Fix whatever is broken (reinstall grub, fix config, etc.)
grub-install /dev/nvme0n1
update-grub

# 6. Exit and reboot
exit
umount -R /mnt/rescue
reboot
```

---

## Still Stuck?

1. **Check the build log:** `cat ~/kirat-build.log`
2. **Check installer log:** `/var/log/kirat-os-install.log` (on installed system)
3. **Check system logs:** `journalctl -xb`
4. **Verify hardware compatibility:** KIRAT OS requires x86_64 CPU, UEFI or BIOS, 8GB+ RAM

**Emergency contact info:** Save this file and the ISO checksum on a separate USB drive before installing.
