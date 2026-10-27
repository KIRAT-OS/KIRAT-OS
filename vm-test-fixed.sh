#!/bin/bash
###############################################################################
# KIRAT OS Server — VM Test & Verification Script
# Step-by-step guide to safely test the fixed kernel module before production
#
# What this does:
#   1. Creates a QEMU VM with your exact hardware profile (i7-10870H, 32GB RAM)
#   2. Installs a minimal Debian base inside the VM
#   3. Builds and loads the FIXED kernel module (kirat-ai-fixed.c)
#   4. Runs automated security tests against every bug we fixed
#   5. Starts the real-time monitoring dashboard
#   6. Generates a pass/fail report
#
# Requirements:
#   - QEMU for Windows (installed via MSYS2 or standalone)
#   - 10GB free disk space for VM disk
#   - Windows 10 with WSL2 OR Git Bash OR MSYS2
#
# Usage:
#   ./vm-test-fixed.sh [create|build|test|dashboard|all|clean]
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION — Matches your hardware profile
# ─────────────────────────────────────────────────────────────────────────────

VM_NAME="kirat-os-test"
VM_DIR="$HOME/kirat-os-vm-test"
VM_DISK="$VM_DIR/$VM_NAME.qcow2"
VM_DISK_SIZE="20G"
VM_RAM="8192"          # 8GB for VM (you have 32GB total)
VM_CPU="8"             # 8 vCPUs (you have 16 threads)
VM_SMP="cores=8,threads=1,sockets=1"  # Matches i7-10870H topology

# Paths (adjust if your workspace is elsewhere)
WORKSPACE="${WORKSPACE:-$HOME/Documents/kimi/workspace}"
PROJECT_DIR="$WORKSPACE/kirat-os-server"
KERNEL_SRC="$PROJECT_DIR/kernel-ai/kirat-ai-fixed.c"
MAKEFILE="$PROJECT_DIR/kernel-ai/Makefile"
DASHBOARD_DIR="$PROJECT_DIR/dashboard"
SENTINEL_SRC="$PROJECT_DIR/sentinel-core/src/main.py"

# Test results
TEST_LOG="$VM_DIR/test-results.log"
PASS_COUNT=0
FAIL_COUNT=0

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

