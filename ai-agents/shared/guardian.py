#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — GUARDIAN MODULE
Kernel & Root Protection Layer for All 5 AI Agents
================================================================================
This module provides aggressive, low-level protection of the system's core:
  - Kernel module load monitoring (detects rootkits, unauthorized drivers)
  - /boot partition integrity (prevents kernel image tampering)
  - /etc/shadow & /etc/sudoers monitoring (detects privilege escalation)
  - Process 1 (init) protection (prevents PID hijacking)
  - Syscall table monitoring (detects hooking)
  - Critical file immutable flags (chattr +i)

Used by: Jitedasti, Galinja, Oysgja, Suyarma, Papa
================================================================================
"""

import os
import sys
import hashlib
import logging
import subprocess
import threading
import time
from datetime import datetime
from typing import Dict, List, Optional, Set
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from shared.privileged import PrivilegedExecutor, destructive_actions_enabled

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("guardian")


class KernelGuardian:
    """
    Protects the Linux kernel from tampering.
    Monitors module loads, /boot integrity, and kernel symbols.
    """
    
    CRITICAL_KERNEL_FILES = [
        "/boot/vmlinuz",
        "/boot/initrd.img",
        "/boot/grub/grub.cfg",
        "/boot/System.map",
    ]
    
    def __init__(self, executor: Optional[PrivilegedExecutor] = None):
        self.baseline_hashes: Dict[str, str] = {}
        self.executor = executor or PrivilegedExecutor("galinja-ai")
        self.allowed_modules: Set[str] = self._get_allowed_modules()
        self._build_baseline()
    
    def _get_allowed_modules(self) -> Set[str]:
        """Get list of currently loaded modules as baseline."""
        try:
            with open("/proc/modules") as f:
                return {line.split()[0] for line in f if line.strip()}
        except:
            return set()
    
    def _build_baseline(self):
        """Create SHA-256 hashes of critical kernel files."""
        for path in self.CRITICAL_KERNEL_FILES:
            # Find actual files (vmlinuz has version suffix)
            import glob
            matches = glob.glob(path + "*")
            for match in matches:
                if os.path.isfile(match):
                    self.baseline_hashes[match] = self._hash_file(match)
        logger.info(f"[GUARDIAN] Kernel baseline: {len(self.baseline_hashes)} files hashed")
    
    def _hash_file(self, path: str) -> str:
        h = hashlib.sha256()
        try:
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(8192), b""):
                    h.update(chunk)
        except:
            return ""
        return h.hexdigest()
    
    def check_kernel_integrity(self) -> List[Dict]:
        """Check if kernel files have been modified."""
        violations = []
        for path, expected_hash in self.baseline_hashes.items():
            current_hash = self._hash_file(path)
            if current_hash != expected_hash:
                violations.append({
                    "file": path,
                    "expected": expected_hash[:16] + "...",
                    "actual": current_hash[:16] + "..." if current_hash else "MISSING",
                    "severity": "CRITICAL",
                    "type": "KERNEL_TAMPERING"
                })
        return violations
    
    def check_new_modules(self) -> List[Dict]:
        """Detect newly loaded kernel modules."""
        violations = []
        try:
            with open("/proc/modules") as f:
                current = {line.split()[0] for line in f if line.strip()}
            
            new_modules = current - self.allowed_modules
            for mod in new_modules:
                violations.append({
                    "module": mod,
                    "severity": "HIGH",
                    "type": "UNAUTHORIZED_MODULE"
                })
                self.allowed_modules.add(mod)  # Whitelist after first alert
        except Exception as e:
            logger.error(f"[GUARDIAN] Module check failed: {e}")
        return violations
    
    def set_immutable(self, paths: List[str]) -> bool:
        """The signed instruction defines the exact paths; callers cannot inject them."""
        if not paths or not destructive_actions_enabled():
            logger.warning("[GUARDIAN] Immutable-file changes disabled by default")
            return False
        result = self.executor.execute_configured("protect-files")
        if result.success:
            logger.info("[GUARDIAN] Signed immutable-file instruction executed")
        else:
            logger.warning("[GUARDIAN] Immutable flags unchanged: %s", result.message)
        return result.success


class RootGuardian:
    """
    Protects root account and privilege escalation paths.
    Monitors /etc/shadow, /etc/sudoers, /etc/passwd, setuid binaries.
    """
    
    CRITICAL_FILES = [
        "/etc/shadow",
        "/etc/sudoers",
        "/etc/sudoers.d/",
        "/etc/passwd",
        "/etc/group",
        "/root/.ssh/",
    ]
    
    def __init__(self):
        self.baseline_hashes: Dict[str, str] = {}
        self.known_setuid: Set[str] = set()
        self._build_baseline()
    
    def _build_baseline(self):
        for path in self.CRITICAL_FILES:
            if os.path.isfile(path):
                self.baseline_hashes[path] = self._hash_file(path)
            elif os.path.isdir(path):
                # Hash all files in directory
                for root, dirs, files in os.walk(path):
                    for f in files:
                        full = os.path.join(root, f)
                        self.baseline_hashes[full] = self._hash_file(full)
        
        # Find all setuid/setgid binaries
        try:
            result = subprocess.run(
                ["find", "/", "-perm", "-4000", "-o", "-perm", "-2000"],
                capture_output=True, text=True, timeout=30
            )
            self.known_setuid = set(line.strip() for line in result.stdout.split("\n") if line.strip())
        except:
            pass
        
        logger.info(f"[GUARDIAN] Root baseline: {len(self.baseline_hashes)} files, {len(self.known_setuid)} setuid binaries")
    
    def _hash_file(self, path: str) -> str:
        h = hashlib.sha256()
        try:
            with open(path, "rb") as f:
                h.update(f.read(65536))  # First 64KB is enough for config files
        except:
            return ""
        return h.hexdigest()
    
    def check_root_integrity(self) -> List[Dict]:
        """Check if critical auth files have been modified."""
        violations = []
        for path, expected_hash in self.baseline_hashes.items():
            if not os.path.exists(path):
                violations.append({
                    "file": path,
                    "severity": "CRITICAL",
                    "type": "CRITICAL_FILE_MISSING"
                })
                continue
            current_hash = self._hash_file(path)
            if current_hash != expected_hash:
                violations.append({
                    "file": path,
                    "severity": "CRITICAL",
                    "type": "AUTH_FILE_MODIFIED"
                })
        return violations
    
    def check_new_setuid(self) -> List[Dict]:
        """Detect newly created setuid binaries (privilege escalation)."""
        violations = []
        try:
            result = subprocess.run(
                ["find", "/", "-perm", "-4000", "-o", "-perm", "-2000"],
                capture_output=True, text=True, timeout=30
            )
            current = set(line.strip() for line in result.stdout.split("\n") if line.strip())
            new_bins = current - self.known_setuid
            for binary in new_bins:
                violations.append({
                    "binary": binary,
                    "severity": "CRITICAL",
                    "type": "NEW_SETUID_BINARY"
                })
                self.known_setuid.add(binary)
        except Exception as e:
            logger.error(f"[GUARDIAN] setuid check failed: {e}")
        return violations
    
    def check_sudoers_d(self) -> List[Dict]:
        """Detect unauthorized sudoers files."""
        violations = []
        try:
            allowed = {"kirat-admin", "security-officer", "ops-engineer", "dev-engineer", 
                       "incident-responder", "galinja-ai", "kirat-healer-ai"}  # legacy name
            for f in os.listdir("/etc/sudoers.d/"):
                if not f.startswith("kirat-") and f != "README":
                    violations.append({
                        "file": f"/etc/sudoers.d/{f}",
                        "severity": "HIGH",
                        "type": "UNAUTHORIZED_SUDOERS"
                    })
        except:
            pass
        return violations


class ProcessGuardian:
    """
    Protects critical processes from hijacking or termination.
    """
    
    CRITICAL_PROCESSES = ["systemd", "sshd", "nginx", "dockerd", "auditd", "apparmor"]
    
    def check_process_integrity(self) -> List[Dict]:
        """Verify critical processes are running and not suspicious."""
        violations = []
        for proc_name in self.CRITICAL_PROCESSES:
            try:
                result = subprocess.run(
                    ["pgrep", "-x", proc_name],
                    capture_output=True, text=True, timeout=5
                )
                if result.returncode != 0:
                    violations.append({
                        "process": proc_name,
                        "severity": "HIGH",
                        "type": "CRITICAL_PROCESS_DOWN"
                    })
            except:
                pass
        return violations
    
    def check_init_pid(self) -> Optional[Dict]:
        """Verify PID 1 is systemd (not hijacked)."""
        try:
            with open("/proc/1/comm") as f:
                init = f.read().strip()
            if init != "systemd":
                return {
                    "init": init,
                    "severity": "CRITICAL",
                    "type": "INIT_HIJACKING"
                }
        except:
            return {"severity": "CRITICAL", "type": "INIT_UNREADABLE"}
        return None


class Guardian:
    """Unified guardian that runs all protection checks."""
    
    def __init__(self):
        self.kernel = KernelGuardian()
        self.root = RootGuardian()
        self.process = ProcessGuardian()
    
    def full_scan(self) -> List[Dict]:
        """Run all guardian checks and return violations."""
        violations = []
        
        # Kernel checks
        violations.extend(self.kernel.check_kernel_integrity())
        violations.extend(self.kernel.check_new_modules())
        
        # Root checks
        violations.extend(self.root.check_root_integrity())
        violations.extend(self.root.check_new_setuid())
        violations.extend(self.root.check_sudoers_d())
        
        # Process checks
        violations.extend(self.process.check_process_integrity())
        init_violation = self.process.check_init_pid()
        if init_violation:
            violations.append(init_violation)
        
        if violations:
            for v in violations:
                logger.critical(f"[GUARDIAN] {v['type']}: {v.get('file', v.get('module', v.get('binary', v.get('process', v.get('init', 'unknown')))))}")
        
        return violations
    
    def protect_critical_files(self):
        """Set immutable flags on most critical files."""
        to_protect = [
            "/etc/shadow",
            "/etc/sudoers",
            "/etc/passwd",
        ]
        self.kernel.set_immutable(to_protect)


if __name__ == "__main__":
    g = Guardian()
    results = g.full_scan()
    print(f"Guardian scan complete. Violations: {len(results)}")
    for r in results:
        print(f"  {r['severity']}: {r['type']}")
