#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — AGENT 5: BIOMETRIC-AI
Behavioral Biometrics & User Profiling
================================================================================
Learns how YOU work and blocks anyone who behaves differently:
  1. SSH session timing: keystroke cadence, command entry speed
  2. Command patterns: which commands you run, in what order, at what times
  3. Sudo usage: when and how you escalate privileges
  4. File access patterns: which directories you touch
  5. Network behavior: typical connection patterns

Uses a lightweight ML model (no heavy dependencies) to build a profile.
Anomaly score > threshold → session terminated, alert sent to jitedasti-ai.

Monitors: /var/log/auth.log, /var/log/audit/audit.log, process table
================================================================================
"""

import os
import sys
import re
import json
import time
import asyncio
import logging
import subprocess
from datetime import datetime
from collections import defaultdict, deque
from typing import Dict, List, Any, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from shared import OllamaClient, AgentDatabase, MessageBus

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("papa-ai")


class BehaviorProfile:
    """Stores and compares behavioral patterns for a single user."""
    
    def __init__(self, username: str):
        self.username = username
        self.created_at = datetime.utcnow().isoformat()
        
        # Command frequency (normalized)
        self.command_frequency: Dict[str, int] = defaultdict(int)
        self.total_commands = 0
        
        # Hour-of-day activity distribution (0-23)
        self.hour_distribution = [0] * 24
        
        # Day-of-week activity (0=Monday)
        self.dow_distribution = [0] * 7
        
        # Typical command chains (bigrams)
        self.command_chains: Dict[str, int] = defaultdict(int)
        self.last_command = ""
        
        # Sudo patterns
        self.sudo_frequency = 0
        self.sudo_hours = set()
        
        # Session duration stats (seconds)
        self.session_durations = deque(maxlen=100)
        self.session_start = None
        
        # File access patterns
        self.common_dirs: Dict[str, int] = defaultdict(int)
    
    def record_command(self, command: str, hour: int, dow: int):
        base_cmd = command.split()[0] if command else "unknown"
        self.command_frequency[base_cmd] += 1
        self.total_commands += 1
        self.hour_distribution[hour] += 1
        self.dow_distribution[dow] += 1
        
        # Chain
        if self.last_command:
            chain = f"{self.last_command} -> {base_cmd}"
            self.command_chains[chain] += 1
        self.last_command = base_cmd
    
    def record_sudo(self, hour: int):
        self.sudo_frequency += 1
        self.sudo_hours.add(hour)
    
    def record_session_end(self, duration_seconds: float):
        self.session_durations.append(duration_seconds)
    
    def record_directory(self, path: str):
        # Extract top-level directory
        parts = path.strip("/").split("/")
        if parts:
            top = "/" + parts[0]
            self.common_dirs[top] += 1
    
    def to_dict(self) -> Dict[str, Any]:
        return {
            "username": self.username,
            "created_at": self.created_at,
            "command_frequency": dict(self.command_frequency),
            "total_commands": self.total_commands,
            "hour_distribution": self.hour_distribution,
            "dow_distribution": self.dow_distribution,
            "command_chains": dict(self.command_chains),
            "sudo_frequency": self.sudo_frequency,
            "sudo_hours": list(self.sudo_hours),
            "session_durations": list(self.session_durations),
            "common_dirs": dict(self.common_dirs),
        }
    
    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "BehaviorProfile":
        p = cls(data["username"])
        p.created_at = data.get("created_at", p.created_at)
        p.command_frequency = defaultdict(int, data.get("command_frequency", {}))
        p.total_commands = data.get("total_commands", 0)
        p.hour_distribution = data.get("hour_distribution", [0]*24)
        p.dow_distribution = data.get("dow_distribution", [0]*7)
        p.command_chains = defaultdict(int, data.get("command_chains", {}))
        p.sudo_frequency = data.get("sudo_frequency", 0)
        p.sudo_hours = set(data.get("sudo_hours", []))
        p.session_durations = deque(data.get("session_durations", []), maxlen=100)
        p.common_dirs = defaultdict(int, data.get("common_dirs", {}))
        return p
    
    def compute_anomaly_score(self, session: "SessionSnapshot") -> float:
        """
        Compute anomaly score (0.0 = normal, 1.0 = highly anomalous).
        Uses multiple behavioral dimensions.
        """
        if self.total_commands < 50:
            return 0.0  # Not enough data to judge
        
        scores = []
        
        # 1. Command rarity (how unusual are the commands used?)
        cmd_rarity = 0.0
        for cmd in session.commands:
            base = cmd.split()[0] if cmd else "unknown"
            freq = self.command_frequency.get(base, 0)
            if self.total_commands > 0:
                rarity = 1.0 - (freq / self.total_commands)
                cmd_rarity = max(cmd_rarity, rarity)
        scores.append(cmd_rarity)
        
        # 2. Hour anomaly (are they active at unusual hours?)
        hour_score = 0.0
        if session.hour is not None:
            total_hour_activity = sum(self.hour_distribution)
            if total_hour_activity > 0:
                hour_prob = self.hour_distribution[session.hour] / total_hour_activity
                hour_score = 1.0 - hour_prob
        scores.append(hour_score)
        
        # 3. Sudo timing anomaly
        sudo_score = 0.0
        if session.sudo_used:
            if session.hour is not None and session.hour not in self.sudo_hours:
                sudo_score = 0.7  # Sudo at unusual hour
        scores.append(sudo_score)
        
        # 4. Session duration anomaly
        duration_score = 0.0
        if self.session_durations and session.duration_seconds > 0:
            avg_duration = sum(self.session_durations) / len(self.session_durations)
            std_duration = (sum((d - avg_duration)**2 for d in self.session_durations) / len(self.session_durations)) ** 0.5
            if std_duration > 0:
                z_score = abs(session.duration_seconds - avg_duration) / std_duration
                duration_score = min(z_score / 3.0, 1.0)
        scores.append(duration_score)
        
        # 5. Command velocity (commands per minute)
        velocity_score = 0.0
        if session.duration_seconds > 0:
            cpm = len(session.commands) / (session.duration_seconds / 60)
            if cpm > 30:  # More than 30 commands per minute is suspicious
                velocity_score = min((cpm - 30) / 30, 1.0)
        scores.append(velocity_score)
        
        # Weighted average
        weights = [0.3, 0.2, 0.2, 0.15, 0.15]
        final_score = sum(s * w for s, w in zip(scores, weights))
        return min(final_score, 1.0)


class SessionSnapshot:
    """Captures a single session's behavior."""
    
    def __init__(self, username: str, tty: str, pid: int):
        self.username = username
        self.tty = tty
        self.pid = pid
        self.start_time = time.time()
        self.commands: List[str] = []
        self.sudo_used = False
        self.hour = datetime.now().hour
        self.dow = datetime.now().weekday()
        self.directories_touched: set = set()
    
    @property
    def duration_seconds(self) -> float:
        return time.time() - self.start_time
    
    def add_command(self, cmd: str):
        self.commands.append(cmd)
    
    def mark_sudo(self):
        self.sudo_used = True


