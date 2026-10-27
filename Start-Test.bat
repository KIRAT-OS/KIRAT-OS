@echo off
chcp 65001 >nul
:: ============================================================================
:: KIRAT OS Server — Windows Launcher
:: Double-click this file to start testing your fixed kernel module safely
:: 
:: What this does:
::   1. Finds Git Bash on your system
::   2. Opens a terminal in the correct directory
::   3. Runs the VM test script with a nice menu
::
:: Requirements:
::   - Git for Windows (Git Bash) installed
::   - 10GB free disk space
::   - QEMU for Windows (optional, script will guide install)
:: ============================================================================

title KIRAT OS Server — VM Test Launcher
color 0A
cls

echo.
echo  ╔══════════════════════════════════════════════════════════════════════╗
echo  ║                                                                      ║
echo  ║   _   ___ ___ ___ __  __ ___ _____   ___   _   ___                  ║
echo  ║  ^| ^| / /_ _^| _ \  \/  ^| _ \_   _^| / _ \ /_\ ^| _ \                 ║
echo  ║  ^| ^|/ / ^| ^|^|  _/ ^|\/^| ^|  _/ ^| ^|^| ^| (_) / _ \^|   /                 ║
echo  ║  ^|___/ ^|___^|_^| ^|_^|  ^|_^|_^|   ^|_^|  \___/_/ \_\_^|_\                 ║
echo  ║                                                                      ║
echo  ║          KIRAT OS Server — VM Test ^& Verification Launcher           ║
echo  ║                                                                      ║
echo  ╚══════════════════════════════════════════════════════════════════════╝
echo.
echo  Teacher: "Let's test your fixed kernel module safely in a VM first."
echo.

:: ────────────────────────────────────────────────────────────────────────────
:: FIND GIT BASH
:: ────────────────────────────────────────────────────────────────────────────

set "GIT_BASH="
set "WORKSPACE=%USERPROFILE%\Documents\kimi\workspace\kirat-os-server"
set "TEST_SCRIPT=%WORKSPACE%\vm-test-fixed.sh"

:: Check common Git Bash locations
if exist "C:\Program Files\Git\bin\bash.exe" (
    set "GIT_BASH=C:\Program Files\Git\bin\bash.exe"
) else if exist "C:\Program Files (x86)\Git\bin\bash.exe" (
    set "GIT_BASH=C:\Program Files (x86)\Git\bin\bash.exe"
) else if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" (
    set "GIT_BASH=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"
) else if exist "%USERPROFILE%\AppData\Local\Programs\Git\bin\bash.exe" (
    set "GIT_BASH=%USERPROFILE%\AppData\Local\Programs\Git\bin\bash.exe"
) else if exist "%USERPROFILE%\scoop\apps\git\current\bin\bash.exe" (
    set "GIT_BASH=%USERPROFILE%\scoop\apps\git\current\bin\bash.exe"
) else (
    :: Try to find bash in PATH
    for %%I in (bash.exe) do set "GIT_BASH=%%~$PATH:I"
)

if not exist "%GIT_BASH%" (
    color 0C
    echo.
    echo  [ERROR] Git Bash not found!
    echo.
    echo  Git for Windows is required. Please install it:
    echo.
    echo  https://git-scm.com/download/win
    echo.
    echo  After installation, run this script again.
    echo.
    pause
    exit /b 1
)

echo  [OK] Git Bash found: %GIT_BASH%
echo.

:: ────────────────────────────────────────────────────────────────────────────
:: CHECK WORKSPACE
:: ────────────────────────────────────────────────────────────────────────────

if not exist "%WORKSPACE%" (
    color 0E
    echo  [WARN] Workspace not found at expected location:
    echo  %WORKSPACE%
    echo.
    echo  Searching for kirat-os-server...
    
    :: Try to find it
    for /f "delims=" %%a in ('dir /s /b "%USERPROFILE%\Documents\kirat-os-server" 2^>nul') do (
        set "WORKSPACE=%%a"
        echo  [OK] Found: %%a
        goto :found_workspace
    )
    
    echo  [ERROR] Could not find kirat-os-server directory.
    echo  Please ensure the workspace is in Documents\kimi\workspace\
    pause
    exit /b 1
)

:found_workspace
set "TEST_SCRIPT=%WORKSPACE%\vm-test-fixed.sh"

