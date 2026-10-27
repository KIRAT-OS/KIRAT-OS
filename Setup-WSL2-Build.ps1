# KIRAT OS — WSL2 Build Environment Setup Guide
# For Windows 10 with Intel i7-10870H, 32GB RAM, 40GB free space
# Run this in PowerShell AS ADMINISTRATOR

# =============================================================================
# STEP 0: CHECK FREE SPACE (need at least 20GB)
# =============================================================================
$freeSpaceGB = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
Write-Host "Free space on C: drive: $freeSpaceGB GB" -ForegroundColor Cyan
if ($freeSpaceGB -lt 20) {
    Write-Host "WARNING: You need at least 20GB free to build the ISO." -ForegroundColor Red
    Write-Host "Please free up space before continuing." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# =============================================================================
# STEP 1: ENABLE WSL2
# =============================================================================
Write-Host "`n[1/7] Enabling WSL2..." -ForegroundColor Green

# Check if WSL is already installed
$wslCheck = wsl --status 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Host "WSL is already installed. Skipping enablement." -ForegroundColor Yellow
} else {
    # Enable required Windows features
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
    
    # Set WSL default version to 2
    wsl --set-default-version 2
    
    Write-Host "WSL2 enabled. You may need to RESTART your PC if this is first-time setup." -ForegroundColor Yellow
    $restart = Read-Host "Restart now? (y/n)"
    if ($restart -eq 'y') {
        Restart-Computer
    }
}

# =============================================================================
# STEP 2: INSTALL DEBIAN IN WSL2
# =============================================================================
Write-Host "`n[2/7] Installing Debian in WSL2..." -ForegroundColor Green

$debianCheck = wsl -d Debian -e echo "ok" 2>$null
if ($debianCheck -eq "ok") {
    Write-Host "Debian already installed in WSL2." -ForegroundColor Yellow
} else {
    Write-Host "Installing Debian from Microsoft Store..." -ForegroundColor Cyan
    wsl --install -d Debian
    Write-Host "Debian installation initiated. Follow prompts to create a UNIX username and password." -ForegroundColor Cyan
    Write-Host "After Debian setup completes, run this script again." -ForegroundColor Cyan
    Read-Host "Press Enter after Debian setup is complete"
}

# =============================================================================
# STEP 3: UPDATE DEBIAN AND INSTALL BUILD DEPENDENCIES
# =============================================================================
Write-Host "`n[3/7] Updating Debian and installing build dependencies..." -ForegroundColor Green

$setupScript = @'
#!/bin/bash
set -e

echo "=== Updating Debian packages ==="
apt-get update -qq

echo "=== Installing build dependencies ==="
apt-get install -y -qq \
    debootstrap \
    grub-pc-bin \
    grub-efi-amd64-bin \
    grub-efi-amd64 \
    xorriso \
    squashfs-tools \
    curl \
    wget \
    git \
    make \
    python3 \
    python3-pip \
    qemu-system-x86 \
    qemu-utils \
    2>/dev/null || {
    echo "Some packages failed, retrying with individual installs..."
    apt-get install -y debootstrap xorriso squashfs-tools qemu-system-x86
}

echo "=== Verifying installations ==="
debootstrap --version
xorriso --version | head -1
mksquashfs -version | head -1
qemu-system-x86_64 --version | head -1

echo "=== Build environment READY ==="
'@

# Write setup script to temp file and execute in WSL
$setupScript | Out-File -Encoding UTF8 "$env:TEMP\kirat-wsl-setup.sh" -Force
wsl -d Debian -e bash -c "cat > /tmp/kirat-wsl-setup.sh" < "$env:TEMP\kirat-wsl-setup.sh"
wsl -d Debian -e bash /tmp/kirat-wsl-setup.sh

# =============================================================================
# STEP 4: COPY KIRAT OS SOURCE INTO WSL2
# =============================================================================
Write-Host "`n[4/7] Copying KIRAT OS source into WSL2..." -ForegroundColor Green

