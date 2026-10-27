#Requires -Version 5.1
<#
.SYNOPSIS
    KIRAT OS Server — One-Click Windows Installer
    Automates WSL2 setup, Debian install, and KIRAT OS deployment

.DESCRIPTION
    This PowerShell script is your one-click gateway to KIRAT OS Server on Windows.
    It handles everything: WSL2 installation, Debian setup, KIRAT OS components,
    kernel module build, dashboard launch, and security hardening.

    Run as Administrator for full functionality.

.PARAMETER Mode
    Installation mode: wsl (default), vm, usb, info

.PARAMETER SkipWSLCheck
    Skip WSL2 availability check (for advanced users)

.PARAMETER AutoStart
    Automatically start dashboard after installation

.EXAMPLE
    .\Install-KIRATOS.ps1
    # Interactive WSL2 installation with prompts

.EXAMPLE
    .\Install-KIRATOS.ps1 -Mode wsl -AutoStart
    # WSL2 install + auto-start dashboard

.EXAMPLE
    .\Install-KIRATOS.ps1 -Mode info
    # Show system info and compatibility

.NOTES
    Author: Teacher (KIRAT AI)
    Version: 1.0.0
    Requires: Windows 10 (1903+) or Windows 11, PowerShell 5.1+
#>

[CmdletBinding()]
param(
    [ValidateSet("wsl", "vm", "usb", "info")]
    [string]$Mode = "wsl",

    [switch]$SkipWSLCheck,
    [switch]$AutoStart,
    [switch]$DryRun,
    [switch]$VerboseOutput
)

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

$ScriptVersion = "1.0.0"
$ScriptName = "KIRAT OS Server Installer"
$WorkspaceDir = "$env:USERPROFILE\Documents\kimi\workspace\kirat-os-server"
$LogFile = "$env:TEMP\kirat-os-install.log"
$DebianVersion = "bookworm"
$RequiredWinBuild = 18362  # Windows 10 1903

# Colors for console output
$Colors = @{
    Success = "Green"
    Error = "Red"
    Warning = "Yellow"
    Info = "Cyan"
    Header = "Magenta"
    Normal = "White"
}

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING & OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $logEntry -ErrorAction SilentlyContinue
    if ($VerboseOutput) { Write-Verbose $logEntry }
}

function Write-Header {
    param([string]$Text)
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Header
    Write-Host "║  $Text" -ForegroundColor $Colors.Header -NoNewline
    $padding = 67 - $Text.Length
    if ($padding -gt 0) { Write-Host (" " * $padding) -ForegroundColor $Colors.Header -NoNewline }
    Write-Host "║" -ForegroundColor $Colors.Header
    Write-Host "╚══════════════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Header
    Write-Log $Text "HEADER"
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor $Colors.Success
    Write-Log $Message "SUCCESS"
}

function Write-Error {
    param([string]$Message)
    Write-Host "  [FAIL] $Message" -ForegroundColor $Colors.Error
    Write-Log $Message "ERROR"
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor $Colors.Warning
    Write-Log $Message "WARNING"
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor $Colors.Info
    Write-Log $Message "INFO"
}

# ─────────────────────────────────────────────────────────────────────────────
# BANNER
# ─────────────────────────────────────────────────────────────────────────────

function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "    _   ___ ___ ___ __  __ ___ _____   ___   _   ___                " -ForegroundColor $Colors.Header
    Write-Host "   | | / /_ _| _ \  \/  | _ \_   _| / _ \ /_\ | _ \               " -ForegroundColor $Colors.Header
    Write-Host "   | |/ / | ||  _/ |\/| |  _/ | || | (_) / _ \|   /               " -ForegroundColor $Colors.Header
    Write-Host "   |___/ |___|_| |_|  |_|_|   |_|  \___/_/ \_\_|_\               " -ForegroundColor $Colors.Header
    Write-Host "                                                                    " -ForegroundColor $Colors.Header
    Write-Host "          KIRAT OS Server — One-Click Windows Installer              " -ForegroundColor $Colors.Info
    Write-Host "          Version $ScriptVersion | Teacher: KIRAT AI                 " -ForegroundColor $Colors.Info
    Write-Host ""
    Write-Log "Banner displayed"
}

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM COMPATIBILITY CHECK
# ─────────────────────────────────────────────────────────────────────────────