if not exist "%TEST_SCRIPT%" (
    color 0C
    echo  [ERROR] Test script not found:
    echo  %TEST_SCRIPT%
    echo.
    echo  Please run the full setup first.
    pause
    exit /b 1
)

echo  [OK] Workspace: %WORKSPACE%
echo  [OK] Test script: %TEST_SCRIPT%
echo.

:: ────────────────────────────────────────────────────────────────────────────
:: CHECK QEMU
:: ────────────────────────────────────────────────────────────────────────────

set "QEMU_FOUND=0"
for %%I in (qemu-system-x86_64.exe) do (
    if not "%%~$PATH:I"=="" set "QEMU_FOUND=1"
)

if %QEMU_FOUND%==0 (
    if exist "C:\Program Files\qemu\qemu-system-x86_64.exe" set "QEMU_FOUND=1"
)
if %QEMU_FOUND%==0 (
    if exist "C:\Program Files (x86)\qemu\qemu-system-x86_64.exe" set "QEMU_FOUND=1"
)

if %QEMU_FOUND%==0 (
    color 0E
    echo  [WARN] QEMU not found!
    echo.
    echo  QEMU is needed to run the VM test. Install options:
    echo.
    echo  1. MSYS2:    pacman -S mingw-w64-x86_64-qemu
    echo  2. Chocolatey: choco install qemu
    echo  3. Manual:    https://www.qemu.org/download/#windows
    echo.
    echo  The test script will still run, but VM tests will fail.
    echo  You can install QEMU and re-run later.
    echo.
    choice /C YN /M "Continue anyway"
    if errorlevel 2 exit /b 0
    echo.
) else (
    echo  [OK] QEMU found
echo.
)

:: ────────────────────────────────────────────────────────────────────────────
:: SHOW MENU
:: ────────────────────────────────────────────────────────────────────────────

:menu
cls
color 0A

echo.
echo  ╔══════════════════════════════════════════════════════════════════════╗
echo  ║                    KIRAT OS Server — Test Menu                        ║
echo  ╠══════════════════════════════════════════════════════════════════════╣
echo  ║                                                                      ║
echo  ║  Your System: Windows 10, Intel i7-10870H, 32GB RAM, 40GB free       ║
echo  ║                                                                      ║
echo  ╠══════════════════════════════════════════════════════════════════════╣
echo  ║  QUICK ACTIONS:                                                     ║
echo  ║                                                                      ║
echo  ║  [1] Run FULL test pipeline (check ^→ create ^→ boot ^→ test)      ║
echo  ║  [2] Run pre-flight checks only                                     ║
echo  ║  [3] Create VM disk only                                            ║
echo  ║  [4] Boot installer ISO (interactive Debian install)                ║
echo  ║  [5] Boot installed system (headless)                               ║
echo  ║  [6] Run security tests only (module must be built)                 ║
echo  ║  [7] Install ^& test dashboard                                      ║
echo  ║  [8] Generate test report                                            ║
echo  ║  [9] SSH into running VM                                            ║
echo  ║  [0] Stop running VM                                                ║
echo  ║                                                                      ║
echo  ╠══════════════════════════════════════════════════════════════════════╣
echo  ║  INFO:                                                               ║
echo  ║  [R] View full security audit report                                ║
echo  ║  [H] Open help / documentation                                      ║
echo  ║  [Q] Quit                                                            ║
echo  ╚══════════════════════════════════════════════════════════════════════╝
echo.

choice /C 1234567890RHQ /N /M "  Select an option: "

if errorlevel 13 goto :quit
if errorlevel 12 goto :help
if errorlevel 11 goto :report
if errorlevel 10 goto :stop_vm
if errorlevel 9 goto :ssh_vm
if errorlevel 8 goto :gen_report
if errorlevel 7 goto :test_dashboard
if errorlevel 6 goto :run_tests
if errorlevel 5 goto :boot_installed
if errorlevel 4 goto :boot_installer
if errorlevel 3 goto :create_disk
if errorlevel 2 goto :run_checks
if errorlevel 1 goto :run_all

goto :menu

:: ────────────────────────────────────────────────────────────────────────────
:: ACTION HANDLERS
:: ────────────────────────────────────────────────────────────────────────────

:run_all
echo.
echo  [LAUNCHING] Full test pipeline...
echo  This will take 30-60 minutes. Grab a coffee! ☕
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh all"
echo.
pause
goto :menu