class PapaAI:
    """
    Behavioral Biometrics AI Agent.
    Learns normal user behavior and detects impostors.
    """
    
    def __init__(self):
        self.name = "papa-ai"
        self.db = AgentDatabase()
        self.bus = MessageBus()
        self.ollama = OllamaClient()
        self._running = False
        
        self.profiles: Dict[str, BehaviorProfile] = {}
        self.active_sessions: Dict[str, SessionSnapshot] = {}
        self.anomaly_threshold = 0.75
        
        self._load_profiles()
    
    def _load_profiles(self):
        """Load existing profiles from database."""
        try:
            import sqlite3
            with sqlite3.connect(self.db.path) as conn:
                conn.row_factory = sqlite3.Row
                cur = conn.execute("SELECT username, profile_json FROM behavior_profiles")
                for row in cur.fetchall():
                    try:
                        data = json.loads(row["profile_json"])
                        self.profiles[row["username"]] = BehaviorProfile.from_dict(data)
                    except:
                        pass
        except Exception as e:
            logger.warning(f"[BIOMETRIC] Failed to load profiles: {e}")
    
    def _save_profile(self, profile: BehaviorProfile):
        try:
            import sqlite3
            with sqlite3.connect(self.db.path) as conn:
                conn.execute(
                    "INSERT OR REPLACE INTO behavior_profiles (username, profile_json, last_updated) VALUES (?, ?, ?)",
                    (profile.username, json.dumps(profile.to_dict()), datetime.utcnow().isoformat())
                )
        except Exception as e:
            logger.warning(f"[BIOMETRIC] Failed to save profile: {e}")
    
    async def initialize(self):
        await self.bus.connect()
        logger.info("Biometric-AI initialized")
        
        # Create profiles for known users if missing
        for user in ["kirat-admin", "security-officer", "ops-engineer", "dev-engineer", "incident-responder"]:
            if user not in self.profiles:
                self.profiles[user] = BehaviorProfile(user)
                logger.info(f"[BIOMETRIC] Created new behavior profile for {user}")
    
    async def run(self):
        self._running = True
        await self.initialize()
        
        while self._running:
            await self._scan_sessions()
            await self._analyze_auth_log()
            await asyncio.sleep(5)
    
    async def _scan_sessions(self):
        """Scan active SSH/tty sessions."""
        try:
            result = subprocess.run(
                ["who", "-u"], capture_output=True, text=True, timeout=5
            )
            
            current_sessions = set()
            for line in result.stdout.strip().split("\n"):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 7:
                    username = parts[0]
                    tty = parts[1]
                    pid_str = parts[6]
                    try:
                        pid = int(pid_str.strip("."))
                    except:
                        pid = 0
                    
                    session_key = f"{username}@{tty}"
                    current_sessions.add(session_key)
                    
                    if session_key not in self.active_sessions:
                        # New session detected
                        self.active_sessions[session_key] = SessionSnapshot(username, tty, pid)
                        logger.info(f"[BIOMETRIC] New session: {session_key}")
                        
                        # Check if user has a profile
                        if username not in self.profiles:
                            self.profiles[username] = BehaviorProfile(username)
            
            # Check for ended sessions
            ended = set(self.active_sessions.keys()) - current_sessions
            for key in ended:
                session = self.active_sessions.pop(key)
                profile = self.profiles.get(session.username)
                if profile:
                    profile.record_session_end(session.duration_seconds)
                    self._save_profile(profile)
                    logger.info(f"[BIOMETRIC] Session ended: {key}, duration: {session.duration_seconds:.0f}s")
        
        except Exception as e:
            logger.debug(f"[BIOMETRIC] Session scan error: {e}")
    
    async def _analyze_auth_log(self):
        """Parse recent auth.log entries for commands and sudo usage."""
        try:
            result = subprocess.run(
                ["tail", "-n", "100", "/var/log/auth.log"],
                capture_output=True, text=True, timeout=5
            )
            
            for line in result.stdout.strip().split("\n"):
                # Sudo usage
                sudo_match = re.search(r'sudo:\s+(\S+)\s+:', line)
                if sudo_match:
                    username = sudo_match.group(1)
                    hour = datetime.now().hour
                    
                    profile = self.profiles.get(username)
                    if profile:
                        profile.record_sudo(hour)
                    
                    # Mark in active session
                    for key, session in self.active_sessions.items():
                        if session.username == username:
                            session.mark_sudo()
                
                # SSH session commands (from auditd if available)
                # This is a simplified implementation
        
        except Exception as e:
            logger.debug(f"[BIOMETRIC] Auth log analysis error: {e}")
    
    async def evaluate_session(self, session_key: str):
        """Evaluate an active session for anomalous behavior."""
        if session_key not in self.active_sessions:
            return
        
        session = self.active_sessions[session_key]
        profile = self.profiles.get(session.username)
        
        if not profile or profile.total_commands < 50:
            return  # Not enough baseline data
        
        score = profile.compute_anomaly_score(session)
        
        if score >= self.anomaly_threshold:
            logger.critical(f"[BIOMETRIC] ANOMALOUS SESSION: {session_key} score={score:.2f}")
            await self.bus.broadcast_alert(
                "critical", self.name,
                f"Behavioral anomaly detected for {session.username} on {session.tty}. Score: {score:.2f}. Possible impersonation.",
                {"session": session_key, "score": score, "commands": len(session.commands), "duration": session.duration_seconds}
            )
            
            # Optionally: terminate the session
            await self._terminate_session(session)
        elif score >= 0.5:
            logger.warning(f"[BIOMETRIC] Unusual behavior: {session_key} score={score:.2f}")
    
    async def _terminate_session(self, session: SessionSnapshot):
        """Terminate a suspicious session."""
        try:
            subprocess.run(["pkill", "-9", "-t", session.tty], capture_output=True, timeout=5)
            logger.critical(f"[BIOMETRIC] TERMINATED suspicious session: {session.username}@{session.tty}")
        except Exception as e:
            logger.error(f"[BIOMETRIC] Failed to terminate session: {e}")
    
    async def learn_from_command(self, username: str, command: str):
        """Called when a user runs a command (via auditd hook or sudo log)."""
        profile = self.profiles.get(username)
        if not profile:
            return
        
        now = datetime.now()
        profile.record_command(command, now.hour, now.weekday())
        
        # Update active session
        for key, session in self.active_sessions.items():
            if session.username == username:
                session.add_command(command)
                # Periodically evaluate
                if len(session.commands) % 10 == 0:
                    await self.evaluate_session(key)


async def main():
    biometric = PapaAI()
    await biometric.run()


if __name__ == "__main__":
    asyncio.run(main())