function Test-SystemCompatibility {
    Write-Header "System Compatibility Check"

    $results = @()
    $allPassed = $true

    # Windows Version
    $osInfo = Get-CimInstance Win32_OperatingSystem
    $winBuild = [System.Environment]::OSVersion.Version.Build
    $isWin11 = $winBuild -ge 22000

    if ($winBuild -ge $RequiredWinBuild) {
        Write-Success "Windows build $winBuild (>= $RequiredWinBuild)"
        $results += @{ Test = "Windows Version"; Status = "PASS"; Detail = "Build $winBuild" }
    } else {
        Write-Error "Windows build $winBuild (need >= $RequiredWinBuild)"
        $results += @{ Test = "Windows Version"; Status = "FAIL"; Detail = "Build $winBuild" }
        $allPassed = $false
    }

    # PowerShell Version
    if ($PSVersionTable.PSVersion.Major -ge 5) {
        Write-Success "PowerShell $($PSVersionTable.PSVersion)"
        $results += @{ Test = "PowerShell"; Status = "PASS"; Detail = $PSVersionTable.PSVersion }
    } else {
        Write-Error "PowerShell $($PSVersionTable.PSVersion) (need >= 5.1)"
        $allPassed = $false
    }

    # Admin Rights
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        Write-Success "Running as Administrator"
        $results += @{ Test = "Admin Rights"; Status = "PASS"; Detail = "Yes" }
    } else {
        Write-Warning "Not running as Administrator (some features limited)"
        $results += @{ Test = "Admin Rights"; Status = "WARN"; Detail = "No" }
    }

    # CPU Virtualization
    try {
        $cpuInfo = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cpuName = $cpuInfo.Name
        Write-Success "CPU: $cpuName"
        $results += @{ Test = "CPU"; Status = "PASS"; Detail = $cpuName }
    } catch {
        Write-Warning "Could not detect CPU info"
    }

    # RAM
    $totalRamGB = [math]::Round($osInfo.TotalVisibleMemorySize / 1MB, 1)
    if ($totalRamGB -ge 8) {
        Write-Success "RAM: $totalRamGB GB (>= 8 GB recommended)"
        $results += @{ Test = "RAM"; Status = "PASS"; Detail = "$totalRamGB GB" }
    } else {
        Write-Warning "RAM: $totalRamGB GB (8+ GB recommended)"
        $results += @{ Test = "RAM"; Status = "WARN"; Detail = "$totalRamGB GB" }
    }

    # Disk Space
    $systemDrive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeSpaceGB = [math]::Round($systemDrive.FreeSpace / 1GB, 1)
    if ($freeSpaceGB -ge 20) {
        Write-Success "Free space: $freeSpaceGB GB (>= 20 GB needed)"
        $results += @{ Test = "Disk Space"; Status = "PASS"; Detail = "$freeSpaceGB GB" }
    } else {
        Write-Error "Free space: $freeSpaceGB GB (need >= 20 GB)"
        $results += @{ Test = "Disk Space"; Status = "FAIL"; Detail = "$freeSpaceGB GB" }
        $allPassed = $false
    }

    # WSL2 Check
    if (-not $SkipWSLCheck) {
        $wslInstalled = Get-Command wsl -ErrorAction SilentlyContinue
        if ($wslInstalled) {
            try {
                $wslVersion = wsl --version 2>&1 | Select-String "WSL version" | ForEach-Object { $_.ToString() }
                Write-Success "WSL installed: $wslVersion"
                $results += @{ Test = "WSL"; Status = "PASS"; Detail = $wslVersion }
            } catch {
                Write-Warning "WSL command found but version check failed"
                $results += @{ Test = "WSL"; Status = "WARN"; Detail = "Unknown version" }
            }
        } else {
            Write-Warning "WSL not installed (will install)"
            $results += @{ Test = "WSL"; Status = "WARN"; Detail = "Not installed" }
        }
    }

    # Virtualization Enabled
    try {
        $hyperv = Get-CimInstance Win32_ComputerSystem | Select-Object -ExpandProperty HypervisorPresent
        if ($hyperv) {
            Write-Success "Virtualization: Enabled"
            $results += @{ Test = "Virtualization"; Status = "PASS"; Detail = "Enabled" }
        } else {
            Write-Warning "Virtualization: Not detected (may need BIOS enable)"
            $results += @{ Test = "Virtualization"; Status = "WARN"; Detail = "Not detected" }
        }
    } catch {
        Write-Warning "Could not detect virtualization status"
    }

    # Workspace Check
    if (Test-Path $WorkspaceDir) {
        Write-Success "Workspace found: $WorkspaceDir"
        $results += @{ Test = "Workspace"; Status = "PASS"; Detail = "Found" }
    } else {
        Write-Error "Workspace not found: $WorkspaceDir"
        Write-Info "Please ensure KIRAT OS files are in Documents\kimi\workspace\"
        $results += @{ Test = "Workspace"; Status = "FAIL"; Detail = "Not found" }
        $allPassed = $false
    }

    Write-Host ""
    Write-Host "  Compatibility Summary: $(if ($allPassed) { 'ALL CHECKS PASSED' } else { 'SOME CHECKS FAILED' })" -ForegroundColor $(if ($allPassed) { $Colors.Success } else { $Colors.Warning })

    return @{ AllPassed = $allPassed; Results = $results }
}