:run_checks
echo.
echo  [LAUNCHING] Pre-flight checks...
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh check"
echo.
pause
goto :menu

:create_disk
echo.
echo  [LAUNCHING] Create VM disk...
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh create-disk"
echo.
pause
goto :menu

:boot_installer
echo.
echo  [LAUNCHING] Debian installer...
echo  Follow the on-screen instructions to install Debian.
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh install"
echo.
pause
goto :menu

:boot_installed
echo.
echo  [LAUNCHING] Boot installed system...
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh boot"
echo.
pause
goto :menu

:run_tests
echo.
echo  [LAUNCHING] Security tests...
echo  This verifies all 25 bug fixes!
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh test"
echo.
pause
goto :menu

:test_dashboard
echo.
echo  [LAUNCHING] Dashboard installation...
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh dashboard"
echo.
pause
goto :menu

:gen_report
echo.
echo  [LAUNCHING] Generate test report...
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh report"
echo.
pause
goto :menu

:ssh_vm
echo.
echo  [LAUNCHING] SSH connection...
echo  Login: sentinel / Password: (set during install)
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh ssh"
echo.
pause
goto :menu

:stop_vm
echo.
echo  [LAUNCHING] Stop VM...
echo.
"%GIT_BASH%" -lc "cd '%WORKSPACE%' && bash vm-test-fixed.sh stop"
echo.
pause
goto :menu

:report
echo.
if exist "%WORKSPACE%\KIMI_OS_SECURITY_AUDIT_REPORT.md" (
    echo  Opening security audit report...
    start "" "%WORKSPACE%\KIMI_OS_SECURITY_AUDIT_REPORT.md"
) else (
    echo  Report not found. It should be at:
    echo  %WORKSPACE%\KIMI_OS_SECURITY_AUDIT_REPORT.md
)
echo.
pause
goto :menu

:help
echo.
echo  ╔══════════════════════════════════════════════════════════════════════╗
echo  ║                         HELP / DOCUMENTATION                         ║
echo  ╠══════════════════════════════════════════════════════════════════════╣
echo  ║                                                                      ║
echo  ║  WHAT IS QEMU?                                                       ║
echo  ║  ─────────────                                                       ║
echo  ║  QEMU is a free emulator that lets you run a full Linux system       ║
echo  ║  inside a window on Windows — like a virtual computer.               ║
echo  ║  It lets you test your OS without risking your real PC.              ║
echo  ║                                                                      ║
echo  ║  WHY DO I NEED IT?                                                   ║
echo  ║  ─────────────────                                                   ║
echo  ║  Testing a kernel module on real hardware is dangerous.              ║
echo  ║  One bug can crash your PC. QEMU gives you a safe sandbox.           ║
echo  ║                                                                      ║
echo  ║  WHAT IS THIS TESTING?                                               ║
echo  ║  ─────────────────────                                               ║
echo  ║  We found 25 bugs in your KIRAT OS Server code. This script           ║
echo  ║  verifies that ALL fixes work correctly before you install          ║
echo  ║  on real hardware.                                                   ║
echo  ║                                                                      ║
echo  ║  FULL WORKFLOW:                                                      ║
echo  ║  ──────────────                                                      ║
echo  ║  1. Install QEMU (if not already)                                    ║
echo  ║  2. Select [1] Run FULL test pipeline                               ║
echo  ║  3. Follow prompts to install Debian in the VM                       ║
echo  ║  4. The script will automatically test everything                    ║
echo  ║  5. Check the report — all tests should pass                         ║
echo  ║  6. Only THEN install on real hardware                               ║
echo  ║                                                                      ║
echo  ║  FILES CREATED:                                                      ║
echo  ║  ──────────────                                                      ║
echo  ║  • vm-test-fixed.sh        — The test script (runs in Git Bash)      ║
echo  ║  • kirat-ai-fixed.c         — Fixed kernel module                     ║
echo  ║  • build-server-fixed.sh   — Fixed OS build script                   ║
echo  ║  • harden-fixed.sh         — Fixed security hardening                ║
echo  ║  • dashboard/              — Real-time monitoring web app              ║
echo  ║                                                                      ║
echo  ╚══════════════════════════════════════════════════════════════════════╝
echo.
pause
goto :menu

:quit
echo.
echo  Teacher: "Come back when you're ready to test!"
echo.
timeout /t 2 >nul
exit /b 0
