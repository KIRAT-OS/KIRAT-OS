#Requires -RunAsAdministrator
<#
.SYNOPSIS
    KIRAT OS — Safe VM Test Script for Windows 10
    Tests the native installer without risking real hardware.

.DESCRIPTION
    This script:
    1. Checks for QEMU or VirtualBox
    2. Downloads Debian 12 Live ISO (if not present)
    3. Creates a 60GB virtual disk
    4. Boots the VM from the ISO
    5. Provides instructions for running install-native.sh inside the VM

    TARGET: Windows 10 with QEMU or VirtualBox installed
    RESULT: Fully functional KIRAT OS VM for safe testing

.EXAMPLE
    .\test-kirat-os-vm.ps1 -VmEngine QEMU -RamGB 8 -DiskGB 60
    .\test-kirat-os-vm.ps1 -VmEngine VirtualBox -RamGB 8 -DiskGB 60
#>

param(
    [ValidateSet("QEMU", "VirtualBox")]
    [string]$VmEngine = "QEMU",

    [int]$RamGB = 8,
    [int]$DiskGB = 60,
    [int]$CpuCores = 4,

    [string]$IsoUrl = "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/debian-live-12.7.0-amd64-standard.iso",
    [string]$IsoFile = "$env:USERPROFILE\Downloads\debian-live-12-amd64-standard.iso",

    [string]$WorkDir = "$env:USERPROFILE\KiratOS-VM-Test",
    [string]$VmName = "KIRAT-OS-TestVM"
)

$ErrorActionPreference = "Stop"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

function Write-Stage([string]$msg) {
    Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  ▶ $msg" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "  [OK]   $msg" -ForegroundColor Green
}

function Write-Warn([string]$msg) {
    Write-Host "  [WARN] $msg" -ForegroundColor Yellow
}

function Write-Crit([string]$msg) {
    Write-Host "  [CRIT] $msg" -ForegroundColor Magenta
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────────

Write-Stage "PRE-FLIGHT: Checking Windows 10 Environment"

# Architecture check
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
    Write-Crit "KIRAT OS requires x86_64. Your CPU architecture is: $env:PROCESSOR_ARCHITECTURE"
    exit 1
}
Write-Ok "Architecture: x86_64 (AMD64)"

# RAM check
$ramTotalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramTotalGB -lt $RamGB) {
    Write-Crit "Insufficient RAM: ${ramTotalGB}GB. Need ${RamGB}GB for VM."
    exit 1
}
Write-Ok "Host RAM: ${ramTotalGB}GB (VM allocated: ${RamGB}GB)"

# Disk space check
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($WorkDir[0])`:"`
$freeGB = [math]::Round($disk.FreeSpace / 1GB)
$neededGB = $DiskGB + 5  # VM disk + ISO + overhead
if ($freeGB -lt $neededGB) {
    Write-Crit "Insufficient disk space: ${freeGB}GB free. Need ${neededGB}GB."
    exit 1
}
Write-Ok "Disk space: ${freeGB}GB free (need ${neededGB}GB)"

# VM engine check
if ($VmEngine -eq "QEMU") {
    $qemuPaths = @(
        "C:\Program Files\qemu\qemu-system-x86_64.exe",
        "C:\qemu\qemu-system-x86_64.exe",
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\qemu-system-x86_64.exe"
    )
    $QemuExe = $qemuPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $QemuExe) {
        Write-Warn "QEMU not found in standard locations."
        Write-Host "`n  QEMU Install Options:" -ForegroundColor Yellow
        Write-Host "    1. Download from https://www.qemu.org/download/#windows" -ForegroundColor White
        Write-Host "    2. Or install via MSYS2: pacman -S mingw-w64-x86_64-qemu" -ForegroundColor White
        Write-Host "    3. Or use VirtualBox instead: .\test-kirat-os-vm.ps1 -VmEngine VirtualBox" -ForegroundColor White
        Write-Host ""
        $choice = Read-Host "  Install QEMU now? (Y=open download page / N=exit / V=switch to VirtualBox)"
        if ($choice -eq 'Y' -or $choice -eq 'y') {
            Start-Process "https://www.qemu.org/download/#windows"
            Write-Warn "Download and install QEMU, then re-run this script."
        }
        elseif ($choice -eq 'V' -or $choice -eq 'v') {
            $VmEngine = "VirtualBox"
            Write-Ok "Switched to VirtualBox engine"
        }
        else {
            exit 1
        }
    }
    else {
        Write-Ok "QEMU found: $QemuExe"
    }
}

if ($VmEngine -eq "VirtualBox") {
    $vboxManage = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
    if (-not (Test-Path $vboxManage)) {
        $vboxManage = "C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe"
    }
    if (-not (Test-Path $vboxManage)) {
        Write-Warn "VirtualBox not found."
        Write-Host "`n  Download from: https://www.virtualbox.org/wiki/Downloads" -ForegroundColor Yellow
        $choice = Read-Host "  Open download page? (Y/N)"
        if ($choice -eq 'Y' -or $choice -eq 'y') {
            Start-Process "https://www.virtualbox.org/wiki/Downloads"
        }
        exit 1
    }
    Write-Ok "VirtualBox found: $vboxManage"
}

