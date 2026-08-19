#!/usr/bin/env python3
# =============================================================================
# KIRAT OS — Hardware Compatibility Verifier
# =============================================================================
# Run this BEFORE installing KIRAT OS on bare metal.
# Checks CPU, RAM, disk, network, and UEFI/BIOS compatibility.
#
# Usage (from KIRAT OS Live USB or any Linux):
#   sudo python3 hw-check.py
#
# Usage (from Windows, if Python installed):
#   python hw-check.py
# =============================================================================

import os
import sys
import re
import json
import subprocess
import platform
from datetime import datetime

# =============================================================================
# CONFIGURATION
# =============================================================================

MIN_CPU_CORES = 4
MIN_RAM_GB = 8
MIN_DISK_GB = 50
RECOMMENDED_RAM_GB = 16
RECOMMENDED_DISK_GB = 100

RESULTS = {
    "timestamp": datetime.utcnow().isoformat(),
    "hostname": platform.node(),
    "checks": {},
    "score": 0,
    "max_score": 100,
    "compatible": False,
    "warnings": [],
    "errors": []
}

# =============================================================================
# HELPERS
# =============================================================================

def run_cmd(cmd, shell=False):
    """Run a command and return stdout."""
    try:
        if shell:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
        else:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return result.stdout.strip()
    except Exception as e:
        return ""

def check_pass(name, message, score=5):
    RESULTS["checks"][name] = {"status": "PASS", "message": message, "score": score}
    RESULTS["score"] += score
    print(f"  ✅ {name}: {message}")

def check_warn(name, message, score=0):
    RESULTS["checks"][name] = {"status": "WARN", "message": message, "score": score}
    RESULTS["warnings"].append(message)
    print(f"  ⚠️  {name}: {message}")

def check_fail(name, message):
    RESULTS["checks"][name] = {"status": "FAIL", "message": message, "score": 0}
    RESULTS["errors"].append(message)
    print(f"  ❌ {name}: {message}")

# =============================================================================
# CHECKS
# =============================================================================

def check_cpu():
    print("\n🔍 Checking CPU...")
    
    # Get CPU info
    cpu_info = run_cmd(["cat", "/proc/cpuinfo"])
    if not cpu_info:
        check_fail("CPU", "Cannot read /proc/cpuinfo")
        return
    
    # Count cores
    cores = len(re.findall(r'^processor\s*:', cpu_info, re.MULTILINE))
    
    # Get model name
    model_match = re.search(r'model name\s*:\s*(.+)', cpu_info)
    model = model_match.group(1).strip() if model_match else "Unknown"
    
    # Check architecture
    arch = run_cmd(["uname", "-m"])
    
    print(f"     Model: {model}")
    print(f"     Cores: {cores}")
    print(f"     Architecture: {arch}")
    
    if arch != "x86_64":
        check_fail("CPU Architecture", f"KIRAT OS requires x86_64. Found: {arch}")
        return
    
    if cores < MIN_CPU_CORES:
        check_warn("CPU Cores", f"Only {cores} cores. Recommended: {MIN_CPU_CORES}+")
    else:
        check_pass("CPU Cores", f"{cores} cores — excellent", 15)
    
    # Check for virtualization support (Intel VT-x / AMD-V)
    vmx = "vmx" in cpu_info.lower()
    svm = "svm" in cpu_info.lower()
    if vmx or svm:
        check_pass("Virtualization", "Intel VT-x / AMD-V supported", 10)
    else:
        check_warn("Virtualization", "CPU virtualization not detected. VMs will be slow.")
    
    # Check AES-NI (encryption acceleration)
    if "aes" in cpu_info.lower():
        check_pass("AES-NI", "Hardware AES encryption supported", 5)
    else:
        check_warn("AES-NI", "No hardware AES acceleration. Disk encryption will be slower.")

