#!/usr/bin/env python3
"""
KIRAT OS — AI Agent Shared Infrastructure
Inter-agent communication, Ollama client, database, and configuration.
"""

import os
import sys
import json
import asyncio
import logging
import sqlite3
from datetime import datetime
from typing import Dict, Any, Optional, Callable
from dataclasses import dataclass, asdict

import httpx

# ── Configuration ──
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://localhost:11434")
DEFAULT_MODEL = os.getenv("SENTINEL_MODEL", "gemma4:latest")
REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = int(os.getenv("REDIS_PORT", "6379"))
AGENT_DB_PATH = "/var/lib/kirat-os/ai-agents.db"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)


class OllamaClient:
    """Shared Ollama LLM client for all AI agents."""
    
    def __init__(self, host: str = OLLAMA_HOST, model: str = DEFAULT_MODEL):
        self.host = host.rstrip("/")
        self.model = model
        self.client = httpx.AsyncClient(timeout=60.0)
    
    async def generate(self, prompt: str, system: Optional[str] = None,
                       temperature: float = 0.3, max_tokens: int = 1024) -> Dict[str, Any]:
        payload = {
            "model": self.model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": temperature, "num_predict": max_tokens}
        }
        if system:
            payload["system"] = system
        try:
            r = await self.client.post(f"{self.host}/api/generate", json=payload, timeout=60.0)
            r.raise_for_status()
            data = r.json()
            return {"success": True, "response": data.get("response", ""), "model": data.get("model", self.model)}
        except Exception as e:
            logging.error(f"Ollama error: {e}")
            return {"success": False, "error": str(e)}
    
    async def is_healthy(self) -> bool:
        try:
            r = await self.client.get(f"{self.host}/api/tags", timeout=5.0)
            return r.status_code == 200
        except:
            return False


class AgentDatabase:
    """SQLite database for agent persistence (anomalies, predictions, profiles)."""
    
    def __init__(self, path: str = AGENT_DB_PATH):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._init_tables()
    
    def _init_tables(self):
        with sqlite3.connect(self.path) as conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS anomalies (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    category TEXT NOT NULL,
                    description TEXT,
                    evidence TEXT,
                    timestamp TEXT NOT NULL,
                    resolved INTEGER DEFAULT 0
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS predictions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    cve_id TEXT,
                    package TEXT,
                    predicted_exploitability REAL,
                    evidence TEXT,
                    patched INTEGER DEFAULT 0,
                    timestamp TEXT NOT NULL
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS behavior_profiles (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL UNIQUE,
                    profile_json TEXT NOT NULL,
                    last_updated TEXT NOT NULL
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS deception_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    honeypot_name TEXT NOT NULL,
                    attacker_ip TEXT,
                    attacker_data TEXT,
                    timestamp TEXT NOT NULL
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS heal_actions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    trigger TEXT NOT NULL,
                    actions_taken TEXT,
                    success INTEGER DEFAULT 0,
                    timestamp TEXT NOT NULL
                )
            """)
    
    def insert_anomaly(self, agent: str, severity: str, category: str,
                       description: str, evidence: Dict[str, Any]):
        with sqlite3.connect(self.path) as conn:
            conn.execute(
                "INSERT INTO anomalies (agent, severity, category, description, evidence, timestamp) VALUES (?, ?, ?, ?, ?, ?)",
                (agent, severity, category, description, json.dumps(evidence), datetime.utcnow().isoformat())
            )
    
    def insert_prediction(self, cve_id: str, package: str, exploitability: float, evidence: str):
        with sqlite3.connect(self.path) as conn:
            conn.execute(
                "INSERT INTO predictions (cve_id, package, predicted_exploitability, evidence, timestamp) VALUES (?, ?, ?, ?, ?)",
                (cve_id, package, exploitability, evidence, datetime.utcnow().isoformat())
            )
    
    def get_recent_anomalies(self, hours: int = 24) -> list:
        with sqlite3.connect(self.path) as conn:
            conn.row_factory = sqlite3.Row
            cur = conn.execute(
                "SELECT * FROM anomalies WHERE timestamp > datetime('now', '-{} hours') AND resolved = 0 ORDER BY timestamp DESC".format(hours)
            )
            return [dict(row) for row in cur.fetchall()]


class MessageBus:
    """Redis-based pub/sub for inter-agent communication."""
    
    def __init__(self, host: str = REDIS_HOST, port: int = REDIS_PORT):
        self.host = host
        self.port = port
        self._pubsub = None
        self._redis = None
        self._listeners: Dict[str, Callable] = {}
    
    async def connect(self):
        try:
            import aioredis
            self._redis = await aioredis.from_url(f"redis://{self.host}:{self.port}")
            self._pubsub = self._redis.pubsub()
            logging.info("MessageBus connected to Redis")
        except ImportError:
            logging.warning("aioredis not installed, using in-memory bus")
            self._redis = None
        except Exception as e:
            logging.error(f"Redis connection failed: {e}")
            self._redis = None
    
    async def publish(self, channel: str, message: Dict[str, Any]):
        payload = json.dumps(message)
        if self._redis:
            await self._redis.publish(channel, payload)
        logging.info(f"[BUS] {channel}: {message.get('type', 'unknown')}")
    
    async def broadcast_alert(self, severity: str, source: str, description: str, evidence: Dict[str, Any] = None):
        await self.publish("kirat.alerts", {
            "type": "alert",
            "severity": severity,
            "source": source,
            "description": description,
            "evidence": evidence or {},
            "timestamp": datetime.utcnow().isoformat()
        })


# ── Decorators for agent health ──
def require_ollama(func):
    """Decorator to skip execution if Ollama is unavailable."""
    async def wrapper(self, *args, **kwargs):
        if not await self.ollama.is_healthy():
            logging.warning(f"[{self.name}] Ollama unavailable, skipping {func.__name__}")
            return None
        return await func(self, *args, **kwargs)
    return wrapper