Write-Ok "Pre-flight PASSED. Ready to build KIRAT OS test VM."

# ─────────────────────────────────────────────────────────────────────────────
# SETUP WORKSPACE
# ─────────────────────────────────────────────────────────────────────────────

Write-Stage "SETUP: Creating Workspace"

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
}
Write-Ok "Workspace: $WorkDir"

# ─────────────────────────────────────────────────────────────────────────────
# DOWNLOAD DEBIAN LIVE ISO
# ─────────────────────────────────────────────────────────────────────────────

Write-Stage "DOWNLOAD: Debian 12 Live ISO"

if (Test-Path $IsoFile) {
    Write-Ok "ISO already exists: $IsoFile"
}
else {
    Write-Warn "Debian Live ISO not found. Downloading... (~400MB - 3GB depending on variant)"
    Write-Host "  URL: $IsoUrl" -ForegroundColor Gray
    Write-Host "  This may take 5-30 minutes depending on your internet speed." -ForegroundColor Gray
    Write-Host ""

    try {
        # Use BITS for reliable download (Windows built-in)
        Import-Module BitsTransfer -ErrorAction SilentlyContinue
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $IsoUrl -Destination $IsoFile -Description "Debian Live ISO" -DisplayName "KIRAT OS VM Setup"
        }
        else {
            Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoFile -UseBasicParsing
        }
        Write-Ok "ISO downloaded: $IsoFile"
    }
    catch {
        Write-Crit "Download failed: $_"
        Write-Host "  Please download manually from: $IsoUrl" -ForegroundColor Yellow
        Write-Host "  Save to: $IsoFile" -ForegroundColor Yellow
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CREATE VIRTUAL DISK
# ─────────────────────────────────────────────────────────────────────────────

Write-Stage "DISK: Creating ${DiskGB}GB Virtual Disk"

if ($VmEngine -eq "QEMU") {
    $diskFile = "$WorkDir\$VmName-disk.img"
    if (-not (Test-Path $diskFile)) {
        & "$QemuExe" -drive file=$diskFile,if=none,id=drive0 2>$null
        if (-not (Test-Path $diskFile)) {
            # qemu-img might be in the same dir
            $qemuImg = Join-Path (Split-Path $QemuExe) "qemu-img.exe"
            & $qemuImg create -f raw $diskFile "${DiskGB}G" | Out-Null
        }
        Write-Ok "QEMU disk created: $diskFile (${DiskGB}GB raw)"
    }
    else {
        Write-Warn "Disk already exists: $diskFile"
        $confirm = Read-Host "  Overwrite? (Y/N)"
        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
            Remove-Item $diskFile -Force
            $qemuImg = Join-Path (Split-Path $QemuExe) "qemu-img.exe"
            & $qemuImg create -f raw $diskFile "${DiskGB}G" | Out-Null
            Write-Ok "QEMU disk recreated: $diskFile"
        }
    }
}
elseif ($VmEngine -eq "VirtualBox") {
    $diskFile = "$WorkDir\$VmName-disk.vdi"
    # Check if VM already exists
    $existing = & $vboxManage list vms | Select-String -Pattern "`"$VmName`""
    if ($existing) {
        Write-Warn "VM '$VmName' already exists."
        $confirm = Read-Host "  Delete and recreate? (Y/N)"
        if ($confirm -eq 'Y' -or $confirm -eq 'y') {
            & $vboxManage unregistervm "$VmName" --delete 2>$null
        }
        else {
            exit 1
        }
    }

    # Create VM
    & $vboxManage createvm --name "$VmName" --ostype Debian_64 --register | Out-Null
    & $vboxManage modifyvm "$VmName" --memory $($RamGB * 1024) --cpus $CpuCores --firmware efi
    & $vboxManage modifyvm "$VmName" --nic1 nat --boot1 dvd --boot2 disk

    # Create disk
    & $vboxManage createhd --filename $diskFile --size $($DiskGB * 1024) --format VDI | Out-Null
    & $vboxManage storagectl "$VmName" --name "SATA" --add sata --controller IntelAhci
    & $vboxManage storageattach "$VmName" --storagectl "SATA" --port 0 --device 0 --type hdd --medium $diskFile
    & $vboxManage storageattach "$VmName" --storagectl "SATA" --port 1 --device 0 --type dvddrive --medium $IsoFile

    Write-Ok "VirtualBox VM created: $VmName"
    Write-Ok "Disk: $diskFile (${DiskGB}GB VDI)"
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOT VM
# ─────────────────────────────────────────────────────────────────────────────

Write-Stage "BOOT: Starting KIRAT OS Test VM"

Write-Host "`n  ┌─────────────────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  KIRAT OS VM TEST ENVIRONMENT                               │" -ForegroundColor Cyan
Write-Host "  ├─────────────────────────────────────────────────────────────┤" -ForegroundColor Cyan
Write-Host "  │  Engine:    $VmEngine" -ForegroundColor Cyan
Write-Host "  │  RAM:       ${RamGB}GB" -ForegroundColor Cyan
Write-Host "  │  CPU:       ${CpuCores} cores" -ForegroundColor Cyan
Write-Host "  │  Disk:      ${DiskGB}GB" -ForegroundColor Cyan
Write-Host "  │  ISO:       $([System.IO.Path]::GetFileName($IsoFile))" -ForegroundColor Cyan
Write-Host "  └─────────────────────────────────────────────────────────────┘" -ForegroundColor Cyan

Write-Host "`n  WHAT WILL HAPPEN:" -ForegroundColor Yellow
Write-Host "    1. Debian Live will boot inside the VM" -ForegroundColor White
Write-Host "    2. Open a terminal inside the VM" -ForegroundColor White
Write-Host "    3. Run: sudo bash install-native.sh --disk /dev/sda --hostname test-kirat" -ForegroundColor White
Write-Host "    4. The VM disk (not your real disk) will be wiped and KIRAT OS installed" -ForegroundColor White
Write-Host "    5. After install, remove the ISO and reboot to test KIRAT OS" -ForegroundColor White

Write-Host "`n  PRESS ANY KEY TO START THE VM..." -ForegroundColor Green
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

if ($VmEngine -eq "QEMU") {
    # QEMU command with reasonable defaults for testing
    $qemuArgs = @(
        "-m", "$($RamGB * 1024)"
        "-smp", "$CpuCores"
        "-hda", $diskFile
        "-cdrom", $IsoFile
        "-boot", "d"
        "-vga", "std"
        "-netdev", "user,id=net0,hostfwd=tcp::2222-:22"
        "-device", "e1000,netdev=net0"
        "-name", $VmName
        "-no-reboot"
    )

    Write-Ok "Launching QEMU..."
    Write-Host "  Command: $QemuExe $qemuArgs" -ForegroundColor DarkGray
    Write-Host ""

    # Launch QEMU (this blocks until VM shuts down)
    & $QemuExe @qemuArgs

    Write-Host "`n  QEMU session ended." -ForegroundColor Yellow
}
elseif ($VmEngine -eq "VirtualBox") {
    Write-Ok "Launching VirtualBox..."
    & $vboxManage startvm "$VmName" --type gui

    Write-Host "`n  VirtualBox VM '$VmName' is running in a separate window." -ForegroundColor Yellow
    Write-Host "  When finished testing, run:" -ForegroundColor Yellow
    Write-Host "    VBoxManage controlvm `"$VmName`" poweroff" -ForegroundColor White
}

# ─────────────────────────────────────────────────────────────────────────────
# POST-VM INSTRUCTIONS
# ─────────────────────────────────────────────────────────────────────────────

Write-Stage "POST-TEST: Instructions"

Write-Host @"

  AFTER KIRAT OS INSTALLS INSIDE THE VM:
  ─────────────────────────────────────────

  1. SHUT DOWN the VM
  2. REMOVE the ISO (so it boots from disk next time):
"@ -ForegroundColor White

if ($VmEngine -eq "QEMU") {
    Write-Host "     Just re-run this script without the -cdrom flag," -ForegroundColor Cyan
    Write-Host "     or run QEMU manually with ONLY the disk:" -ForegroundColor Cyan
    Write-Host "       qemu-system-x86_64 -m 8192 -hda `"$diskFile`" -vga std" -ForegroundColor Green
}
elseif ($VmEngine -eq "VirtualBox") {
    Write-Host "     In VirtualBox Manager, select VM → Settings → Storage" -ForegroundColor Cyan
    Write-Host "     Remove the ISO from the optical drive, then start VM again" -ForegroundColor Cyan
}

Write-Host @"

  3. TEST KIRAT OS:
     - Login as kirat-admin
     - Check services: sudo systemctl status nginx ssh ollama sentinel
     - Open browser: https://localhost (inside VM) or forward ports from host

  4. SSH FROM HOST (QEMU port forward on :2222):
     ssh -p 2222 kirat-admin@localhost

  5. CLEAN UP WHEN DONE:
"@ -ForegroundColor White

if ($VmEngine -eq "QEMU") {
    Write-Host "     Remove disk: Remove-Item `"$diskFile`"" -ForegroundColor Green
}
elseif ($VmEngine -eq "VirtualBox") {
    Write-Host "     Delete VM: VBoxManage unregistervm `"$VmName`" --delete" -ForegroundColor Green
}

Write-Host "`n  KIRAT OS VM test complete! 🛡️" -ForegroundColor Green