def check_ram():
    print("\n🔍 Checking RAM...")
    
    mem_info = run_cmd(["cat", "/proc/meminfo"])
    if not mem_info:
        check_fail("RAM", "Cannot read /proc/meminfo")
        return
    
    total_kb_match = re.search(r'MemTotal:\s+(\d+)', mem_info)
    if not total_kb_match:
        check_fail("RAM", "Cannot parse total RAM")
        return
    
    total_kb = int(total_kb_match.group(1))
    total_gb = total_kb / 1024 / 1024
    
    print(f"     Total RAM: {total_gb:.1f} GB")
    
    if total_gb < MIN_RAM_GB:
        check_fail("RAM", f"Only {total_gb:.1f}GB RAM. Minimum required: {MIN_RAM_GB}GB")
    elif total_gb < RECOMMENDED_RAM_GB:
        check_warn("RAM", f"{total_gb:.1f}GB RAM. Recommended: {RECOMMENDED_RAM_GB}GB+ for AI features")
    else:
        check_pass("RAM", f"{total_gb:.1f}GB RAM — excellent for AI workloads", 20)

def check_disk():
    print("\n🔍 Checking Disk...")
    
    # Find available disks
    lsblk = run_cmd(["lsblk", "-d", "-o", "NAME,SIZE,TYPE,MODEL"])
    print(f"     Disks found:")
    
    disks = []
    for line in lsblk.split('\n')[1:]:  # Skip header
        if line.strip():
            parts = line.split()
            if len(parts) >= 2:
                name = parts[0]
                size = parts[1]
                disks.append((name, size))
                print(f"       /dev/{name}: {size}")
    
    if not disks:
        check_fail("Disk", "No disks detected!")
        return
    
    # Check largest disk
    largest_gb = 0
    for name, size in disks:
        # Parse size (e.g., "931.5G" or "500G")
        size_match = re.match(r'([\d.]+)([GMTP])', size)
        if size_match:
            val = float(size_match.group(1))
            unit = size_match.group(2)
            if unit == 'G':
                largest_gb = max(largest_gb, val)
            elif unit == 'T':
                largest_gb = max(largest_gb, val * 1024)
            elif unit == 'M':
                largest_gb = max(largest_gb, val / 1024)
    
    if largest_gb < MIN_DISK_GB:
        check_fail("Disk", f"Largest disk is only {largest_gb:.0f}GB. Minimum: {MIN_DISK_GB}GB")
    elif largest_gb < RECOMMENDED_DISK_GB:
        check_warn("Disk", f"Largest disk: {largest_gb:.0f}GB. Recommended: {RECOMMENDED_DISK_GB}GB+")
    else:
        check_pass("Disk", f"Largest disk: {largest_gb:.0f}GB — plenty of space", 15)
    
    # Check for NVMe (preferred)
    nvme_disks = [d for d in disks if d[0].startswith('nvme')]
    if nvme_disks:
        check_pass("NVMe", f"NVMe SSD detected — excellent I/O performance", 10)
    else:
        check_warn("NVMe", "No NVMe SSD found. SATA is fine but slower.")

def check_network():
    print("\n🔍 Checking Network...")
    
    # Check for ethernet
    ip_link = run_cmd(["ip", "link", "show"])
    has_ethernet = any(iface in ip_link for iface in ['eth0', 'eth1', 'enp', 'eno'])
    has_wifi = any(iface in ip_link for iface in ['wlan', 'wlp'])
    
    # Check internet connectivity
    ping = run_cmd(["ping", "-c", "1", "-W", "3", "deb.debian.org"])
    has_internet = "1 received" in ping or "1 packets received" in ping
    
    if has_ethernet:
        check_pass("Ethernet", "Wired network adapter detected", 10)
    if has_wifi:
        check_pass("WiFi", "Wireless adapter detected", 5)
    
    if not has_ethernet and not has_wifi:
        check_fail("Network", "No network adapters detected!")
    
    if has_internet:
        check_pass("Internet", "Internet connectivity confirmed", 10)
    else:
        check_warn("Internet", "No internet access. ISO build and updates will require offline packages.")

def check_uefi():
    print("\n🔍 Checking UEFI/BIOS...")
    
    # Check if system is UEFI
    if os.path.exists("/sys/firmware/efi"):
        check_pass("UEFI", "System boots in UEFI mode — Secure Boot ready", 15)
        
        # Check Secure Boot status
        efi_vars = run_cmd(["mokutil", "--sb-state"])
        if "SecureBoot enabled" in efi_vars:
            check_pass("Secure Boot", "Secure Boot is currently enabled", 5)
        elif "SecureBoot disabled" in efi_vars:
            check_warn("Secure Boot", "Secure Boot is disabled. Enable after install for maximum security.")
    else:
        check_warn("UEFI", "System appears to be BIOS (legacy) mode. KIRAT OS works but UEFI is recommended.")

