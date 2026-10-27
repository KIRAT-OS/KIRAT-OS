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
from contextlib import contextmanager
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
    """SQLite persistence, including durable exactly-once incident claims."""

    def __init__(self, path: str = AGENT_DB_PATH):
        self.path = path
        directory = os.path.dirname(os.path.abspath(path))
        os.makedirs(directory, exist_ok=True)
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
            conn.execute("""
                CREATE TABLE IF NOT EXISTS incident_claims (
                    incident_id TEXT PRIMARY KEY,
                    agent TEXT NOT NULL,
                    status TEXT NOT NULL,
                    claimed_at TEXT NOT NULL,
                    completed_at TEXT
                )
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS incident_actions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    incident_id TEXT NOT NULL,
                    agent TEXT NOT NULL,
                    action TEXT NOT NULL,
                    success INTEGER NOT NULL,
                    detail TEXT,
                    timestamp TEXT NOT NULL,
                    UNIQUE(incident_id, agent, action)
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
                "SELECT * FROM anomalies WHERE timestamp > datetime('now', ?) AND resolved = 0 ORDER BY timestamp DESC",
                (f"-{hours} hours",)
            )
            return [dict(row) for row in cur.fetchall()]

    def claim_incident(self, incident_id, agent: str) -> bool:
        """Atomically claim an incident; a durable prior claim is never repeated."""
        with sqlite3.connect(self.path, timeout=30) as conn:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                "INSERT OR IGNORE INTO incident_claims (incident_id, agent, status, claimed_at) VALUES (?, ?, 'claimed', ?)",
                (str(incident_id), agent, datetime.utcnow().isoformat()),
            )
            return cursor.rowcount == 1

    def record_incident_action(self, incident_id, agent: str, action: str,
                               success: bool, detail: str = "") -> bool:
        """Persist one idempotent terminal action record for a claimed incident."""
        now = datetime.utcnow().isoformat()
        with sqlite3.connect(self.path, timeout=30) as conn:
            conn.execute("BEGIN IMMEDIATE")
            claimed = conn.execute(
                "SELECT 1 FROM incident_claims WHERE incident_id = ? AND agent = ?",
                (str(incident_id), agent),
            ).fetchone()
            if not claimed:
                return False
            conn.execute(
                """INSERT INTO incident_actions
                   (incident_id, agent, action, success, detail, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?)
                   ON CONFLICT(incident_id, agent, action) DO UPDATE SET
                       success = excluded.success, detail = excluded.detail,
                       timestamp = excluded.timestamp""",
                (str(incident_id), agent, action, int(bool(success)), detail, now),
            )
            conn.execute(
                "UPDATE incident_claims SET status = ?, completed_at = ? WHERE incident_id = ?",
                ("completed" if success else "failed", now, str(incident_id)),
            )
            return True

    def get_incident_actions(self, incident_id) -> list:
        with sqlite3.connect(self.path) as conn:
            conn.row_factory = sqlite3.Row
            rows = conn.execute(
                "SELECT * FROM incident_actions WHERE incident_id = ? ORDER BY id",
                (str(incident_id),),
            ).fetchall()
            return [dict(row) for row in rows]


class MessageBus:
    """Real Redis pub/sub with reconnects; delivery is disabled when unavailable."""

    def __init__(self, host: str = REDIS_HOST, port: int = REDIS_PORT):
        self.host = host
        self.port = port
        self._redis = None
        self._listeners: Dict[str, Callable] = {}
        self._subscription_task = None
        self._closed = False

    @property
    def enabled(self) -> bool:
        return self._redis is not None

    async def connect(self) -> bool:
        """Connect using redis.asyncio from the installed redis package."""
        self._closed = False
        redis = None
        try:
            from redis.asyncio import from_url
            redis = from_url(
                f"redis://{self.host}:{self.port}",
                socket_connect_timeout=3,
                socket_timeout=5,
                decode_responses=True,
            )
            await redis.ping()
            self._redis = redis
            logging.info("MessageBus connected to Redis")
            return True
        except ImportError:
            logging.error("MessageBus disabled: install the redis Python package")
        except Exception as exc:
            logging.error("MessageBus disabled; Redis connection failed: %s", exc)
            if redis is not None:
                try:
                    await redis.close()
                except Exception:
                    pass
        self._redis = None
        return False

    async def publish(self, channel: str, message: Dict[str, Any]) -> bool:
        """Publish to Redis and report failure honestly; never emulate delivery."""
        if self._redis is None:
            logging.warning("[BUS] disabled; message not delivered on %s", channel)
            return False
        try:
            await self._redis.publish(channel, json.dumps(message))
            logging.info("[BUS] published %s: %s", channel, message.get("type", "unknown"))
            return True
        except Exception as exc:
            logging.error("[BUS] publish failed on %s: %s", channel, exc)
            self._redis = None
            return False

    async def subscribe(self, channel: str, callback: Callable):
        """Register a real Redis subscription and start its reconnecting reader."""
        self._listeners[channel] = callback
        self._closed = False
        if self._subscription_task is None or self._subscription_task.done():
            self._subscription_task = asyncio.create_task(self._subscription_loop())

    async def _subscription_loop(self):
        delay = 1
        while self._listeners and not self._closed:
            pubsub = None
            try:
                if self._redis is None and not await self.connect():
                    await asyncio.sleep(delay)
                    delay = min(delay * 2, 30)
                    continue
                pubsub = self._redis.pubsub()
                await pubsub.subscribe(*self._listeners.keys())
                delay = 1
                while self._listeners and not self._closed and self._redis is not None:
                    message = await pubsub.get_message(ignore_subscribe_messages=True, timeout=1.0)
                    if not message or message.get("type") != "message":
                        continue
                    callback = self._listeners.get(message.get("channel"))
                    if callback is None:
                        continue
                    try:
                        payload = json.loads(message["data"])
                        result = callback(message["channel"], payload)
                        if asyncio.iscoroutine(result):
                            await result
                    except Exception as exc:
                        logging.error("[BUS] subscriber callback failed: %s", exc)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logging.error("[BUS] subscription disconnected: %s", exc)
                self._redis = None
                await asyncio.sleep(delay)
                delay = min(delay * 2, 30)
            finally:
                if pubsub is not None:
                    try:
                        await pubsub.close()
                    except Exception:
                        pass

    async def broadcast_alert(self, severity: str, source: str, description: str,
                              evidence: Dict[str, Any] = None) -> bool:
        return await self.publish("kirat.alerts", {
            "type": "alert",
            "severity": severity,
            "source": source,
            "description": description,
            "evidence": evidence or {},
            "timestamp": datetime.utcnow().isoformat()
        })

    async def close(self):
        self._closed = True
        if self._subscription_task is not None:
            self._subscription_task.cancel()
            try:
                await self._subscription_task
            except asyncio.CancelledError:
                pass
        if self._redis is not None:
            await self._redis.close()
            self._redis = None


# ── Decorators for agent health ──
def require_ollama(func):
    """Decorator to skip execution if Ollama is unavailable."""
    async def wrapper(self, *args, **kwargs):
        if not await self.ollama.is_healthy():
            logging.warning(f"[{self.name}] Ollama unavailable, skipping {func.__name__}")
            return None
        return await func(self, *args, **kwargs)
    return wrapper
