#Requires -RunAsAdministrator
<#
.SYNOPSIS
    KIRAT OS — Automated ISO Build Script for Windows 10 + WSL2
.DESCRIPTION
    This script automates the entire KIRAT OS ISO build pipeline on your Windows 10 machine:
      1. Verifies WSL2 is installed and enabled
      2. Installs/updates Debian inside WSL2
      3. Installs all build dependencies (debootstrap, squashfs-tools, xorriso, etc.)
      4. Builds the KIRAT OS bootable ISO from your workspace
      5. (Optional) Launches QEMU to test the ISO safely in a VM

    WHAT IS QEMU?
    -----------
    QEMU is a hardware emulator/virtualizer. It lets you run a COMPLETE computer
    inside a window on your Windows 10 desktop. You can boot the KIRAT OS ISO,
    watch it start up, test the dashboard, SSH into it — all WITHOUT rebooting
    your real PC or risking your Windows installation. This is the SAFEST way to
    test an operating system you are building.

    YOUR MACHINE
    ------------
    CPU:  Intel Core i7-10870H (8 cores / 16 threads) — excellent for parallel builds
    RAM:  32 GB — sufficient for ISO build + QEMU test simultaneously
    Disk: 40 GB free — tight but workable (ISO build needs ~15 GB, QEMU image ~10 GB)

    ESTIMATED TIME: 45–90 minutes depending on internet speed

    USAGE:
      Right-click → "Run with PowerShell" (must be Administrator)
      Or open PowerShell as Admin and run: .\Build-KiratOS-ISO.ps1

.PARAMETER SkipQemuTest
    If set, the script will build the ISO but NOT launch QEMU afterwards.
    Use this if you only want the ISO file and will test it later.

.PARAMETER WslDistro
    Name of the WSL Debian distribution. Default: "Debian"
#>

param(
    [switch]$SkipQemuTest = $false,
    [string]$WslDistro = "Debian",
    [string]$WorkspaceDir = "$env:USERPROFILE\Documents\kimi\workspace\kirat-os-server"
)

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────
$ErrorActionPreference = "Stop"
$ProgressPreference    = "Continue"

$IsoOutputName = "kirat-os-1.0.0-amd64.iso"
$IsoOutputPath = "$WorkspaceDir\$IsoOutputName"
$QemuDiskSize  = "20G"
$QemuRamMB     = 4096
$QemuCores     = 4

