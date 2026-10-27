#!/usr/bin/env python3
"""Galinja AI: conservative self-healing and forensic incident response.

Monitoring and evidence collection remain automatic. Destructive remediation is
opt-in and additionally requires an administrator-signed canonical executor
instruction. Every incident is durably claimed before it is processed.
"""

import argparse
import asyncio
import json
import logging
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime
from typing import Any, Dict, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from shared import AgentDatabase, MessageBus, OllamaClient
from shared.privileged import PrivilegedExecutor, destructive_actions_enabled

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("galinja-ai")


class FirewallEmergency:
    """Request firewall changes only through the signed executor."""

    def __init__(self, executor: Optional[PrivilegedExecutor] = None):
        self.executor = executor or PrivilegedExecutor("galinja-ai")

    def isolate(self) -> bool:
        if not destructive_actions_enabled():
            logger.error("[HEALER] Isolation disabled; set KIRAT_OS_ENABLE_DESTRUCTIVE_ACTIONS=true and provide signed approval")
            return False
        result = self.executor.execute_configured("isolate")
        if not result.success:
            logger.error("[HEALER] Isolation not performed: %s", result.message)
        return result.success

    def restore_normal(self) -> bool:
        if not destructive_actions_enabled():
            logger.error("[HEALER] Firewall restore is disabled by default")
            return False
        result = self.executor.execute_configured("restore-firewall")
        if not result.success:
            logger.error("[HEALER] Firewall restore failed: %s", result.message)
        return result.success


class ServiceRestorer:
    """Create local baselines and delegate any restore/restart to signed approval."""

    BACKUP_DIR = os.getenv("GALINJA_BACKUP_DIR", "/var/lib/kirat-os/galinja-ai/backups")

    def __init__(self, executor: Optional[PrivilegedExecutor] = None):
        self.executor = executor or PrivilegedExecutor("galinja-ai")
        os.makedirs(self.BACKUP_DIR, exist_ok=True)

    def create_baseline_backup(self) -> str:
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S_%f")
        backup_path = os.path.join(self.BACKUP_DIR, f"baseline_{timestamp}")
        os.makedirs(backup_path, exist_ok=False)
        manifest = []
        items_to_backup = [
            "/etc/nginx", "/etc/ssh", "/etc/systemd/system/ollama.service",
            "/opt/kirat-os/sentinel-core", "/opt/kirat-os/dashboard",
            "/opt/kirat-os/security", "/etc/ufw", "/etc/fail2ban",
        ]
        for item in items_to_backup:
            if not os.path.exists(item):
                continue
            # Names are prefixed to avoid collisions between identically named paths.
            dest = os.path.join(backup_path, item.strip("/").replace("/", "__"))
            try:
                if os.path.isdir(item):
                    shutil.copytree(item, dest, dirs_exist_ok=True, symlinks=True)
                else:
                    shutil.copy2(item, dest)
                manifest.append({"source": item, "backup": os.path.basename(dest)})
            except (OSError, shutil.Error) as exc:
                logger.warning("Backup failed for %s: %s", item, exc)
        with open(os.path.join(backup_path, "manifest.json"), "w", encoding="utf-8") as handle:
            json.dump(manifest, handle, indent=2)
        latest_link = os.path.join(self.BACKUP_DIR, "latest")
        temporary_link = os.path.join(self.BACKUP_DIR, ".latest.tmp")
        if os.path.lexists(temporary_link):
            os.unlink(temporary_link)
        os.symlink(backup_path, temporary_link)
        os.replace(temporary_link, latest_link)
        logger.info("[HEALER] Baseline backup created: %s (%d items)", backup_path, len(manifest))
        return backup_path

    def restore_from_baseline(self) -> bool:
        latest = os.path.join(self.BACKUP_DIR, "latest")
        if not os.path.islink(latest) or not os.path.isdir(latest):
            logger.error("[HEALER] No baseline backup available for restore")
            return False
        if not destructive_actions_enabled():
            logger.error("[HEALER] Baseline restore is disabled by default")
            return False
        result = self.executor.execute_configured("restore-baseline", timeout=300)
        if not result.success:
            logger.error("[HEALER] Baseline restore not performed: %s", result.message)
        return result.success

    def restart_service(self, service: str) -> bool:
        # The signed instruction, not alert text, determines the exact service.
        if not service or not destructive_actions_enabled():
            logger.error("[HEALER] Service restart is disabled or has no target")
            return False
        result = self.executor.execute_configured("restart-service")
        if not result.success:
            logger.error("[HEALER] Service restart not performed: %s", result.message)
        return result.success


class ForensicCollector:
    """Collect read-only forensic evidence without claiming privileged success."""

    FORENSIC_DIR = os.getenv("GALINJA_FORENSIC_DIR", "/var/lib/kirat-os/galinja-ai/forensics")

    def __init__(self):
        os.makedirs(self.FORENSIC_DIR, exist_ok=True)

    def collect(self, trigger: str) -> str:
        safe_trigger = re.sub(r"[^A-Za-z0-9_.-]", "_", trigger or "unknown")[:80]
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S_%f")
        case_dir = os.path.join(self.FORENSIC_DIR, f"case_{timestamp}_{safe_trigger}")
        os.makedirs(case_dir, exist_ok=False)
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
            "docker.txt": ["docker", "ps", "-a"],
        }
        for filename, command in commands.items():
            try:
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                output = result.stdout
                if result.returncode != 0 or result.stderr:
                    output += f"\n--- STATUS: exit {result.returncode}; evidence may be incomplete ---\n{result.stderr}"
                with open(os.path.join(case_dir, filename), "w", encoding="utf-8") as handle:
                    handle.write(output)
            except (OSError, subprocess.TimeoutExpired) as exc:
                logger.warning("Forensic collection failed for %s: %s", filename, exc)
                with open(os.path.join(case_dir, filename), "w", encoding="utf-8") as handle:
                    handle.write(f"Collection failed: {exc}\n")
        logger.info("[HEALER] Forensic evidence collected: %s", case_dir)
        return case_dir