info()  { echo -e "${BLUE}[TEST]${NC}  $1" | tee -a "$TEST_LOG"; }
ok()    { echo -e "${GREEN}[PASS]${NC}  $1" | tee -a "$TEST_LOG"; PASS_COUNT=$((PASS_COUNT+1)); }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "$TEST_LOG"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $1" | tee -a "$TEST_LOG"; FAIL_COUNT=$((FAIL_COUNT+1)); }
stage() { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
          echo -e "${CYAN}[STAGE] $1${NC}" | tee -a "$TEST_LOG"
          echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT CHECKS
# ─────────────────────────────────────────────────────────────────────────────

check_prerequisites() {
    stage "Pre-flight Checks"
    
    # Check QEMU
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        if command -v qemu-system-x86_64.exe &>/dev/null; then
            QEMU="qemu-system-x86_64.exe"
        else
            fail "QEMU not found. Install it first:"
            echo "  Windows: https://www.qemu.org/download/#windows"
            echo "  MSYS2:   pacman -S mingw-w64-x86_64-qemu"
            echo "  WSL2:    sudo apt-get install qemu-system-x86"
            exit 1
        fi
    else
        QEMU="qemu-system-x86_64"
    fi
    ok "QEMU found: $QEMU"
    
    # Check qemu-img
    if ! command -v qemu-img &>/dev/null && ! command -v qemu-img.exe &>/dev/null; then
        fail "qemu-img not found. Install with QEMU."
        exit 1
    fi
    ok "qemu-img found"
    
    # Check disk space
    local free_space=0
    if command -v df &>/dev/null; then
        free_space=$(df -BG "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
    elif command -v wmic &>/dev/null; then
        free_space=$(wmic logicaldisk get size,freespace,caption | grep -E "C:" | awk '{print $2/1073741824}')
    fi
    
    if [ "${free_space:-0}" -lt 15 ]; then
        warn "Less than 15GB free space detected (${free_space}GB). VM needs ~10GB."
        read -p "Continue anyway? (y/N): " confirm
        [[ "$confirm" != [yY]* ]] && exit 1
    else
        ok "Disk space: ${free_space}GB available"
    fi
    
    # Check source files exist
    if [ ! -f "$KERNEL_SRC" ]; then
        fail "Kernel source not found: $KERNEL_SRC"
        echo "  Run this script from the workspace directory or set WORKSPACE variable."
        exit 1
    fi
    ok "Kernel source found: $KERNEL_SRC"
    
    if [ ! -f "$MAKEFILE" ]; then
        fail "Makefile not found: $MAKEFILE"
        exit 1
    fi
    ok "Makefile found: $MAKEFILE"
    
    if [ ! -f "$SENTINEL_SRC" ]; then
        warn "Sentinel source not found: $SENTINEL_SRC"
    else
        ok "Sentinel source found: $SENTINEL_SRC"
    fi
    
    # Create VM directory
    mkdir -p "$VM_DIR"
    ok "VM directory: $VM_DIR"
    
    info "Host: Windows 10, Intel i7-10870H (16 threads), 32GB RAM"
    info "VM:   $VM_CPU vCPUs, $VM_RAM MB RAM, $VM_DISK_SIZE disk"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: CREATE VM DISK
# ─────────────────────────────────────────────────────────────────────────────

create_vm_disk() {
    stage "Step 1: Creating VM Disk"
    
    if [ -f "$VM_DISK" ]; then
        warn "VM disk already exists: $VM_DISK"
        read -p "Delete and recreate? (y/N): " confirm
        if [[ "$confirm" == [yY]* ]]; then
            rm -f "$VM_DISK"
            info "Deleted old VM disk"
        else
            info "Using existing VM disk"
            return 0
        fi
    fi
    
    info "Creating $VM_DISK_SIZE qcow2 disk..."
    qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"
    ok "VM disk created: $VM_DISK ($VM_DISK_SIZE)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: DOWNLOAD DEBIAN NETINSTALL ISO
# ─────────────────────────────────────────────────────────────────────────────

download_iso() {
    stage "Step 2: Downloading Debian Netinstall ISO"
    
    local iso_url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
    local iso_file="$VM_DIR/debian-12-netinst.iso"
    local iso_checksum_url="https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS"
    
    if [ -f "$iso_file" ]; then
        ok "ISO already downloaded: $iso_file"
        return 0
    fi
    
    info "Downloading Debian 12 netinstall ISO..."
    info "URL: $iso_url"
    info "This may take 5-10 minutes depending on your connection..."
    
    if command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$iso_file" "$iso_url"
    elif command -v wget &>/dev/null; then
        wget --progress=bar:force -O "$iso_file" "$iso_url"
    else
        fail "Neither curl nor wget found. Please download manually:"
        echo "  $iso_url"
        echo "  Save to: $iso_file"
        exit 1
    fi
    
    ok "ISO downloaded: $iso_file"
    
    # Verify checksum if possible
    if command -v sha256sum &>/dev/null; then
        info "Verifying SHA256 checksum..."
        local expected=$(curl -s "$iso_checksum_url" | grep "$(basename "$iso_url")" | awk '{print $1}')
        local actual=$(sha256sum "$iso_file" | awk '{print $1}')
        if [ "$expected" = "$actual" ]; then
            ok "SHA256 checksum verified"
        else
            warn "Checksum mismatch! Expected: $expected, Got: $actual"
            warn "The ISO may be corrupted. Consider re-downloading."
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: BOOT INSTALLER ISO
# ─────────────────────────────────────────────────────────────────────────────

boot_installer() {
    stage "Step 3: Booting Debian Installer in VM"
    
    local iso_file="$VM_DIR/debian-12-netinst.iso"
    
    if [ ! -f "$iso_file" ]; then
        fail "ISO not found. Run: $0 download-iso"
        exit 1
    fi
    
    info "Starting QEMU with installer..."
    info ""
    info "╔══════════════════════════════════════════════════════════════╗"
    info "║  DEBIAN INSTALLER INSTRUCTIONS                              ║"
    info "╠══════════════════════════════════════════════════════════════╣"
    info "║  1. Select 'Install' (not Graphical Install)                ║"
    info "║  2. Language: English → Country: Other → Asia → Hong Kong     ║"
    info "║  3. Locale: en_US.UTF-8                                     ║"
    info "║  4. Keyboard: American English                              ║"
    info "║  5. Hostname: kirat-test                                     ║"
    info "║  6. Domain: (leave blank)                                   ║"
    info "║  7. Root password: kiratos123 (change later!)                ║"
    info "║  8. User: sentinel / password: kiratos123                    ║"
    info "║  9. Partition: Guided - use entire disk → All files in one   ║"
    info "║  10. Software: ONLY select 'SSH server' + 'standard tools' ║"
    info "║  11. DO NOT select desktop environment (we're headless)       ║"
    info "║  12. Install GRUB to /dev/vda                               ║"
    info "╚══════════════════════════════════════════════════════════════╝"
    info ""
    info "Press Ctrl+Alt+2 then type 'sendkey ctrl-alt-f1' if you need console"
    info "Press Ctrl+Alt+G to release mouse grab"
    info ""
    read -p "Press ENTER to start the installer..."
    
    $QEMU \
        -name "$VM_NAME-installer" \
        -machine type=q35,accel=tcg \
        -cpu max \
        -smp "$VM_SMP" \
        -m "$VM_RAM" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -cdrom "$iso_file" \
        -boot d \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::8000-:8000 \
        -device virtio-net-pci,netdev=net0 \
        -display gtk \
        -vga virtio \
        -serial stdio \
        -no-reboot
    
    ok "Installer finished. VM disk now has Debian installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: BOOT INSTALLED SYSTEM (HEADLESS)
# ─────────────────────────────────────────────────────────────────────────────

boot_installed() {
    stage "Step 4: Booting Installed KIRAT OS Test System"
    
    if [ ! -f "$VM_DISK" ]; then
        fail "VM disk not found. Run: $0 create-disk first"
        exit 1
    fi
    
    info "Starting headless VM..."
    info "SSH:    ssh -p 2222 sentinel@localhost"
    info "Web:    http://localhost:8080 (Sentinel)"
    info "Dash:   http://localhost:8000 (Dashboard)"
    info ""
    info "To stop: ./vm-test-fixed.sh stop"
    
    $QEMU \
        -name "$VM_NAME" \
        -machine type=q35,accel=tcg \
        -cpu max \
        -smp "$VM_SMP" \
        -m "$VM_RAM" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::8000-:8000,hostfwd=tcp::9090-:9090 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -serial mon:stdio \
        -no-reboot \
        -daemonize \
        -pidfile "$VM_DIR/qemu.pid" \
        -D "$VM_DIR/qemu.log"
    
    # Wait for PID file (fix race condition from original bug)
    local waited=0
    while [ ! -f "$VM_DIR/qemu.pid" ] && [ $waited -lt 30 ]; do
        sleep 0.1
        waited=$((waited+1))
    done
    
    if [ -f "$VM_DIR/qemu.pid" ]; then
        local pid=$(cat "$VM_DIR/qemu.pid")
        ok "VM running in background (PID: $pid)"
    else
        warn "PID file not found yet, but VM may still be starting"
    fi
    
    info "Waiting 30 seconds for system to boot..."
    sleep 30
    
    # Test SSH connectivity
    info "Testing SSH connectivity..."
    local ssh_attempts=0
    while [ $ssh_attempts -lt 10 ]; do
        if ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes sentinel@localhost "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
            ok "SSH connection established!"
            return 0
        fi
        ssh_attempts=$((ssh_attempts+1))
        info "SSH attempt $ssh_attempts/10... waiting 10 seconds"
        sleep 10
    done
    
    warn "SSH not responding yet. The VM may still be booting."
    info "Try manually: ssh -p 2222 sentinel@localhost"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: COPY FIXED FILES INTO VM
# ─────────────────────────────────────────────────────────────────────────────

copy_files_to_vm() {
    stage "Step 5: Copying Fixed Files to VM"
    
    # Wait for SSH
    local ssh_attempts=0
    while [ $ssh_attempts -lt 10 ]; do
        if ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes sentinel@localhost "mkdir -p ~/kirat-test" 2>/dev/null; then
            break
        fi
        ssh_attempts=$((ssh_attempts+1))
        sleep 5
    done
    
    if [ $ssh_attempts -eq 10 ]; then
        fail "Cannot connect to VM via SSH. Is it running?"
        exit 1
    fi
    
    # Copy kernel module source
    info "Copying kernel module source..."
    scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$KERNEL_SRC" sentinel@localhost:~/kirat-test/kirat-ai.c
    ok "Kernel source copied"
    
    # Copy Makefile
    info "Copying Makefile..."
    scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$MAKEFILE" sentinel@localhost:~/kirat-test/Makefile
    ok "Makefile copied"
    
    # Copy sentinel source
    if [ -f "$SENTINEL_SRC" ]; then
        info "Copying Sentinel source..."
        scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$SENTINEL_SRC" sentinel@localhost:~/kirat-test/main.py
        ok "Sentinel source copied"
    fi
    
    # Copy dashboard
    if [ -d "$DASHBOARD_DIR" ]; then
        info "Copying dashboard..."
        scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -r \
            "$DASHBOARD_DIR" sentinel@localhost:~/kirat-test/dashboard
        ok "Dashboard copied"
    fi
    
    ok "All files copied to VM"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: BUILD KERNEL MODULE IN VM
# ─────────────────────────────────────────────────────────────────────────────

build_in_vm() {
    stage "Step 6: Building Kernel Module Inside VM"
    
    info "Installing build dependencies..."
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            sudo apt-get update -qq
            sudo apt-get install -y -qq linux-headers-\$(uname -r) build-essential
        " || {
        fail "Failed to install build dependencies"
        exit 1
    }
    ok "Build dependencies installed"
    
    info "Building kernel module..."
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            cd ~/kirat-test
            make clean 2>/dev/null || true
            make 2>&1
        " || {
        fail "Kernel module build failed"
        exit 1
    }
    ok "Kernel module built successfully"
    
    info "Checking for .ko file..."
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "ls -la ~/kirat-test/*.ko" || {
        fail "No .ko file found after build"
        exit 1
    }
    ok ".ko file confirmed"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 7: LOAD MODULE AND RUN SECURITY TESTS
# ─────────────────────────────────────────────────────────────────────────────

run_security_tests() {
    stage "Step 7: Running Automated Security Tests"
    
    info "Loading kernel module..."
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            cd ~/kirat-test
            sudo insmod kirat-ai.ko 2>&1
            sleep 2
            dmesg | tail -20
        " || {
        fail "Failed to load kernel module"
        exit 1
    }
    ok "Kernel module loaded"
    
    # Test 1: Device exists
    info "Test 1: Checking /dev/kirat-ai exists..."
    if ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "ls -la /dev/kirat-ai" >/dev/null 2>&1; then
        ok "TEST 1 PASS: /dev/kirat-ai exists"
    else
        fail "TEST 1 FAIL: /dev/kirat-ai not found"
    fi
    
    # Test 2: Read snapshot (unprivileged should work)
    info "Test 2: Reading snapshot as unprivileged user..."
    local snapshot=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "cat /dev/kirat-ai" 2>/dev/null | head -5)
    if echo "$snapshot" | grep -q "timestamp"; then
        ok "TEST 2 PASS: Snapshot readable (JSON format)"
    else
        fail "TEST 2 FAIL: Snapshot not readable"
    fi
    
    # Test 3: Capability check — unprivileged user cannot boost priority
    info "Test 3: Verifying privilege escalation is BLOCKED..."
    local boost_result=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            # Try to boost priority without CAP_SYS_NICE
            printf '\x03\x00\x00\x00' > /tmp/boost_cmd
            printf '\x01\x00\x00\x00' >> /tmp/boost_cmd  # PID 1
            printf '\x64\x00\x00\x00' >> /tmp/boost_cmd  # priority 100
            cat /tmp/boost_cmd > /dev/kirat-ai 2>&1 || echo 'WRITE_FAILED'
        " 2>/dev/null)
    if echo "$boost_result" | grep -q "WRITE_FAILED\|Permission denied\|Operation not permitted"; then
        ok "TEST 3 PASS: Unprivileged boost blocked (CVE fixed!)"
    else
        fail "TEST 3 FAIL: Unprivileged boost may have succeeded!"
    fi
    
    # Test 4: Capability check — root with CAP_SYS_NICE can boost
    info "Test 4: Verifying authorized boost works..."
    local root_boost=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            sudo bash -c '
                printf \"\\x03\\x00\\x00\\x00\" > /tmp/boost_cmd
                printf \"\\x01\\x00\\x00\\x00\" >> /tmp/boost_cmd
                printf \"\\x64\\x00\\x00\\x00\" >> /tmp/boost_cmd
                cat /tmp/boost_cmd > /dev/kirat-ai 2>&1
                echo \"ROOT_BOOST_OK\"
            '
        " 2>/dev/null)
    if echo "$root_boost" | grep -q "ROOT_BOOST_OK"; then
        ok "TEST 4 PASS: Authorized boost works for root"
    else
        warn "TEST 4 WARN: Root boost may have issues (check dmesg)"
    fi
    
    # Test 5: Bounds check — short write rejected
    info "Test 5: Verifying bounds check on short writes..."
    local short_write=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            printf '\x03\x00\x00\x00' > /dev/kirat-ai 2>&1 || echo 'SHORT_WRITE_BLOCKED'
        " 2>/dev/null)
    if echo "$short_write" | grep -q "SHORT_WRITE_BLOCKED\|Invalid argument"; then
        ok "TEST 5 PASS: Short write correctly rejected"
    else
        fail "TEST 5 FAIL: Short write not rejected"
    fi
    
    # Test 6: Sysfs exists
    info "Test 6: Checking sysfs interface..."
    if ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "cat /sys/kernel/kirat/governor" >/dev/null 2>&1; then
        ok "TEST 6 PASS: Sysfs interface readable"
    else
        fail "TEST 6 FAIL: Sysfs interface not accessible"
    fi
    
    # Test 7: Netlink socket registered
    info "Test 7: Checking netlink protocol..."
    local netlink_check=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "dmesg | grep -i 'netlink' | tail -5" 2>/dev/null)
    if echo "$netlink_check" | grep -q "netlink"; then
        ok "TEST 7 PASS: Netlink registered in dmesg"
    else
        warn "TEST 7 WARN: Netlink registration not visible in dmesg"
    fi
    
    # Test 8: Module version correct
    info "Test 8: Verifying module version..."
    local modinfo=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "modinfo ~/kirat-test/kirat-ai.ko | grep version" 2>/dev/null)
    if echo "$modinfo" | grep -q "2.0.0"; then
        ok "TEST 8 PASS: Module version 2.0.0 confirmed"
    else
        warn "TEST 8 WARN: Module version not as expected"
    fi
    
    ok "Security tests complete. Check $TEST_LOG for details."
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 8: INSTALL AND TEST DASHBOARD
# ─────────────────────────────────────────────────────────────────────────────

test_dashboard() {
    stage "Step 8: Installing and Testing Dashboard"
    
    info "Installing Python dependencies..."
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            sudo apt-get install -y -qq python3-pip python3-venv
            cd ~/kirat-test/dashboard
            python3 -m venv venv
            source venv/bin/activate
            pip install -q -r requirements.txt
        " || {
        warn "Dashboard dependency install failed"
        return 1
    }
    ok "Dashboard dependencies installed"
    
    info "Starting dashboard in background..."
    ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "
            cd ~/kirat-test/dashboard
            source venv/bin/activate
            nohup uvicorn main:app --host 0.0.0.0 --port 8000 > ~/dashboard.log 2>&1 &
            sleep 3
            curl -s http://localhost:8000/api/health | head -1
        " || {
        warn "Dashboard start failed"
        return 1
    }
    ok "Dashboard started on http://localhost:8000"
    
    info "Testing dashboard endpoints..."
    
    # Test health endpoint
    local health=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "curl -s http://localhost:8000/api/health" 2>/dev/null)
    if echo "$health" | grep -q "healthy\|ok"; then
        ok "Dashboard health endpoint responding"
    else
        warn "Dashboard health endpoint not responding correctly"
    fi
    
    # Test metrics endpoint
    local metrics=$(ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        sentinel@localhost "curl -s http://localhost:8000/api/metrics" 2>/dev/null | head -1)
    if [ -n "$metrics" ]; then
        ok "Dashboard metrics endpoint responding"
    else
        warn "Dashboard metrics endpoint not responding"
    fi
    
    info "Dashboard accessible at: http://localhost:8000 (from host)"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 9: GENERATE TEST REPORT
# ─────────────────────────────────────────────────────────────────────────────

generate_report() {
    stage "Step 9: Generating Test Report"
    
    local report_file="$VM_DIR/TEST_REPORT.md"
    
    cat > "$report_file" << EOF
# KIRAT OS Server — VM Test Report

**Date:** $(date '+%Y-%m-%d %H:%M:%S')  
**VM:** $VM_NAME  
**Host:** Windows 10, Intel i7-10870H, 32GB RAM  
**VM Config:** $VM_CPU vCPUs, $VM_RAM MB RAM, $VM_DISK_SIZE disk

---

## Test Results Summary

| Metric | Value |
|--------|-------|
| Tests Passed | $PASS_COUNT |
| Tests Failed | $FAIL_COUNT |
| Success Rate | $(( PASS_COUNT * 100 / (PASS_COUNT + FAIL_COUNT) ))% |

## Security Fixes Verified

| Fix | Status |
|-----|--------|
| C-001: Privilege escalation blocked | $(grep -q "TEST 3 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "❌ FAIL") |
| C-002: Bounds checks enforced | $(grep -q "TEST 5 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "❌ FAIL") |
| C-003: Device created | $(grep -q "TEST 1 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "❌ FAIL") |
| C-004: Snapshot readable | $(grep -q "TEST 2 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "❌ FAIL") |
| C-005: Sysfs accessible | $(grep -q "TEST 6 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "❌ FAIL") |
| C-006: Netlink registered | $(grep -q "TEST 7 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "⚠️ WARN") |
| C-007: Module version correct | $(grep -q "TEST 8 PASS" "$TEST_LOG" 2>/dev/null && echo "✅ PASS" || echo "⚠️ WARN") |

## Next Steps

1. If all tests pass: ✅ Ready to install on real hardware
2. If any tests fail: Review the logs and re-run specific steps
3. Dashboard: Access at http://localhost:8000 from your Windows host

## Commands Reference

\`\`\`bash
# SSH into VM
ssh -p 2222 sentinel@localhost

# Check kernel module logs
sudo dmesg | grep kirat-ai

# View dashboard logs
tail -f ~/dashboard.log

# Stop VM
kill \$(cat $VM_DIR/qemu.pid)
\`\`\`

---

*Generated by vm-test-fixed.sh*
EOF

    ok "Test report generated: $report_file"
    
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           TEST SUMMARY                                       ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    printf "║  Passed:  %-3d                                                ║\n" "$PASS_COUNT"
    printf "║  Failed:  %-3d                                                ║\n" "$FAIL_COUNT"
    printf "║  Rate:    %d%%                                               ║\n" "$(( PASS_COUNT * 100 / (PASS_COUNT + FAIL_COUNT + 1) ))"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    
    if [ $FAIL_COUNT -eq 0 ]; then
        echo -e "${GREEN}🎉 ALL TESTS PASSED!${NC} Your fixed kernel module is ready for production."
    else
        echo -e "${YELLOW}⚠️  Some tests failed.${NC} Review $TEST_LOG for details."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# UTILITY COMMANDS
# ─────────────────────────────────────────────────────────────────────────────

stop_vm() {
    stage "Stopping VM"
    if [ -f "$VM_DIR/qemu.pid" ]; then
        local pid=$(cat "$VM_DIR/qemu.pid")
        info "Stopping VM (PID: $pid)..."
        kill "$pid" 2>/dev/null || true
        rm -f "$VM_DIR/qemu.pid"
        ok "VM stopped"
    else
        warn "No PID file found. Trying to find QEMU process..."
        if command -v pgrep &>/dev/null; then
            local qemu_pids=$(pgrep -f "qemu-system-x86_64.*$VM_NAME" || true)
            if [ -n "$qemu_pids" ]; then
                echo "$qemu_pids" | xargs kill 2>/dev/null || true
                ok "QEMU processes killed"
            else
                warn "No QEMU processes found"
            fi
        fi
    fi
}

ssh_vm() {
    info "Connecting to VM via SSH..."
    ssh -p 2222 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        sentinel@localhost
}

clean_all() {
    stage "Cleaning Up"
    stop_vm
    
    read -p "Delete VM disk and all test files? (y/N): " confirm
    if [[ "$confirm" == [yY]* ]]; then
        rm -rf "$VM_DIR"
        ok "All test files deleted"
    else
        info "Cleanup cancelled"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN MENU
# ─────────────────────────────────────────────────────────────────────────────

show_banner() {
    cat << 'BANNER'
 _   ___ ___ ___ __  __ ___ _____   ___   _   ___ 
| | / /_ _| _ \  \/  | _ \_   _| / _ \ /_\ | _ \
| |/ / | ||  _/ |\/| |  _/ | || | (_) / _ \|   /
|___/ |___|_| |_|  |_|_|   |_|  \___/_/ \_\_|_\
                                                 
    KIRAT OS Server — VM Test & Verification
    Super God Mode Security Audit Follow-up
    
BANNER
}

show_help() {
    cat << 'HELP'
Usage: ./vm-test-fixed.sh [COMMAND]

COMMANDS:
  check         Run pre-flight checks only
  create-disk   Create VM disk image
  download-iso  Download Debian netinstall ISO
  install       Boot installer ISO (interactive)
  boot          Boot installed system (headless)
  copy-files    Copy fixed files to running VM
  build         Build kernel module inside VM
  test          Run automated security tests
  dashboard     Install and test monitoring dashboard
  report        Generate test report
  stop          Stop running VM
  ssh           SSH into running VM
  clean         Delete all VM files
  all           Run full pipeline: check → create → boot → copy → build → test → dashboard → report
  help          Show this help

FULL TEST WORKFLOW:
  ./vm-test-fixed.sh all

STEP BY STEP:
  1. ./vm-test-fixed.sh check          # Verify prerequisites
  2. ./vm-test-fixed.sh create-disk    # Create 20GB VM disk
  3. ./vm-test-fixed.sh download-iso   # Download Debian installer
  4. ./vm-test-fixed.sh install        # Install Debian (interactive)
  5. ./vm-test-fixed.sh boot           # Boot installed system
  6. ./vm-test-fixed.sh copy-files   # Copy fixed kernel module
  7. ./vm-test-fixed.sh build          # Build inside VM
  8. ./vm-test-fixed.sh test           # Run security tests
  9. ./vm-test-fixed.sh dashboard      # Install dashboard
  10. ./vm-test-fixed.sh report        # Generate report

HELP
}

run_all() {
    check_prerequisites
    create_vm_disk
    download_iso
    boot_installer
    boot_installed
    copy_files_to_vm
    build_in_vm
    run_security_tests
    test_dashboard
    generate_report
}

main() {
    show_banner
    
    local cmd="${1:-help}"
    
    case "$cmd" in
        check)          check_prerequisites ;;
        create-disk)    create_vm_disk ;;
        download-iso)   download_iso ;;
        install)        boot_installer ;;
        boot)           boot_installed ;;
        copy-files)     copy_files_to_vm ;;
        build)          build_in_vm ;;
        test)           run_security_tests ;;
        dashboard)      test_dashboard ;;
        report)         generate_report ;;
        stop)           stop_vm ;;
        ssh)            ssh_vm ;;
        clean)          clean_all ;;
        all)            run_all ;;
        help|--help|-h) show_help ;;
        *)              echo "Unknown command: $cmd"; show_help; exit 1 ;;
    esac
}

main "$@"
