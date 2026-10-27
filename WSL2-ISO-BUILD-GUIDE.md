# KIRAT OS — WSL2 ISO Build Guide
## Step-by-Step Walkthrough for Teacher

**Your Machine:** Windows 10, Intel Core i7-10870H (16 threads), 32 GB RAM, 40 GB free space  
**Goal:** Build a bootable KIRAT OS ISO without dual-booting, using WSL2  
**Result:** `kirat-os-2.0.0.iso` ready to burn to USB or test in a VM

---

## 1. What is QEMU and Why Do You Need It?

| Tool | What It Does | Why You Need It |
|------|-------------|-----------------|
| **WSL2** | Runs a real Linux kernel inside Windows | You need a Linux environment to run the ISO build scripts |
| **QEMU** | Hardware emulator — runs a virtual PC inside your PC | Lets you **test** the ISO safely without rebooting or risking your Windows install |
| **KVM** | Linux hardware acceleration for QEMU | Makes QEMU fast (nearly native speed) on your i7 |

> **In plain English:** You are on Windows. You cannot build a Linux OS from Windows directly. WSL2 gives you a Linux "box" inside Windows. QEMU lets you boot that ISO inside a safe sandbox to verify it works before you ever touch real hardware.

---

## 2. Space & Hardware Reality Check

You have **40 GB free**. Here is the honest breakdown:

| Item | Space Needed | You Have |
|------|-------------|----------|
| WSL2 + Debian base | ~5 GB | ✓ 40 GB |
| Build dependencies (`debootstrap`, `squashfs-tools`, etc.) | ~2 GB | ✓ 40 GB |
| ISO build workspace | ~8–12 GB | ✓ 40 GB |
| Final ISO file | ~1.5–2.5 GB | ✓ 40 GB |
| **QEMU test VM disk** (optional) | ~10 GB | ✓ 40 GB |
| **Headroom for Ollama models** (if testing AI) | ~15–30 GB | ⚠️ **Tight** |

**Verdict:** You can build the ISO and do a quick QEMU smoke-test. If you want to test-pull AI models inside QEMU, you will need to free up another 20 GB or use an external USB drive for the VM disk.

---

## 3. Install WSL2 + Debian (One-Time Setup)

### Step 3A — Open PowerShell as **Administrator**
Right-click the Start button → **Windows PowerShell (Admin)** or **Terminal (Admin)**.

### Step 3B — Install WSL2 + Debian
```powershell
wsl --install -d Debian
```
This will:
1. Enable the WSL2 Windows feature
2. Download Debian from the Microsoft Store
3. Set WSL2 as the default version

**Restart your computer when prompted.**

### Step 3C — Launch Debian and Create Your Linux User
After reboot, open **Debian** from the Start menu. Set a UNIX username (suggestion: `teacher`) and a strong password.

### Step 3D — Move WSL to a Drive With Space (If C: is Full)
If your C: drive is tight, move WSL to another drive:
```powershell
# In PowerShell Admin:
wsl --shutdown
wsl --export Debian "D:\wsl-debian.tar"
wsl --unregister Debian
mkdir "D:\WSL"
wsl --import Debian "D:\WSL\Debian" "D:\wsl-debian.tar"
```

---

## 4. Prepare the Build Environment Inside WSL2

### Step 4A — Open Debian WSL
From PowerShell or the Start menu:
```powershell
wsl -d Debian
```

### Step 4B — Update Debian and Install Build Tools
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
    debootstrap squashfs-tools xorriso isolinux syslinux-efi \
    grub-pc-bin grub-efi-amd64-bin mtools dosfstools \
    qemu-utils qemu-system-x86 qemu-kvm \
    git curl wget rsync
```

### Step 4C — Verify KVM Acceleration (Makes QEMU Fast)
```bash
sudo usermod -aG kvm "$USER"
# Log out and back in (close WSL window, reopen), then:
ls -la /dev/kvm
```
If you see `/dev/kvm`, QEMU will run at nearly native speed on your i7.

---

## 5. Copy KIRAT OS Project Into WSL2

Your project lives in Windows at:
```
C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server
```

Inside WSL2, this path is:
```
/mnt/c/Users/#RAI/Documents/kimi/workspace/kirat-os-server
```

### Step 5A — Create a Working Directory in WSL2
```bash
mkdir -p ~/kirat-build
cd ~/kirat-build
```

### Step 5B — Copy the Project (Two Options)

**Option A: Copy into WSL2's native filesystem (faster builds):**
```bash
cp -r /mnt/c/Users/#RAI/Documents/kimi/workspace/kirat-os-server ./kirat-os-server
```

**Option B: Build directly from the Windows mount (slower, but no copy):**
```bash
cd /mnt/c/Users/#RAI/Documents/kimi/workspace/kirat-os-server
```

> **Recommendation:** Use Option A. WSL2's native `ext4` filesystem is **10–20× faster** than the `/mnt/c` bridge.

---

## 6. Build the Bootable ISO

### Step 6A — Enter the Scripts Directory
```bash
cd ~/kirat-build/kirat-os-server/scripts
```

### Step 6B — Run the Builder
```bash
sudo ./build-iso.sh --output /tmp/kirat-os-2.0.0.iso --include-installer
```

**What happens:**
1. `debootstrap` downloads a minimal Debian base (~400 MB)
2. Installs KIRAT OS packages, kernel, and hardening stack
3. Copies the native installer (`install-native.sh`) into the ISO
4. Builds GRUB2 EFI + BIOS bootloader
5. Compresses the live filesystem with `xz`
6. Assembles the final ISO

**Estimated time on your i7-10870H:** 15–30 minutes.

### Step 6C — Verify the ISO
```bash
ls -lh /tmp/kirat-os-2.0.0.iso
file /tmp/kirat-os-2.0.0.iso
```
You should see:
```
kirat-os-2.0.0.iso: DOS/MBR boot sector; ISO 9660 CD-ROM ...
```

---

## 7. Test the ISO Safely With QEMU (No Reboot Required)

### Step 7A — Create a Virtual Disk for Testing
```bash
qemu-img create -f qcow2 /tmp/kirat-test-disk.qcow2 30G
```

### Step 7B — Launch QEMU with KVM Acceleration
```bash
qemu-system-x86_64 \
    -enable-kvm \
    -m 8192 \
    -smp 4 \
    -cdrom /tmp/kirat-os-2.0.0.iso \
    -hda /tmp/kirat-test-disk.qcow2 \
    -boot d \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -display gtk