class GalinjaAI:
    def __init__(self, db=None, bus=None, ollama=None, restorer=None, forensics=None,
                 executor: Optional[PrivilegedExecutor] = None):
        self.name = "galinja-ai"
        self.ollama = ollama or OllamaClient()
        self.db = db or AgentDatabase()
        self.bus = bus or MessageBus()
        self.executor = executor or PrivilegedExecutor(self.name)
        self.restorer = restorer or ServiceRestorer(self.executor)
        self.forensics = forensics or ForensicCollector()
        self.firewall = FirewallEmergency(self.executor)
        self._running = False
        self._isolated = False

    async def initialize(self):
        await self.bus.connect()
        self.restorer.create_baseline_backup()
        logger.info("Galinja initialized; destructive actions enabled=%s", destructive_actions_enabled())

    async def run(self):
        self._running = True
        await self.initialize()
        while self._running:
            anomalies = self.db.get_recent_anomalies(hours=1)
            for anomaly in anomalies:
                if str(anomaly.get("severity", "")).lower() in ("critical", "high") and not anomaly.get("resolved", 0):
                    await self._respond_to_threat(anomaly)
            await asyncio.sleep(10)

    async def _respond_to_threat(self, anomaly: Dict[str, Any]) -> bool:
        threat_id = anomaly.get("id")
        if threat_id is None:
            logger.error("[HEALER] Ignoring anomaly without an id")
            return False
        if not self.db.claim_incident(threat_id, self.name):
            logger.info("[HEALER] Threat #%s already claimed; skipping duplicate", threat_id)
            return False

        severity = str(anomaly.get("severity", "unknown")).lower()
        category = str(anomaly.get("category") or "unknown")
        description = str(anomaly.get("description") or "")
        logger.critical("[HEALER] RESPONDING TO THREAT #%s: %s (%s)", threat_id, category, severity)
        success = False
        action = "response_failed"
        detail = ""
        try:
            if severity == "critical" and not self._isolated:
                self._isolated = self.firewall.isolate()
                if self._isolated:
                    await self.bus.broadcast_alert(
                        "critical", self.name,
                        f"Emergency isolation activated due to {category}", {"threat_id": threat_id},
                    )

            case_dir = self.forensics.collect(category)
            action = await self._decide_action(category, description, severity)
            if action == "restart_service":
                affected = self._identify_affected_service(description)
                success = bool(affected) and self.restorer.restart_service(affected)
                detail = affected or "No affected service identified"
            elif action == "restore_baseline":
                success = self.restorer.restore_from_baseline()
                detail = "Signed baseline restore requested"
            elif action == "kill_process":
                success = await self._kill_malicious_process(description)
                detail = "Signed process termination requested"
            elif action == "isolate_and_wait":
                success = True  # Waiting and preserving evidence is a safe, completed response.
                detail = "Monitoring preserved; waiting for administrator"
        except Exception as exc:
            logger.exception("[HEALER] Response failed for threat #%s", threat_id)
            detail = str(exc)
            success = False

        self.db.record_incident_action(threat_id, self.name, action, success, detail)
        logger.info("[HEALER] Response complete for threat #%s. Action: %s, Success: %s", threat_id, action, success)
        await self.bus.broadcast_alert(
            severity, self.name,
            f"Galinja response complete for {category}. Action: {action}. Success: {success}",
            {"threat_id": threat_id, "action": action, "success": success, "isolated": self._isolated},
        )
        return success

    async def _decide_action(self, category: str, description: str, severity: str) -> str:
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
            result = await self.ollama.generate(
                prompt, system="You are a cautious incident responder. Choose one action only.",
                temperature=0.1, max_tokens=50,
            )
            action = result.get("response") or "isolate_and_wait"
            action = action.strip().lower()
            valid_actions = {"restart_service", "restore_baseline", "kill_process", "isolate_and_wait"}
            return action if action in valid_actions else "isolate_and_wait"
        except Exception as exc:
            logger.warning("[HEALER] Decision unavailable; waiting for administrator: %s", exc)
            return "isolate_and_wait"

    def _identify_affected_service(self, description: str) -> Optional[str]:
        services = {
            "nginx": "nginx", "web": "nginx", "ssh": "ssh", "sshd": "ssh",
            "docker": "docker", "postgresql": "postgresql", "postgres": "postgresql",
            "redis": "redis-server", "ollama": "ollama", "sentinel": "sentinel",
        }
        description = description.lower()
        return next((service for keyword, service in services.items() if keyword in description), None)

    async def _kill_malicious_process(self, description: str) -> bool:
        if not re.search(r"\bpid\s+[1-9]\d*\b", description.lower()):
            logger.error("[HEALER] No explicit PID supplied; refusing process termination")
            return False
        if not destructive_actions_enabled():
            logger.error("[HEALER] Process termination is disabled by default")
            return False
        result = self.executor.execute_configured("kill-process")
        if not result.success:
            logger.error("[HEALER] Process termination not performed: %s", result.message)
        return result.success


async def main():
    parser = argparse.ArgumentParser(description="Galinja incident response agent")
    parser.add_argument("--create-baseline", action="store_true")
    args = parser.parse_args()
    if args.create_baseline:
        path = ServiceRestorer().create_baseline_backup()
        print(path)
        return
    await GalinjaAI().run()


if __name__ == "__main__":
    asyncio.run(main())