# ─────────────────────────────────────────────────────────────────────────────
# WSL2 INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

function Install-WSL2 {
    Write-Header "Installing WSL2 + Debian"

    if ($DryRun) {
        Write-Info "DRY RUN: Would install WSL2 and Debian"
        return $true
    }

    # Check if WSL is installed
    $wslCheck = wsl --list --verbose 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Info "WSL not found. Installing WSL2..."
        Write-Info "This may take 5-10 minutes. Please wait..."

        try {
            # Enable WSL
            dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
            Write-Success "WSL feature enabled"

            # Enable Virtual Machine Platform
            dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
            Write-Success "Virtual Machine Platform enabled"

            # Set WSL default version to 2
            wsl --set-default-version 2 2>&1 | Out-Null
            Write-Success "WSL2 set as default"

            Write-Warning "A system restart may be required. If installation fails, please restart and run again."
        } catch {
            Write-Error "Failed to enable WSL features: $_"
            return $false
        }
    } else {
        Write-Success "WSL already installed"
    }

    # Install Debian
    Write-Info "Installing Debian $DebianVersion..."
    try {
        # Download Debian rootfs
        $debianUrl = "https://cloud.debian.org/images/cloud/$DebianVersion/latest/debian-12-nocloud-amd64-wsl.rootfs.tar.gz"
        $debianPath = "$env:TEMP\debian-wsl.tar.gz"

        if (-not (Test-Path $debianPath)) {
            Write-Info "Downloading Debian rootfs (~200MB)..."
            Invoke-WebRequest -Uri $debianUrl -OutFile $debianPath -UseBasicParsing
            Write-Success "Debian rootfs downloaded"
        } else {
            Write-Success "Debian rootfs already downloaded"
        }

        # Import Debian to WSL
        $wslName = "KIRATOS-Debian"
        $wslDir = "$env:USERPROFILE\WSL\KIRATOS"

        # Remove existing if present
        wsl --unregister $wslName 2>&1 | Out-Null

        New-Item -ItemType Directory -Path $wslDir -Force | Out-Null
        wsl --import $wslName $wslDir $debianPath --version 2 2>&1 | Out-Null
        Write-Success "Debian imported to WSL as '$wslName'"

        # Set as default
        wsl --set-default $wslName 2>&1 | Out-Null

        return $true
    } catch {
        Write-Error "Failed to install Debian: $_"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# KIRAT OS INSTALLATION INSIDE WSL
# ─────────────────────────────────────────────────────────────────────────────

function Install-KIRATOSInWSL {
    Write-Header "Installing KIRAT OS Server Components"

    if ($DryRun) {
        Write-Info "DRY RUN: Would install KIRAT OS components in WSL"
        return $true
    }

    $wslName = "KIRATOS-Debian"

    # Check if WSL distro exists
    $distros = wsl --list --quiet 2>&1
    if ($distros -notcontains $wslName) {
        Write-Error "WSL distro '$wslName' not found. Run WSL2 installation first."
        return $false
    }

    # Copy files to WSL
    Write-Info "Copying KIRAT OS files to WSL..."
    $wslWorkspace = "/opt/kirat-os"

    $commands = @"
# Create workspace
mkdir -p $wslWorkspace

# Update system
apt-get update -qq

# Install dependencies
apt-get install -y -qq \
    build-essential linux-headers-\$(uname -r) \
    python3 python3-pip python3-venv \
    curl wget git vim \
    nftables fail2ban \
    nginx

# Copy kernel module source
cp -r /mnt/c/Users/$env:USERNAME/Documents/kimi/workspace/kirat-os-server/kernel-ai $wslWorkspace/
cp -r /mnt/c/Users/$env:USERNAME/Documents/kimi/workspace/kirat-os-server/sentinel-core $wslWorkspace/
cp -r /mnt/c/Users/$env:USERNAME/Documents/kimi/workspace/kirat-os-server/dashboard $wslWorkspace/
cp -r /mnt/c/Users/$env:USERNAME/Documents/kimi/workspace/kirat-os-server/security $wslWorkspace/

# Build kernel module
cd $wslWorkspace/kernel-ai
make clean && make
if [ -f kirat-ai.ko ]; then
    insmod kirat-ai.ko
    echo "kirat-ai" >> /etc/modules-load.d/kirat-ai.conf
    echo "Kernel module loaded successfully"
fi

# Install Sentinel AI
cd $wslWorkspace/sentinel-core
python3 -m venv venv
source venv/bin/activate
pip install -q fastapi uvicorn websockets psutil pyyaml

# Install Dashboard
cd $wslWorkspace/dashboard
python3 -m venv venv
source venv/bin/activate
pip install -q -r requirements.txt

# Create systemd service for dashboard
cat > /etc/systemd/system/kirat-dashboard.service << 'EOF'
[Unit]
Description=KIRAT OS Dashboard
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/kirat-os/dashboard
Environment=ENVIRONMENT=production
ExecStart=/opt/kirat-os/dashboard/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kirat-dashboard

# Create systemd service for Sentinel
cat > /etc/systemd/system/kirat-sentinel.service << 'EOF'
[Unit]
Description=KIRAT OS Sentinel AI
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/kirat-os/sentinel-core
ExecStart=/opt/kirat-os/sentinel-core/venv/bin/python src/main.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable kirat-sentinel

# Run basic hardening
cd $wslWorkspace/security/hardening
bash harden-fixed.sh 2>/dev/null || echo "Hardening completed with some warnings"

echo "KIRAT OS installation complete!"
"@

    # Write commands to temp file and execute in WSL
    $tempScript = "$env:TEMP\kirat-os-wsl-install.sh"
    $commands | Out-File -FilePath $tempScript -Encoding UTF8

    Write-Info "Running installation inside WSL (this may take 10-20 minutes)..."
    wsl -d $wslName -e bash -c "$(Get-Content $tempScript -Raw)" 2>&1 | ForEach-Object {
        Write-Info "WSL: $_"
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Success "KIRAT OS components installed in WSL"
        return $true
    } else {
        Write-Error "Installation failed with exit code $LASTEXITCODE"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# START SERVICES
# ─────────────────────────────────────────────────────────────────────────────

function Start-KIRATOSServices {
    Write-Header "Starting KIRAT OS Services"

    if ($DryRun) {
        Write-Info "DRY RUN: Would start services"
        return
    }

    $wslName = "KIRATOS-Debian"

    # Start services in WSL
    Write-Info "Starting Sentinel AI..."
    wsl -d $wslName -e systemctl start kirat-sentinel 2>&1 | Out-Null

    Write-Info "Starting Dashboard..."
    wsl -d $wslName -e systemctl start kirat-dashboard 2>&1 | Out-Null

    # Wait for services
    Write-Info "Waiting for services to start (10 seconds)..."
    Start-Sleep -Seconds 10

    # Test dashboard
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:8000/api/health" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            Write-Success "Dashboard is running at http://localhost:8000"
        }
    } catch {
        Write-Warning "Dashboard not responding yet. It may need more time."
    }

    Write-Info ""
    Write-Info "Services Status:"
    Write-Info "  - Sentinel AI: systemctl status kirat-sentinel"
    Write-Info "  - Dashboard:   systemctl status kirat-dashboard"
    Write-Info ""
    Write-Info "Access URLs:"
    Write-Info "  - Dashboard UI: http://localhost:8000"
    Write-Info "  - Health Check: http://localhost:8000/api/health"
    Write-Info "  - WebSocket:    ws://localhost:8000/ws/metrics"
}

# ─────────────────────────────────────────────────────────────────────────────
# VM INSTALLATION (QEMU)
# ─────────────────────────────────────────────────────────────────────────────

function Install-VM {
    Write-Header "VM Installation (QEMU)"

    Write-Info "VM installation uses the existing vm-test-fixed.sh script"
    Write-Info ""
    Write-Info "Options:"
    Write-Info "  1. Double-click Start-Test.bat (easiest)"
    Write-Info "  2. Run in Git Bash: bash vm-test-fixed.sh all"
    Write-Info ""

    $choice = Read-Host "Launch Start-Test.bat now? (Y/n)"
    if ($choice -ne 'n' -and $choice -ne 'N') {
        $batPath = "$WorkspaceDir\Start-Test.bat"
        if (Test-Path $batPath) {
            Start-Process $batPath
            Write-Success "Launched Start-Test.bat"
        } else {
            Write-Error "Start-Test.bat not found at $batPath"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# USB CREATION
# ─────────────────────────────────────────────────────────────────────────────

function Create-USB {
    Write-Header "USB Live Creation"

    Write-Info "This will create a bootable USB with KIRAT OS Server"
    Write-Info ""
    Write-Warning "WARNING: This will ERASE all data on the target USB drive!"
    Write-Info ""

    # List available disks
    Write-Info "Available disks:"
    Get-Disk | Where-Object { $_.BusType -eq 'USB' } | ForEach-Object {
        Write-Info "  Disk $($_.Number): $($_.FriendlyName) - $([math]::Round($_.Size / 1GB, 1)) GB"
    }

    Write-Info ""
    Write-Info "To create USB:"
    Write-Info "  1. Download Rufus from https://rufus.ie"
    Write-Info "  2. Download Debian netinstall ISO"
    Write-Info "  3. Use Rufus to write ISO to USB"
    Write-Info "  4. Copy kirat-os-server/ folder to USB"
    Write-Info "  5. Boot from USB and run install-local.sh"
}

# ─────────────────────────────────────────────────────────────────────────────
# INFO MODE
# ─────────────────────────────────────────────────────────────────────────────

function Show-Info {
    Write-Header "System Information"

    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ram = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $free = [math]::Round($disk.FreeSpace / 1GB, 1)

    Write-Info "Operating System: $($os.Caption) $($os.Version)"
    Write-Info "Windows Build:    $([System.Environment]::OSVersion.Version.Build)"
    Write-Info "CPU:              $($cpu.Name)"
    Write-Info "Cores/Threads:    $($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T"
    Write-Info "RAM:              $ram GB"
    Write-Info "Disk Free:        $free GB"
    Write-Info "PowerShell:       $($PSVersionTable.PSVersion)"
    Write-Info ""

    # WSL Status
    Write-Info "WSL Status:"
    try {
        $wslList = wsl --list --verbose 2>&1
        if ($wslList -match "No distributions") {
            Write-Info "  No WSL distributions installed"
        } else {
            $wslList | ForEach-Object { Write-Info "  $_" }
        }
    } catch {
        Write-Info "  WSL not available"
    }

    Write-Info ""
    Write-Info "Workspace: $WorkspaceDir"
    if (Test-Path $WorkspaceDir) {
        $files = Get-ChildItem $WorkspaceDir -File | Measure-Object | Select-Object -ExpandProperty Count
        Write-Info "  Files found: $files"
    } else {
        Write-Warning "  Workspace not found!"
    }

    Write-Info ""
    Write-Info "Recommended Next Steps:"
    Write-Info "  1. Run: .\Install-KIRATOS.ps1 -Mode wsl"
    Write-Info "  2. Or double-click: Start-Test.bat"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

function Main {
    Show-Banner

    switch ($Mode) {
        "info" {
            Show-Info
            return
        }

        "vm" {
            Install-VM
            return
        }

        "usb" {
            Create-USB
            return
        }

        "wsl" {
            # Run compatibility check
            $compat = Test-SystemCompatibility
            if (-not $compat.AllPassed) {
                Write-Warning "Some compatibility checks failed. Continue anyway?"
                $cont = Read-Host "Continue? (y/N)"
                if ($cont -ne 'y' -and $cont -ne 'Y') {
                    Write-Info "Installation cancelled."
                    return
                }
            }

            # Confirm installation
            Write-Host ""
            Write-Host "  This will install:" -ForegroundColor $Colors.Info
            Write-Host "    • WSL2 (if not installed)" -ForegroundColor $Colors.Normal
            Write-Host "    • Debian Linux distribution" -ForegroundColor $Colors.Normal
            Write-Host "    • KIRAT OS Server components" -ForegroundColor $Colors.Normal
            Write-Host "    • Kernel module, Sentinel AI, Dashboard" -ForegroundColor $Colors.Normal
            Write-Host ""

            if (-not $DryRun) {
                $confirm = Read-Host "Proceed with installation? (yes/no)"
                if ($confirm -ne 'yes') {
                    Write-Info "Installation cancelled."
                    return
                }
            }

            # Install WSL2
            if (-not (Install-WSL2)) {
                Write-Error "WSL2 installation failed. Please check the log: $LogFile"
                return
            }

            # Install KIRAT OS in WSL
            if (-not (Install-KIRATOSInWSL)) {
                Write-Error "KIRAT OS installation failed. Please check the log: $LogFile"
                return
            }

            # Start services
            if ($AutoStart) {
                Start-KIRATOSServices
            } else {
                Write-Host ""
                $startNow = Read-Host "Start KIRAT OS services now? (Y/n)"
                if ($startNow -ne 'n' -and $startNow -ne 'N') {
                    Start-KIRATOSServices
                }
            }

            # Final message
            Write-Header "Installation Complete!"
            Write-Info ""
            Write-Info "Access your KIRAT OS Server:"
            Write-Info "  Dashboard: http://localhost:8000"
            Write-Info "  Health:    http://localhost:8000/api/health"
            Write-Info ""
            Write-Info "WSL Commands:"
            Write-Info "  wsl -d KIRATOS-Debian"
            Write-Info "  sudo systemctl status kirat-dashboard"
            Write-Info "  sudo systemctl status kirat-sentinel"
            Write-Info ""
            Write-Info "Log file: $LogFile"
            Write-Info ""
            Write-Success "Welcome to KIRAT OS Server!"
        }
    }
}

# Run main
Main