```

**What this does:**
- `-enable-kvm` → Uses your i7's hardware virtualization (fast)
- `-m 8192` → Gives the VM 8 GB RAM
- `-smp 4` → Gives the VM 4 CPU cores
- `-cdrom ... -boot d` → Boots from the ISO (like a virtual USB stick)
- `-hda ...` → Attaches the 30 GB virtual disk for installation testing
- `-display gtk` → Opens a window so you can see the boot screen

### Step 7C — What You Should See
1. GRUB menu with options: **"Try KIRAT OS Live"** and **"Install KIRAT OS"**
2. If you pick "Try Live," you get a Debian desktop to explore
3. If you pick "Install," the native installer (`install-native.sh`) launches and walks you through partitioning and installation onto the virtual disk

### Step 7D — After Testing, Clean Up
```bash
rm /tmp/kirat-test-disk.qcow2
```

---

## 8. Create a Bootable USB (To Install on Real Hardware)

### Step 8A — Copy ISO Back to Windows
```bash
cp /tmp/kirat-os-2.0.0.iso /mnt/c/Users/#RAI/Desktop/
```

### Step 8B — Flash to USB (In Windows, as Admin)
Use **Rufus** (https://rufus.ie):
1. Download and run Rufus
2. Select your USB drive (minimum 8 GB)
3. Select `kirat-os-2.0.0.iso`
4. Partition scheme: **GPT** for UEFI, **MBR** for BIOS
5. Click **START**

### Step 8C — Boot from USB
1. Plug the USB into your target machine
2. Power on and press the boot menu key (usually F12, F10, or Esc)
3. Select the USB drive
4. Choose **"Install KIRAT OS"**

---

## 9. Post-Install: First Boot on Real Hardware

After the installer finishes and reboots:

1. **LUKS passphrase prompt** — Enter the disk encryption key
2. **First-boot script runs automatically** — You will be asked to:
   - Set the **root** password
   - Set the **kirat-admin** password
   - Generate SSH keypair for `kirat-admin`
   - Download AI models (~30 GB) — **skip this if offline**, pull later with `ollama pull`
3. **Enroll MOK** (UEFI only) — If you want Secure Boot:
   ```bash
   sudo mokutil --import /opt/kirat-os/security/mok/MOK.der
   # Reboot and follow the blue MOK enrollment screen
   ```

---

## 10. Daily RBAC Commands (Quick Reference)

| Task | Command |
|------|---------|
| Check AI agent status | `kirat-admin agent status` |
| Delegate a command to an AI agent | `kirat-admin instruction create executor-ai "systemctl status nginx"` |
| List pending instructions | `kirat-admin instruction list` |
| View audit log | `kirat-admin audit report` |
| Switch to DevSecOps user | `su - security-officer` |
| SSH into server | `ssh kirat-admin@<server-ip>` |

---

## 11. Troubleshooting

| Problem | Fix |
|---------|-----|
| WSL2 install fails | Enable virtualization in BIOS: `Intel VT-x` must be ON |
| `debootstrap` fails | Check internet: `ping 8.8.8.8` |
| ISO too large | Use `--compression gzip` for faster but larger builds |
| QEMU is slow | Ensure `/dev/kvm` exists; run `sudo usermod -aG kvm $USER` and restart WSL |
| Out of disk during build | Free up space or set `TMPDIR=/mnt/d/tmp` to use another drive |

---

## 12. Next Steps After ISO Build

1. ✅ Build ISO in WSL2
2. ✅ Test in QEMU
3. ⬜ Flash to USB
4. ⬜ Install on bare-metal server or laptop
5. ⬜ Run first-boot setup
6. ⬜ Enroll MOK for Secure Boot (optional)
7. ⬜ Configure TPM 2.0 auto-unlock (optional)
8. ⬜ Pull Ollama models and start Sentinel AI

---

**Teacher, when you are ready, run Step 3 to install WSL2 + Debian, then come back and I will guide you through each command in Step 4 and beyond.**
