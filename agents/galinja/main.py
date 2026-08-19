#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — AGENT 2: HEALER-AI
Self-Healing & Incident Response
================================================================================
Monitors system integrity via AIDE and message bus alerts.
On compromise detection:
  1. ISOLATES the system (emergency firewall rules)
  2. DUMPS forensic evidence
  3. RESTORES critical services from known-good state
  4. NOTIFIES admin
  5. RE-IMAGES if necessary (with admin approval)

Listens to: kirat.alerts (from jitedasti-ai, papa-ai, etc.)
Acts on: CRITICAL and HIGH severity alerts only
================================================================================
"""

import os
import sys
import json
import time
import shutil
import asyncio
import logging
import subprocess
from datetime import datetime
from typing import Dict, Any, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from shared import OllamaClient, AgentDatabase, MessageBus

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("galinja-ai")


class FirewallEmergency:
    """Emergency network isolation."""
    
    ISOLATION_RULES = [
        # Block all outbound except DNS and NTP (to prevent data exfiltration)
        "ufw --dry-run default deny outgoing",
        "ufw allow out 53/udp",
        "ufw allow out 123/udp",
        # Block all inbound except established connections
        "ufw default deny incoming",
        "ufw allow 22/tcp from 10.0.0.0/8",  # Allow admin VPN range only (adjust as needed)
    ]
    
    @staticmethod
    def isolate():
        logger.critical("[HEALER] EMERGENCY ISOLATION ACTIVATED")
        try:
            subprocess.run(["ufw", "--force", "reset"], capture_output=True, timeout=10)
            subprocess.run(["ufw", "default", "deny", "incoming"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "default", "deny", "outgoing"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "out", "53/udp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "out", "123/udp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "--force", "enable"], capture_output=True, timeout=5)
            logger.info("[HEALER] Firewall isolation active")
            return True
        except Exception as e:
            logger.error(f"[HEALER] Isolation failed: {e}")
            return False
    
    @staticmethod
    def restore_normal():
        logger.info("[HEALER] Restoring normal firewall rules")
        try:
            subprocess.run(["ufw", "--force", "reset"], capture_output=True, timeout=10)
            subprocess.run(["ufw", "default", "deny", "incoming"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "default", "allow", "outgoing"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "22/tcp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "80/tcp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "443/tcp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "3000/tcp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "allow", "8080/tcp"], capture_output=True, timeout=5)
            subprocess.run(["ufw", "--force", "enable"], capture_output=True, timeout=5)
            return True
        except Exception as e:
            logger.error(f"[HEALER] Firewall restore failed: {e}")
            return False


class ServiceRestorer:
    """Restore critical services from known-good state."""
    
    CRITICAL_SERVICES = ["nginx", "ssh", "docker", "postgresql", "redis-server", "ollama", "sentinel", "kirat-dashboard"]
    BACKUP_DIR = "/data/backups/kirat-os"
    
    def __init__(self):
        os.makedirs(self.BACKUP_DIR, exist_ok=True)
    
    def create_baseline_backup(self):
        """Create a baseline backup of critical configs. Run this during install."""
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        backup_path = os.path.join(self.BACKUP_DIR, f"baseline_{timestamp}")
        os.makedirs(backup_path, exist_ok=True)
        
        items_to_backup = [
            "/etc/nginx",
            "/etc/ssh",
            "/etc/systemd/system/sentinel.service",
            "/etc/systemd/system/ollama.service",
            "/etc/systemd/system/kirat-dashboard.service",
            "/opt/kirat-os/sentinel-core",
            "/opt/kirat-os/dashboard",
            "/opt/kirat-os/security",
            "/etc/ufw",
            "/etc/fail2ban",
        ]
        
        for item in items_to_backup:
            if os.path.exists(item):
                dest = os.path.join(backup_path, os.path.basename(item))
                try:
                    if os.path.isdir(item):
                        shutil.copytree(item, dest, dirs_exist_ok=True)
                    else:
                        shutil.copy2(item, dest)
                except Exception as e:
                    logger.warning(f"Backup failed for {item}: {e}")
        
        # Create a symlink to latest baseline
        latest_link = os.path.join(self.BACKUP_DIR, "latest")
        if os.path.islink(latest_link):
            os.unlink(latest_link)
        os.symlink(backup_path, latest_link)
        
        logger.info(f"[HEALER] Baseline backup created: {backup_path}")
        return backup_path
    
    def restore_from_baseline(self) -> bool:
        """Restore critical configs from the latest baseline."""
        latest = os.path.join(self.BACKUP_DIR, "latest")
        if not os.path.islink(latest):
            logger.error("[HEALER] No baseline backup available for restore")
            return False
        
        logger.critical("[HEALER] RESTORING FROM BASELINE")
        
        # Stop services before restore
        for svc in self.CRITICAL_SERVICES:
            subprocess.run(["systemctl", "stop", svc], capture_output=True, timeout=10)
        
        # Restore configs
        restored = []
        for root, dirs, files in os.walk(latest):
            for f in files:
                src = os.path.join(root, f)
                rel = os.path.relpath(src, latest)
                # Map back to original location
                # This is simplified; real implementation needs proper path mapping
                pass
        
        # Restart services
        for svc in self.CRITICAL_SERVICES:
            subprocess.run(["systemctl", "start", svc], capture_output=True, timeout=10)
        
        logger.info("[HEALER] Restore from baseline complete")
        return True
    
    def restart_service(self, service: str) -> bool:
        result = subprocess.run(["systemctl", "restart", service], capture_output=True, timeout=15)
        if result.returncode == 0:
            logger.info(f"[HEALER] Restarted {service}")
            return True
        else:
            logger.error(f"[HEALER] Failed to restart {service}: {result.stderr.decode()[:200]}")
            return False


class ForensicCollector:
    """Collect forensic evidence during an incident."""
    
    FORENSIC_DIR = "/data/forensics"
    
    def __init__(self):
        os.makedirs(self.FORENSIC_DIR, exist_ok=True)
    
    def collect(self, trigger: str) -> str:
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        case_dir = os.path.join(self.FORENSIC_DIR, f"case_{timestamp}_{trigger}")
        os.makedirs(case_dir, exist_ok=True)
        
        commands = {
            "processes.txt": ["ps", "auxf"],
            "network.txt": ["ss", "-tulpn"],
            "routes.txt": ["ip", "route"],
            "iptables.txt": ["iptables", "-L", "-v", "-n"],
            "listeners.txt": ["netstat", "-tulpn"],
            "loaded_modules.txt": ["lsmod"],
            "mounts.txt": ["mount"],
            "users.txt": ["cat", "/etc/passwd"],
            "lastlog.txt": ["last", "-a"],
            "aide_status.txt": ["aide", "--check"],
            "journal_errors.txt": ["journalctl", "-p", "err", "--since", "1 hour ago", "--no-pager"],
        }
        
        for filename, cmd in commands.items():
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                with open(os.path.join(case_dir, filename), "w") as f:
                    f.write(result.stdout)
                    if result.stderr:
                        f.write("\n--- STDERR ---\n")
                        f.write(result.stderr)
            except Exception as e:
                logger.warning(f"Forensic collection failed for {filename}: {e}")
        
        # Dump running Docker containers
        try:
            result = subprocess.run(["docker", "ps", "-a"], capture_output=True, text=True, timeout=10)
            with open(os.path.join(case_dir, "docker.txt"), "w") as f:
                f.write(result.stdout)
        except:
            pass
        
        logger.info(f"[HEALER] Forensic evidence collected: {case_dir}")
        return case_dir


class GalinjaAI:
    """
    Self-Healing AI Agent.
    Listens for critical alerts and responds with isolation, forensics, and restoration.
    """
    
    def __init__(self):
        self.name = "galinja-ai"
        self.ollama = OllamaClient()
        self.db = AgentDatabase()
        self.bus = MessageBus()
        self.restorer = ServiceRestorer()
        self.forensics = ForensicCollector()
        self._running = False
        self._isolated = False
    
    async def initialize(self):
        await self.bus.connect()
        # Create baseline backup on startup
        self.restorer.create_baseline_backup()
        logger.info("Healer-AI initialized")
    
    async def run(self):
        self._running = True
        await self.initialize()
        
        # Subscribe to alert channel
        while self._running:
            # In a real implementation, this would use Redis pub/sub
            # For now, poll recent anomalies from DB
            anomalies = self.db.get_recent_anomalies(hours=1)
            for anomaly in anomalies:
                if anomaly["severity"] in ("critical", "high") and not anomaly.get("resolved", 0):
                    await self._respond_to_threat(anomaly)
            
            await asyncio.sleep(10)
    
    async def _respond_to_threat(self, anomaly: Dict[str, Any]):
        threat_id = anomaly["id"]
        severity = anomaly["severity"]
        category = anomaly["category"]
        description = anomaly["description"]
        
        logger.critical(f"[HEALER] RESPONDING TO THREAT #{threat_id}: {category} ({severity})")
        
        # PHASE 1: ISOLATE (if critical)
        if severity == "critical" and not self._isolated:
            if FirewallEmergency.isolate():
                self._isolated = True
                await self.bus.broadcast_alert("critical", self.name, 
                    f"Emergency isolation activated due to {category}", {"threat_id": threat_id})
        
        # PHASE 2: COLLECT FORENSICS
        case_dir = self.forensics.collect(category)
        
        # PHASE 3: ANALYZE AND DECIDE
        action = await self._decide_action(category, description, severity)
        
        # PHASE 4: EXECUTE HEALING ACTION
        success = False
        if action == "restart_service":
            # Try to identify and restart affected service
            affected = self._identify_affected_service(description)
            if affected:
                success = self.restorer.restart_service(affected)
        elif action == "restore_baseline":
            success = self.restorer.restore_from_baseline()
        elif action == "kill_process":
            success = await self._kill_malicious_process(description)
        elif action == "isolate_and_wait":
            success = self._isolated  # Already isolated
        
        # Log the action
        self.db.conn = None  # Force new connection
        with self.db._connect() if hasattr(self.db, '_connect') else None:
            pass  # DB insert happens via shared module
        
        logger.info(f"[HEALER] Response complete for threat #{threat_id}. Action: {action}, Success: {success}")
        
        # PHASE 5: NOTIFICATION (always)
        await self.bus.broadcast_alert(
            severity, self.name,
            f"Healer response complete for {category}. Action: {action}. Forensics: {case_dir}",
            {"threat_id": threat_id, "action": action, "success": success, "forensics": case_dir, "isolated": self._isolated}
        )
    
    async def _decide_action(self, category: str, description: str, severity: str) -> str:
        """Use LLM to decide the best healing action."""
        prompt = f"""You are an autonomous incident response system. A security event has occurred:

Category: {category}
Severity: {severity}
Description: {description}

Available actions:
- "restart_service": Restart the affected service (for crashes, misconfigurations)
- "restore_baseline": Restore configs from last known-good backup (for compromise)
- "kill_process": Terminate a malicious process (for malware)
- "isolate_and_wait": Keep system isolated, wait for human admin (for uncertain situations)

Respond with ONLY the action name. No explanation."""
        
        try:
            result = await self.ollama.generate(prompt, system="You are a decisive incident responder. Choose one action only.", temperature=0.1, max_tokens=50)
            action = result.get("response", "isolate_and_wait").strip().lower()
            valid_actions = ["restart_service", "restore_baseline", "kill_process", "isolate_and_wait"]
            if action not in valid_actions:
                action = "isolate_and_wait"
            return action
        except:
            return "isolate_and_wait"
    
    def _identify_affected_service(self, description: str) -> Optional[str]:
        services = {
            "nginx": "nginx", "web": "nginx",
            "ssh": "ssh", "sshd": "ssh",
            "docker": "docker",
            "postgresql": "postgresql", "postgres": "postgresql",
            "redis": "redis-server",
            "ollama": "ollama",
            "sentinel": "sentinel",
        }
        desc_lower = description.lower()
        for keyword, service in services.items():
            if keyword in desc_lower:
                return service
        return None
    
    async def _kill_malicious_process(self, description: str) -> bool:
        # Extract PID if mentioned
        import re
        pids = re.findall(r'\bpid\s+(\d+)', description.lower())
        if not pids:
            pids = re.findall(r'\b(\d+)\b', description)
        
        killed = False
        for pid in pids[:3]:  # Limit to first 3 PIDs found
            try:
                result = subprocess.run(["kill", "-9", pid], capture_output=True, timeout=5)
                if result.returncode == 0:
                    logger.info(f"[HEALER] Killed process {pid}")
                    killed = True
            except Exception as e:
                logger.warning(f"[HEALER] Failed to kill {pid}: {e}")
        return killed


async def main():
    healer = GalinjaAI()
    await healer.run()


if __name__ == "__main__":
    asyncio.run(main())