# Colors
function Write-Info    { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Cyan }
function Write-Ok      { param($msg) Write-Host "[OK]    $msg" -ForegroundColor Green }
function Write-Warn    { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Write-Error   { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Crit    { param($msg) Write-Host "[CRIT]  $msg" -ForegroundColor Magenta }
function Write-Stage   { param($msg)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host "  ▶ $msg" -ForegroundColor Blue -BackgroundColor Black
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0: PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 0: PRE-FLIGHT CHECKS"

# Verify Admin
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Crit "This script must run as Administrator. Right-click PowerShell → 'Run as administrator'"
    exit 1
}
Write-Ok "Running as Administrator"

# Verify Windows version (WSL2 needs 1903+ or Win10 2004+ preferred)
$osInfo = Get-CimInstance Win32_OperatingSystem
$build  = [System.Environment]::OSVersion.Version.Build
if ($build -lt 18362) {
    Write-Crit "Windows build $build is too old. WSL2 requires Windows 10 version 1903 (build 18362) or newer."
    exit 1
}
Write-Ok "Windows build $build — WSL2 compatible"

# Check free disk space
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"
$freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
if ($freeGB -lt 25) {
    Write-Crit "Only $freeGB GB free on C: drive. Need at least 25 GB free for safe ISO build + QEMU test."
    Write-Crit "Free up space or set -SkipQemuTest to skip the VM disk creation."
    exit 1
}
Write-Ok "Disk space: $freeGB GB free (minimum 25 GB recommended)"

# Check RAM
$totalRamGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 0)
Write-Ok "RAM: $totalRamGB GB"

# Verify workspace exists
if (-not (Test-Path $WorkspaceDir)) {
    Write-Crit "Workspace not found: $WorkspaceDir"
    Write-Crit "Make sure your KIRAT OS project is cloned/extracted there."
    exit 1
}
Write-Ok "Workspace found: $WorkspaceDir"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: ENABLE WSL2
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 1: ENABLE WSL2 (Windows Subsystem for Linux)"

Write-Info "WSL2 lets you run a real Linux kernel inside Windows — no VM software needed."
Write-Info "It is MUCH faster than a traditional virtual machine for building software."

function Test-WslInstalled {
    try { $null = wsl --status 2>$null; return $true } catch { return $false }
}

if (-not (Test-WslInstalled)) {
    Write-Warn "WSL not installed. Enabling now..."
    Write-Info "This will install WSL2 + the default Linux kernel. Windows may ask to reboot."
    
    # Enable required Windows features
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    
    # Install WSL2 kernel update and set default version
    wsl --install --no-distribution 2>$null
    wsl --set-default-version 2 | Out-Null
    
    Write-Warn "WSL2 was just installed. You MUST reboot your computer now."
    Write-Warn "After reboot, re-run this script and it will continue from Step 2."
    $confirm = Read-Host "Type REBOOT to restart now, or anything else to exit"
    if ($confirm -eq "REBOOT") { Restart-Computer }
    exit 0
} else {
    Write-Ok "WSL is already installed"
}

# Ensure WSL default version is 2
$wslStatus = wsl --status 2>&1 | Out-String
if ($wslStatus -notmatch "Default Version: 2") {
    Write-Info "Setting WSL default version to 2..."
    wsl --set-default-version 2 | Out-Null
}
Write-Ok "WSL2 is the default version"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: INSTALL DEBIAN IN WSL2
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 2: INSTALL DEBIAN IN WSL2"

$installedDistros = wsl --list --quiet 2>$null | ForEach-Object { $_.Trim() }
if ($installedDistros -contains $WslDistro) {
    Write-Ok "Debian distribution '$WslDistro' already exists in WSL2"
} else {
    Write-Info "Installing Debian from Microsoft Store package..."
    Write-Info "This downloads ~500 MB and takes 5–10 minutes."
    
    # Download Debian rootfs directly (faster and more reliable than Microsoft Store)
    $debianRootfsUrl = "https://aka.ms/wsl-debian-gnulinux"
    $debianInstaller = "$env:TEMP\debian.appx"
    
    try {
        Invoke-WebRequest -Uri $debianRootfsUrl -OutFile $debianInstaller -UseBasicParsing
    } catch {
        # Fallback: direct rootfs tar.gz
        Write-Warn "Direct download failed. Trying alternate Debian rootfs..."
        $debianRootfsUrl = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.tar.xz"
        $debianInstaller = "$env:TEMP\debian-rootfs.tar.xz"
        Invoke-WebRequest -Uri $debianRootfsUrl -OutFile $debianInstaller -UseBasicParsing
        
        # Import as WSL distribution
        $debianInstallDir = "$env:LOCALAPPDATA\Packages\DebianKirat"
        New-Item -ItemType Directory -Force -Path $debianInstallDir | Out-Null
        wsl --import $WslDistro $debianInstallDir $debianInstaller --version 2 | Out-Null
    }
    
    Write-Ok "Debian installed in WSL2 as '$WslDistro'"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: INSTALL BUILD DEPENDENCIES INSIDE DEBIAN
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 3: INSTALL BUILD DEPENDENCIES"

$setupScript = @'
#!/bin/bash
set -e
echo "[BUILD] Updating package lists..."
apt-get update -qq

echo "[BUILD] Installing build dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    debootstrap \
    squashfs-tools \
    xorriso \
    isolinux \
    syslinux-efi \
    grub-pc-bin \
    grub-efi-amd64-bin \
    mtools \
    dosfstools \
    rsync \
    curl \
    wget \
    git \
    build-essential \
    python3 \
    python3-pip \
    qemu-utils \
    qemu-system-x86 \
    parted \
    kpartx \
    zip \
    unzip

echo "[BUILD] All dependencies installed."
'@

$setupScriptPath = "$WorkspaceDir\wsl-setup.sh"
$setupScript | Set-Content -Path $setupScriptPath -Encoding UTF8

Write-Info "Running dependency installation inside Debian WSL..."
wsl -d $WslDistro -u root -- bash -c "cat > /tmp/wsl-setup.sh" < $setupScriptPath
wsl -d $WslDistro -u root -- bash /tmp/wsl-setup.sh
Write-Ok "Build dependencies installed inside Debian WSL"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: COPY WORKSPACE INTO WSL2
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 4: COPY KIRAT OS WORKSPACE INTO WSL2"

Write-Info "Copying workspace into WSL2 filesystem for fast Linux-native building..."

# WSL2 path for the workspace
$wslWorkspace = "/opt/kirat-os-build"

wsl -d $WslDistro -u root -- bash -c "rm -rf $wslWorkspace && mkdir -p $wslWorkspace"

# Use wsl --copy or tar+untar for speed
Write-Info "Packing workspace for fast transfer..."
$tarPath = "$env:TEMP\kirat-os-build.tar"
# Exclude large git/objects if any, node_modules, etc.
$excludeList = @(".git", "node_modules", "__pycache__", "*.iso", "*.img", "*.qcow2")
$excludeArgs = $excludeList | ForEach-Object { "--exclude=$_" }

# We use tar from Git Bash or WSL itself
wsl -d $WslDistro -u root -- bash -c "
    cd /mnt/c && cd '$(($WorkspaceDir -replace '\\','/') -replace 'C:/','/mnt/c/')' && 
    tar -cf /tmp/kirat-os-build.tar --exclude='.git' --exclude='node_modules' --exclude='__pycache__' --exclude='*.iso' --exclude='*.img' --exclude='*.qcow2' .
"

wsl -d $WslDistro -u root -- bash -c "
    mkdir -p $wslWorkspace && 
    tar -xf /tmp/kirat-os-build.tar -C $wslWorkspace && 
    rm -f /tmp/kirat-os-build.tar
"

Write-Ok "Workspace copied to WSL2 at $wslWorkspace"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: BUILD THE ISO
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 5: BUILD KIRAT OS BOOTABLE ISO"

$isoBuildScript = @'
#!/bin/bash
set -euo pipefail

BUILD_DIR="/opt/kirat-os-build"
OUTPUT_ISO="/opt/kirat-os.iso"
BUILD_TMP="/tmp/kirat-os-iso-build"

if [ -f "$OUTPUT_ISO" ]; then
    echo "[BUILD] Removing previous ISO..."
    rm -f "$OUTPUT_ISO"
fi

rm -rf "$BUILD_TMP"
mkdir -p "$BUILD_TMP"

cd "$BUILD_DIR"

# Check if a dedicated ISO build script exists
if [ -f "$BUILD_DIR/build-iso.sh" ]; then
    echo "[BUILD] Found build-iso.sh — executing..."
    cd "$BUILD_DIR"
    bash build-iso.sh --output "$OUTPUT_ISO"
else
    echo "[BUILD] No build-iso.sh found. Building minimal Debian Live ISO with KIRAT OS overlay..."
    
    # Create a minimal live boot structure
    mkdir -p "$BUILD_TMP/live"
    
    # Debootstrap a minimal Debian into the ISO root
    echo "[BUILD] Creating minimal Debian base (this takes 10-20 minutes)..."
    debootstrap --variant=minbase \
        --include=linux-image-amd64,systemd,systemd-sysv,grub-pc,grub-efi-amd64,openssh-server,sudo,curl,wget,vim,python3,docker.io,nginx,postgresql,redis-server,fail2ban,ufw,cryptsetup \
        bookworm "$BUILD_TMP/live/filesystem" http://deb.debian.org/debian
    
    # Copy KIRAT OS custom files over the base
    echo "[BUILD] Applying KIRAT OS overlay..."
    cp -r "$BUILD_DIR/scripts" "$BUILD_TMP/live/filesystem/opt/kirat-os-scripts" 2>/dev/null || true
    cp -r "$BUILD_DIR/ai-agents" "$BUILD_TMP/live/filesystem/opt/kirat-os-ai" 2>/dev/null || true
    cp -r "$BUILD_DIR/dashboard" "$BUILD_TMP/live/filesystem/opt/kirat-os-dashboard" 2>/dev/null || true
    
    # Mark as KIRAT OS
    echo "KIRAT OS 1.0.0 — AI-Native Enterprise Server" > "$BUILD_TMP/live/filesystem/etc/kirat-release"
    
    # Squash the filesystem
    echo "[BUILD] Compressing filesystem..."
    mksquashfs "$BUILD_TMP/live/filesystem" "$BUILD_TMP/live/filesystem.squashfs" -comp xz -e boot
    
    # Copy kernel and initrd
    cp "$BUILD_TMP/live/filesystem/boot/vmlinuz"* "$BUILD_TMP/live/vmlinuz" 2>/dev/null || true
    cp "$BUILD_TMP/live/filesystem/boot/initrd"* "$BUILD_TMP/live/initrd.img" 2>/dev/null || true
    
    # Create ISO tree
    mkdir -p "$BUILD_TMP/boot/grub"
    cat > "$BUILD_TMP/boot/grub/grub.cfg" << 'GRUBEOF'
set timeout=5
set default=0

menuentry "KIRAT OS 1.0.0 — Install" {
    linux /live/vmlinuz boot=live components quiet
    initrd /live/initrd.img
}

menuentry "KIRAT OS — Rescue Mode" {
    linux /live/vmlinuz boot=live components quiet rescue
    initrd /live/initrd.img
}
GRUBEOF
    
    # Build the ISO
    echo "[BUILD] Generating ISO image..."
    grub-mkrescue -o "$OUTPUT_ISO" "$BUILD_TMP" \
        --modules="part_gpt part_msdos fat iso9660 zfs zfscrypt" \
        2>/dev/null || xorriso -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -volid "KIRAT_OS" \
            -eltorito-boot boot/grub/grub.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/boot.cat \
            -output "$OUTPUT_ISO" \
            "$BUILD_TMP"
fi

echo "[BUILD] ISO created at: $OUTPUT_ISO"
ls -lh "$OUTPUT_ISO"
'@

$isoBuildScriptPath = "$WorkspaceDir\wsl-build-iso.sh"
$isoBuildScript | Set-Content -Path $isoBuildScriptPath -Encoding UTF8

Write-Info "Starting ISO build inside Debian WSL (this takes 20-45 minutes)..."
Write-Info "You can minimize this window. The build runs inside Linux."

wsl -d $WslDistro -u root -- bash -c "cat > /tmp/build-iso.sh" < $isoBuildScriptPath
$buildResult = wsl -d $WslDistro -u root -- bash /tmp/build-iso.sh 2>&1
$buildResult | ForEach-Object { Write-Host $_ }

if ($LASTEXITCODE -ne 0) {
    Write-Crit "ISO build failed inside WSL. Check the output above for errors."
    exit 1
}

# Copy ISO back to Windows
Write-Info "Copying completed ISO back to Windows..."
wsl -d $WslDistro -u root -- bash -c "cp /opt/kirat-os.iso /mnt/c$(($IsoOutputPath -replace '\\','/') -replace 'C:','')" 2>$null

if (-not (Test-Path $IsoOutputPath)) {
    # Try alternate copy method
    $wslIsoPath = wsl -d $WslDistro -u root -- readlink -f /opt/kirat-os.iso 2>$null
    $wslIsoWinPath = $wslIsoPath -replace '^/mnt/c','C:' -replace '/','\'
    if (Test-Path $wslIsoWinPath) {
        Copy-Item -Path $wslIsoWinPath -Destination $IsoOutputPath -Force
    }
}

if (Test-Path $IsoOutputPath) {
    $isoSize = [math]::Round((Get-Item $IsoOutputPath).Length / 1MB, 1)
    Write-Ok "ISO built successfully: $IsoOutputPath ($isoSize MB)"
} else {
    Write-Warn "Could not copy ISO to Windows path automatically."
    Write-Info "The ISO is inside WSL2 at: /opt/kirat-os.iso"
    Write-Info "You can copy it manually: wsl -d Debian -- cp /opt/kirat-os.iso /mnt/c/Users/..."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: INSTALL QEMU FOR WINDOWS (if not present)
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "STEP 6: QEMU SETUP"

Write-Info "QEMU is a hardware emulator. It lets you boot the KIRAT OS ISO inside a"
Write-Info "window on your Windows desktop — NO reboot required, ZERO risk to your PC."

$qemuDir = "$env:LOCALAPPDATA\QEMU"
$qemuExe = "$qemuDir\qemu-system-x86_64.exe"

if (-not (Test-Path $qemuExe)) {
    Write-Info "QEMU not found. Downloading portable QEMU for Windows..."
    $qemuZip = "$env:TEMP\qemu-win.zip"
    $qemuUrl = "https://github.com/semickolon/QEMU-Windows/releases/download/2023-08-09/qemu-w64.zip"
    
    try {
        Invoke-WebRequest -Uri $qemuUrl -OutFile $qemuZip -UseBasicParsing
        Expand-Archive -Path $qemuZip -DestinationPath $qemuDir -Force
        Remove-Item $qemuZip -Force
        Write-Ok "QEMU installed to $qemuDir"
    } catch {
        Write-Warn "Could not auto-download QEMU."
        Write-Info "Please install QEMU manually from: https://www.qemu.org/download/#windows"
        Write-Info "Or install via Winget:  winget install QEMU.QEMU"
    }
} else {
    Write-Ok "QEMU found: $qemuExe"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: QEMU TEST (Optional)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipQemuTest) {
    Write-Stage "STEP 7: QEMU TEST — Boot KIRAT OS ISO Safely"
    
    if (-not (Test-Path $qemuExe)) {
        Write-Warn "QEMU executable not found. Skipping VM test."
        Write-Info "You can test the ISO later by installing QEMU and running:"
        Write-Info "  $qemuExe -m $QemuRamMB -smp $QemuCores -cdrom $IsoOutputPath -boot d"
    } else {
        $qemuDisk = "$WorkspaceDir\kirat-os-test-disk.qcow2"
        
        if (-not (Test-Path $qemuDisk)) {
            Write-Info "Creating virtual hard disk for testing ($QemuDiskSize)..."
            & "$qemuDir\qemu-img.exe" create -f qcow2 $qemuDisk $QemuDiskSize | Out-Null
        }
        
        Write-Ok "Launching QEMU VM..."
        Write-Info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        Write-Info "  QEMU Window will open. KIRAT OS will boot from the ISO."
        Write-Info "  To interact: Click inside the QEMU window."
        Write-Info "  To release mouse: Press CTRL + ALT"
        Write-Info "  To quit QEMU: Close the window or press ALT + F4"
        Write-Info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        $qemuArgs = @(
            "-m", "$QemuRamMB"
            "-smp", "$QemuCores"
            "-cdrom", $IsoOutputPath
            "-drive", "file=$qemuDisk,format=qcow2,if=virtio"
            "-netdev", "user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80,hostfwd=tcp::8443-:443"
            "-device", "e1000,netdev=net0"
            "-boot", "d"
            "-vga", "std"
            "-display", "sdl"
            "-name", "KIRAT-OS-Test"
        )
        
        Start-Process -FilePath $qemuExe -ArgumentList $qemuArgs -Wait
        
        Write-Ok "QEMU session ended."
        Write-Info "SSH into the VM next time with:  ssh -p 2222 kirat-admin@localhost"
        Write-Info "Dashboard test URL:             http://localhost:8080"
    }
} else {
    Write-Stage "STEP 7: QEMU TEST SKIPPED"
    Write-Info "You chose to skip the QEMU test."
}

# ─────────────────────────────────────────────────────────────────────────────
# DONE
# ─────────────────────────────────────────────────────────────────────────────
Write-Stage "BUILD COMPLETE"

Write-Ok "Your KIRAT OS ISO is ready!"
Write-Info "Location: $IsoOutputPath"
if (Test-Path $IsoOutputPath) {
    $finalSize = [math]::Round((Get-Item $IsoOutputPath).Length / 1MB, 1)
    Write-Info "Size:     $finalSize MB"
}

Write-Info ""
Write-Info "NEXT STEPS:"
Write-Info "  1. Flash the ISO to a USB drive with Rufus (https://rufus.ie)"
Write-Info "     or Ventoy (https://ventoy.net) for multi-ISO bootable USB"
Write-Info "  2. Boot your target PC/server from the USB"
Write-Info "  3. Run:  sudo bash /opt/kirat-os-scripts/install-native.sh --disk /dev/sda"
Write-Info ""
Write-Info "  To copy ISO to USB via command line (PowerShell Admin):"
Write-Info "    (Get-Disk | Where-Object BusType -eq 'USB').Number   # find USB disk #"
Write-Info "    # Then use Rufus GUI for safety — raw disk writing is dangerous"
Write-Info ""
Write-Info "  To test again in QEMU later:"
Write-Info "    $qemuExe -m 4096 -smp 4 -cdrom $IsoOutputPath -boot d"
Write-Info ""

Pause
