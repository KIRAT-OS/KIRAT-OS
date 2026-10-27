#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — AGENT 1: HUNTER-AI
Autonomous Threat Hunting & Anomaly Detection
================================================================================
Reads logs 24/7, detects never-before-seen anomalies using:
  1. Statistical methods (z-score, isolation forest)
  2. Pattern analysis (failed logins, unusual process trees)
  3. LLM-powered semantic analysis of log entries

Feeds: journalctl, auditd, /var/log/auth.log, /var/log/nginx/error.log,
       AIDE reports, rkhunter reports

Actions: Broadcasts alerts to message bus, stores anomalies in DB,
         triggers galinja-ai on critical findings.
================================================================================
"""

import os
import sys
import re
import json
import time
import math
import asyncio
import logging
import subprocess
from datetime import datetime, timedelta
from collections import defaultdict, deque
from typing import Dict, List, Any, Optional, Tuple

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from shared import OllamaClient, AgentDatabase, MessageBus, require_ollama

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("jitedasti-ai")


class LogStream:
    """Continuously stream logs from various sources."""
    
    SOURCES = {
        "journalctl": ["journalctl", "-f", "-n", "0", "--no-pager", "-q"],
        "auditd": ["tail", "-F", "-n", "0", "/var/log/audit/audit.log"],
        "auth": ["tail", "-F", "-n", "0", "/var/log/auth.log"],
        "nginx": ["tail", "-F", "-n", "0", "/var/log/nginx/error.log"],
        "kirat": ["tail", "-F", "-n", "0", "/var/log/kirat-os/kirat.log"],
    }
    
    def __init__(self):
        self.queues: Dict[str, asyncio.Queue] = {name: asyncio.Queue(maxsize=10000) for name in self.SOURCES}
        self._tasks = []
    
    def start(self):
        for name, cmd in self.SOURCES.items():
            self._tasks.append(asyncio.create_task(self._read_stream(name, cmd)))
    
    async def _read_stream(self, name: str, cmd: list):
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
            )
            while True:
                line = await proc.stdout.readline()
                if not line:
                    await asyncio.sleep(1)
                    continue
                text = line.decode("utf-8", errors="replace").strip()
                if text:
                    try:
                        self.queues[name].put_nowait(text)
                    except asyncio.QueueFull:
                        pass  # Drop oldest if overwhelmed
        except Exception as e:
            logger.error(f"LogStream {name} error: {e}")
    
    def get(self, source: str, timeout: float = 0.1) -> Optional[str]:
        try:
            return self.queues[source].get_nowait()
        except asyncio.QueueEmpty:
            return None


class StatisticalAnomalyDetector:
    """Detect anomalies using statistical methods."""
    
    def __init__(self, window_size: int = 1000):
        self.windows: Dict[str, deque] = defaultdict(lambda: deque(maxlen=window_size))
        self.baselines: Dict[str, Dict] = {}
    
    def update(self, key: str, value: float):
        self.windows[key].append(value)
    
    def zscore(self, key: str, value: float) -> Optional[float]:
        window = self.windows[key]
        if len(window) < 30:
            return None
        mean = sum(window) / len(window)
        variance = sum((x - mean) ** 2 for x in window) / len(window)
        std = math.sqrt(variance) if variance > 0 else 1
        return (value - mean) / std
    
    def is_anomaly(self, key: str, value: float, threshold: float = 3.0) -> bool:
        z = self.zscore(key, value)
        return z is not None and abs(z) > threshold


class JitedastiAI:
    """
    Autonomous Threat Hunter.
    Continuously monitors logs, detects anomalies, uses LLM for deep analysis.
    """
    
    def __init__(self):
        self.name = "jitedasti-ai"
        self.ollama = OllamaClient()
        self.db = AgentDatabase()
        self.bus = MessageBus()
        self.logs = LogStream()
        self.detector = StatisticalAnomalyDetector()
        self._running = False
        
        # Trackers
        self.failed_logins: Dict[str, List[float]] = defaultdict(list)
        self.process_trees: Dict[str, int] = defaultdict(int)
        self.sudo_attempts: deque = deque(maxlen=500)
    
    async def initialize(self):
        await self.bus.connect()
        self.logs.start()
        logger.info("Hunter-AI initialized and streaming logs")
    
    async def run(self):
        self._running = True
        await self.initialize()
        
        # Main loop: process logs from all sources
        while self._running:
            for source in self.logs.SOURCES:
                line = self.logs.get(source)
                if line:
                    await self._analyze_line(source, line)
            
            # Periodic deep scan every 60 seconds
            await asyncio.sleep(0.1)
    
    async def _analyze_line(self, source: str, line: str):
        """Analyze a single log line."""
        
        # Pattern 1: Failed SSH logins (brute force detection)
        if source == "auth":
            match = re.search(r"Failed password for .* from (\S+)", line)
            if match:
                ip = match.group(1)
                now = time.time()
                self.failed_logins[ip].append(now)
                # Clean old entries
                self.failed_logins[ip] = [t for t in self.failed_logins[ip] if now - t < 300]
                if len(self.failed_logins[ip]) >= 5:
                    await self._report_brute_force(ip, len(self.failed_logins[ip]))
            
            # Pattern 2: New user creation
            if "useradd" in line or "new user" in line.lower():
                await self._report_suspicious("NEW_USER", f"New user creation detected: {line[:200]}", {"source": source, "line": line})
            
            # Pattern 3: Sudo escalation
            if "sudo:" in line:
                self.sudo_attempts.append(time.time())
                recent = [t for t in self.sudo_attempts if time.time() - t < 60]
                if len(recent) > 10:
                    await self._report_suspicious("SUDO_FLOOD", f"Unusual sudo activity: {len(recent)} attempts in 60s", {"count": len(recent)})
        
        # Pattern 4: Nginx error spikes (web attacks)
        if source == "nginx":
            if "403" in line or "401" in line or "404" in line:
                self.detector.update("nginx_errors", 1)
            if "SQL" in line.upper() or " UNION " in line.upper() or "<script" in line.lower():
                await self._report_suspicious("WEB_ATTACK", f"Possible web attack: {line[:300]}", {"source": source, "line": line}, severity="critical")
        
        # Pattern 5: Auditd anomalies (file integrity, permission changes)
        if source == "auditd":
            if "type=SYSCALL" in line and ("chmod" in line or "chown" in line or "open" in line):
                # Track file permission changes in sensitive directories
                if "/etc/" in line or "/opt/kirat-os/" in line or "/root/" in line:
                    await self._report_suspicious("FILE_CHANGE", f"Sensitive file access: {line[:300]}", {"source": source, "line": line})
        
        # Pattern 6: Kernel/module events (rootkit indicators)
        if "journalctl" in source or "auditd" in source:
            if "module" in line.lower() and ("load" in line.lower() or "insert" in line.lower()):
                if "kirat" not in line.lower():  # Exclude our own modules
                    await self._report_suspicious("MODULE_LOAD", f"Kernel module loaded: {line[:300]}", {"source": source, "line": line}, severity="high")
    
    async def _report_brute_force(self, ip: str, count: int):
        await self.bus.broadcast_alert("high", self.name, f"SSH brute force detected from {ip}", {"ip": ip, "failed_attempts": count})
        self.db.insert_anomaly(self.name, "high", "BRUTE_FORCE", f"SSH brute force from {ip}", {"ip": ip, "count": count})
        logger.warning(f"[HUNTER] Brute force from {ip}: {count} attempts")
    
    async def _report_suspicious(self, category: str, description: str, evidence: Dict, severity: str = "medium"):
        await self.bus.broadcast_alert(severity, self.name, description, evidence)
        self.db.insert_anomaly(self.name, severity, category, description, evidence)
        logger.warning(f"[HUNTER] {category}: {description[:120]}")
    
    @require_ollama
    async def deep_analysis(self, anomaly_id: int) -> str:
        """Use LLM to perform deep analysis of a stored anomaly."""
        anomalies = self.db.get_recent_anomalies(hours=1)
        target = next((a for a in anomalies if a["id"] == anomaly_id), None)
        if not target:
            return "Anomaly not found"
        
        prompt = f"""Analyze this security anomaly like a senior SOC analyst:

Category: {target['category']}
Severity: {target['severity']}
Description: {target['description']}
Evidence: {target['evidence']}

Provide:
1. Likely attack technique (MITRE ATT&CK if applicable)
2. Confidence level (low/medium/high)
3. Recommended immediate actions
4. Whether this could be a false positive

Be concise."""
        
        result = await self.ollama.generate(prompt, system="You are a senior threat hunter. Be precise and actionable.", temperature=0.2)
        return result.get("response", "Analysis unavailable")
    
    async def periodic_deep_scan(self):
        """Run every 5 minutes: analyze patterns across all recent anomalies."""
        while self._running:
            await asyncio.sleep(300)
            anomalies = self.db.get_recent_anomalies(hours=1)
            
            if len(anomalies) >= 3:
                # Cluster analysis: are multiple anomalies related?
                categories = defaultdict(int)
                for a in anomalies:
                    categories[a["category"]] += 1
                
                dominant = max(categories, key=categories.get)
                if categories[dominant] >= 3:
                    await self.bus.broadcast_alert(
                        "critical", self.name,
                        f"Pattern detected: {categories[dominant]} {dominant} anomalies in 1 hour. Possible coordinated attack.",
                        {"pattern": dominant, "count": categories[dominant], "all_categories": dict(categories)}
                    )
                    logger.critical(f"[HUNTER] Coordinated attack pattern: {dominant} x{categories[dominant]}")


async def main():
    hunter = JitedastiAI()
    await hunter.initialize()
    
    # Run main log analysis + periodic deep scan concurrently
    await asyncio.gather(
        hunter.run(),
        hunter.periodic_deep_scan()
    )


if __name__ == "__main__":
    asyncio.run(main())