$kiratSource = "$env:USERPROFILE\Documents\kimi\workspace\kirat-os-server"
if (Test-Path $kiratSource) {
    Write-Host "Found KIRAT OS source at: $kiratSource" -ForegroundColor Cyan
    wsl -d Debian -e bash -c "mkdir -p /home/`$USER/kirat-build"
    
    # Copy using tar (preserves permissions better than cp through WSL)
    Write-Host "Copying files (this may take a minute)..." -ForegroundColor Cyan
    tar -cf - -C $kiratSource . | wsl -d Debian -e bash -c "tar -xf - -C /home/`$USER/kirat-build"
    
    Write-Host "KIRAT OS source copied to WSL2 at: ~/kirat-build" -ForegroundColor Green
} else {
    Write-Host "WARNING: KIRAT OS source not found at expected location." -ForegroundColor Red
    Write-Host "Expected: $kiratSource" -ForegroundColor Red
    Write-Host "Please ensure the workspace folder exists." -ForegroundColor Red
}

# =============================================================================
# STEP 5: BUILD THE ISO
# =============================================================================
Write-Host "`n[5/7] Ready to build KIRAT OS ISO!" -ForegroundColor Green
Write-Host "`nThe next step will build the bootable ISO. This takes 15-45 minutes depending on your internet speed." -ForegroundColor Cyan
Write-Host "Required: ~15GB disk space in WSL2" -ForegroundColor Cyan

$buildNow = Read-Host "Build ISO now? (y/n)"
if ($buildNow -eq 'y') {
    Write-Host "`nBuilding ISO... (this will take a while)" -ForegroundColor Green
    wsl -d Debian -e bash -c "cd ~/kirat-build/scripts && sudo bash build-iso.sh --output ~/kirat-os-2.0.0.iso --include-installer"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`n✅ ISO BUILD SUCCESSFUL!" -ForegroundColor Green
    } else {
        Write-Host "`n❌ ISO build failed. Check errors above." -ForegroundColor Red
    }
} else {
    Write-Host "`nSkipped ISO build. To build later, run in WSL2 Debian:" -ForegroundColor Yellow
    Write-Host "  cd ~/kirat-build/scripts && sudo bash build-iso.sh --output ~/kirat-os-2.0.0.iso --include-installer" -ForegroundColor Cyan
}

# =============================================================================
# STEP 6: COPY ISO BACK TO WINDOWS
# =============================================================================
Write-Host "`n[6/7] Checking for built ISO..." -ForegroundColor Green

$isoCheck = wsl -d Debian -e bash -c "ls ~/kirat-os-2.0.0.iso 2>/dev/null"
if ($isoCheck -like "*kirat-os*") {
    Write-Host "ISO found in WSL2. Copying to Windows Desktop..." -ForegroundColor Cyan
    wsl -d Debian -e bash -c "cp ~/kirat-os-2.0.0.iso /mnt/c/Users/`$USER/Desktop/" 2>$null
    
    $desktopIso = "$env:USERPROFILE\Desktop\kirat-os-2.0.0.iso"
    if (Test-Path $desktopIso) {
        $isoSize = [math]::Round((Get-Item $desktopIso).Length / 1MB, 2)
        Write-Host "✅ ISO copied to Desktop: $desktopIso ($isoSize MB)" -ForegroundColor Green
    }
} else {
    Write-Host "No ISO found yet. Build it first with Step 5." -ForegroundColor Yellow
}

# =============================================================================
# STEP 7: TEST IN QEMU (OPTIONAL)
# =============================================================================
Write-Host "`n[7/7] Test in QEMU?" -ForegroundColor Green
$testQemu = Read-Host "Launch VM to test ISO? (y/n)"
if ($testQemu -eq 'y') {
    Write-Host "Launching QEMU with 4GB RAM... Close QEMU window when done testing." -ForegroundColor Cyan
    wsl -d Debian -e bash -c "qemu-system-x86_64 -m 4096 -cdrom ~/kirat-os-2.0.0.iso -boot d -vga std -display gtk"
}

# =============================================================================
# DONE
# =============================================================================
Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  KIRAT OS WSL2 Build Setup Complete!" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "`nNext steps:" -ForegroundColor White
Write-Host "1. If ISO is on Desktop, use Rufus (rufus.ie) to write to USB" -ForegroundColor Cyan
Write-Host "2. Boot your new laptop from USB" -ForegroundColor Cyan
Write-Host "3. Select 'Install KIRAT OS' from GRUB menu" -ForegroundColor Cyan
Write-Host "`nTo enter WSL2 Debian anytime:" -ForegroundColor White
Write-Host "   wsl -d Debian" -ForegroundColor Yellow
Write-Host "`nTo build ISO again:" -ForegroundColor White
Write-Host "   cd ~/kirat-build/scripts && sudo bash build-iso.sh" -ForegroundColor Yellow