def check_tpm():
    print("\n🔍 Checking TPM...")
    
    tpm_version = ""
    
    # Check TPM 2.0
    if os.path.exists("/dev/tpm0") or os.path.exists("/dev/tpmrm0"):
        # Try to get version
        tpm_info = run_cmd(["cat", "/sys/class/tpm/tpm0/tpm_version_major"])
        if tpm_info.strip() == "2":
            check_pass("TPM", "TPM 2.0 detected — LUKS auto-unlock ready", 10)
        else:
            check_warn("TPM", "TPM detected but version unclear. Manual LUKS setup required.")
    else:
        check_warn("TPM", "No TPM detected. LUKS auto-unlock will require passphrase entry on boot.")

def check_gpu():
    print("\n🔍 Checking GPU...")
    
    # Check for NVIDIA
    lspci = run_cmd(["lspci"])
    
    if "NVIDIA" in lspci:
        check_pass("GPU", "NVIDIA GPU detected — Ollama can use CUDA for faster inference", 5)
    elif "AMD" in lspci and "VGA" in lspci:
        check_pass("GPU", "AMD GPU detected", 3)
    elif "Intel" in lspci and ("Graphics" in lspci or "VGA" in lspci):
        check_pass("GPU", "Intel integrated graphics — sufficient for headless server", 3)
    else:
        check_warn("GPU", "No GPU detected. AI inference will use CPU only (slower).")

def check_usb():
    print("\n🔍 Checking USB Boot Capability...")
    
    lsusb = run_cmd(["lsusb"])
    usb_controllers = len(re.findall(r'Host Controller', lsusb))
    
    if usb_controllers > 0:
        check_pass("USB", f"{usb_controllers} USB controller(s) detected — can boot from USB", 5)
    else:
        check_warn("USB", "No USB controllers detected. You may need PXE network boot.")

# =============================================================================
# MAIN
# =============================================================================

def main():
    print("=" * 60)
    print("  KIRAT OS — Hardware Compatibility Verifier")
    print("=" * 60)
    print(f"  Time: {RESULTS['timestamp']}")
    print(f"  Host: {RESULTS['hostname']}")
    print("=" * 60)
    
    check_cpu()
    check_ram()
    check_disk()
    check_network()
    check_uefi()
    check_tpm()
    check_gpu()
    check_usb()
    
    # Calculate final score
    print("\n" + "=" * 60)
    print("  RESULTS")
    print("=" * 60)
    
    print(f"\n  Score: {RESULTS['score']} / {RESULTS['max_score']}")
    
    if RESULTS['score'] >= 80:
        print(f"  🟢 EXCELLENT — This hardware is ideal for KIRAT OS!")
        RESULTS['compatible'] = True
    elif RESULTS['score'] >= 60:
        print(f"  🟡 GOOD — Compatible with minor limitations")
        RESULTS['compatible'] = True
    elif RESULTS['score'] >= 40:
        print(f"  🟠 FAIR — Will work but some features limited")
        RESULTS['compatible'] = True
    else:
        print(f"  🔴 POOR — Not recommended for KIRAT OS")
        RESULTS['compatible'] = False
    
    if RESULTS['warnings']:
        print(f"\n  Warnings ({len(RESULTS['warnings'])}):")
        for w in RESULTS['warnings']:
            print(f"    ⚠️  {w}")
    
    if RESULTS['errors']:
        print(f"\n  Errors ({len(RESULTS['errors'])}):")
        for e in RESULTS['errors']:
            print(f"    ❌ {e}")
    
    # Save report
    report_file = "/tmp/kirat-hw-report.json"
    try:
        with open(report_file, 'w') as f:
            json.dump(RESULTS, f, indent=2)
        print(f"\n  📄 Full report saved: {report_file}")
    except:
        pass
    
    print("\n" + "=" * 60)
    
    return 0 if RESULTS['compatible'] else 1

if __name__ == "__main__":
    sys.exit(main())
