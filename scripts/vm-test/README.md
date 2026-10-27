# KIRAT OS — VM Test Environment

Test the KIRAT OS native installer safely inside a virtual machine before wiping any real hardware.

---

## Option 1: PowerShell (Windows 10/11) — QEMU or VirtualBox

```powershell
# Open PowerShell as Administrator
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
.\scripts\vm-test\test-kirat-os-vm.ps1 -VmEngine QEMU -RamGB 8 -DiskGB 60
```

**Requirements:**
- QEMU for Windows: https://www.qemu.org/download/#windows
- OR VirtualBox: https://www.virtualbox.org/wiki/Downloads

**What it does:**
1. Downloads Debian 12 Live ISO (~400MB)
2. Creates a 60GB virtual disk
3. Boots QEMU/VirtualBox with the ISO
4. You run `install-native.sh` inside the VM
5. KIRAT OS installs on the VM disk (not your real disk)

---

## Option 2: WSL2 or Linux — QEMU

```bash
# Make executable and run
chmod +x scripts/vm-test/test-wsl2-qemu.sh
./scripts/vm-test/test-wsl2-qemu.sh
```

**Requirements:**
```bash
# Debian/Ubuntu
sudo apt-get install qemu-system-x86 qemu-utils wget

# Fedora
sudo dnf install qemu-system-x86 wget

# Arch
sudo pacman -S qemu-full wget
```

**Includes:** 9P virtio share so the VM can access your KIRAT OS project files directly.

---

## Inside the VM: Running the Installer

Once Debian Live boots inside the VM:

```bash
# Open a terminal inside the VM

# For PowerShell/QEMU: files are not auto-shared; copy install-native.sh via SSH or USB
# For WSL2/QEMU: mount the shared folder:
sudo mkdir -p /mnt/kirat
sudo mount -t 9p -o trans=virtio kirat-share /mnt/kirat
cd /mnt/kirat

# Run the installer (THIS WIPES THE VM DISK ONLY):
sudo bash scripts/install-native.sh --disk /dev/sda --hostname test-kirat --domain localhost
```

---

## After Install: Boot KIRAT OS (No ISO)

### PowerShell / QEMU
```powershell
qemu-system-x86_64 -m 8192 -hda "$env:USERPROFILE\KiratOS-VM-Test\KIRAT-OS-TestVM-disk.img" -vga std
```

### WSL2 / Linux
```bash
qemu-system-x86_64 -m 8192 -hda ~/kirat-os-vm-test/kirat-os-test-disk.img -vga std
```

### VirtualBox
Remove the ISO from the VM's optical drive in VirtualBox Manager, then start the VM.

---

## SSH into the VM from Host

QEMU port-forwards host port `2222` → VM port `22`:

```bash
ssh -p 2222 kirat-admin@localhost
```

---

## Cleanup

```powershell
# Windows (PowerShell)
Remove-Item -Recurse -Force "$env:USERPROFILE\KiratOS-VM-Test"

# Linux / WSL2
rm -rf ~/kirat-os-vm-test
```

---

## ⚠️ Safety Reminder

These scripts create **virtual disks** — they do NOT touch your real Windows C: drive or physical hardware. The `install-native.sh` inside the VM only sees the virtual disk (`/dev/sda`).
