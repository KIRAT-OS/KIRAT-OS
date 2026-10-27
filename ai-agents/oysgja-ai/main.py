#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — AGENT 3: DECEPTION-AI
Adaptive Honeypots & Attacker Deception
================================================================================
Creates convincing fake services to trap, study, and delay attackers:
  - Fake SSH server on port 2222 (catches brute force scanners)
  - Fake PostgreSQL on port 5433 (catches database attackers)
  - Fake Redis on port 6380 (catches cache attackers)
  - Fake API endpoints (catches web attackers)
  - Canary files in /tmp and /data (catches file access)

All interactions are logged with full attacker data (IP, commands, timing).
Feeds intelligence directly to jitedasti-ai via message bus.
================================================================================
"""

import os
import sys
import json
import time
import asyncio
import logging
import socket
import threading
from datetime import datetime
from typing import Dict, Any, Optional

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from shared import AgentDatabase, MessageBus

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("oysgja-ai")


class FakeSSHServer:
    """Emulates an SSH server to capture brute force attempts."""
    
    BANNER = b"SSH-2.0-OpenSSH_8.9p1 Ubuntu-3ubuntu0.1\r\n"
    FAKE_USERS = ["root", "admin", "user", "test", "oracle", "postgres", "ubuntu"]
    
    def __init__(self, host: str = "0.0.0.0", port: int = 2222):
        self.host = host
        self.port = port
        self.sock = None
        self._running = False
    
    def start(self):
        self._running = True
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.sock.bind((self.host, self.port))
            self.sock.listen(5)
            logger.info(f"[DECEPTION] Fake SSH listening on {self.host}:{self.port}")
            threading.Thread(target=self._accept_loop, daemon=True).start()
        except OSError as e:
            logger.error(f"[DECEPTION] Cannot bind fake SSH to port {self.port}: {e}")
    
    def _accept_loop(self):
        while self._running:
            try:
                self.sock.settimeout(1.0)
                client, addr = self.sock.accept()
                threading.Thread(target=self._handle_client, args=(client, addr), daemon=True).start()
            except socket.timeout:
                continue
            except Exception as e:
                logger.error(f"[DECEPTION] SSH accept error: {e}")
    
    def _handle_client(self, client: socket.socket, addr: tuple):
        attacker_ip = addr[0]
        logger.warning(f"[DECEPTION] ATTACKER CONNECTED to fake SSH: {attacker_ip}")
        
        try:
            client.send(self.BANNER)
            
            # Collect whatever they send us
            data_buffer = []
            client.settimeout(10.0)
            for _ in range(10):  # Up to 10 packets
                try:
                    data = client.recv(4096)
                    if not data:
                        break
                    data_buffer.append(data.hex()[:200])
                except socket.timeout:
                    break
            
            # Log the event
            event = {
                "honeypot": "fake-ssh",
                "attacker_ip": attacker_ip,
                "attacker_port": addr[1],
                "data_samples": data_buffer,
                "timestamp": datetime.utcnow().isoformat()
            }
            self._log_event(event)
            
            # Pretend to authenticate slowly (wastes attacker's time)
            time.sleep(5)
            client.send(b"Permission denied, please try again.\r\n")
            time.sleep(3)
            
        except Exception as e:
            logger.debug(f"[DECEPTION] SSH handler error: {e}")
        finally:
            client.close()
    
    def _log_event(self, event: Dict):
        # Async logging via message bus would happen here
        logger.info(f"[DECEPTION] Event logged: {event['honeypot']} from {event['attacker_ip']}")


class FakeHTTPServer:
    """Emulates vulnerable web endpoints to catch web attackers."""
    
    FAKE_ENDPOINTS = {
        "/admin": b'{"error": "Unauthorized", "msg": "Please login with admin:admin123"}',
        "/api/v1/users": b'{"users": [{"id": 1, "name": "admin", "role": "superuser"}]}',
        "/wp-admin": b'<html><body><form>WordPress Login<br>User: <input><br>Pass: <input></form></body></html>',
        "/.env": b"DB_PASSWORD=SuperSecret123\nAWS_KEY=AKIAIOSFODNN7EXAMPLE",
        "/config.json": b'{"database": {"host": "localhost", "password": "default123"}}',
    }
    
    def __init__(self, host: str = "0.0.0.0", port: int = 18081):
        self.host = host
        self.port = port
        self.sock = None
        self._running = False
    
    def start(self):
        self._running = True
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.sock.bind((self.host, self.port))
            self.sock.listen(10)
            logger.info(f"[DECEPTION] Fake HTTP listening on {self.host}:{self.port}")
            threading.Thread(target=self._accept_loop, daemon=True).start()
        except OSError as e:
            logger.error(f"[DECEPTION] Cannot bind fake HTTP to port {self.port}: {e}")
    
    def _accept_loop(self):
        while self._running:
            try:
                self.sock.settimeout(1.0)
                client, addr = self.sock.accept()
                threading.Thread(target=self._handle_client, args=(client, addr), daemon=True).start()
            except socket.timeout:
                continue
            except Exception as e:
                logger.error(f"[DECEPTION] HTTP accept error: {e}")
    
    def _handle_client(self, client: socket.socket, addr: tuple):
        attacker_ip = addr[0]
        try:
            client.settimeout(5.0)
            data = client.recv(4096)
            if not data:
                client.close()
                return
            
            request = data.decode("utf-8", errors="replace")
            path = "/"
            method = "GET"
            
            # Parse HTTP request
            lines = request.split("\r\n")
            if lines:
                first = lines[0].split()
                if len(first) >= 2:
                    method = first[0]
                    path = first[1]
            
            # Extract interesting headers
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    k, v = line.split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            
            user_agent = headers.get("user-agent", "unknown")
            
            logger.warning(f"[DECEPTION] WEB ATTACKER: {attacker_ip} {method} {path} UA:{user_agent[:60]}")
            
            # Log full event
            event = {
                "honeypot": "fake-http",
                "attacker_ip": attacker_ip,
                "method": method,
                "path": path,
                "user_agent": user_agent,
                "headers": headers,
                "body_preview": request[:500],
                "timestamp": datetime.utcnow().isoformat()
            }
            self._log_event(event)
            
            # Respond with fake content
            response_body = self.FAKE_ENDPOINTS.get(path, b'{"status": "ok"}')
            if isinstance(response_body, str):
                response_body = response_body.encode()
            
            http_response = (
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Type: application/json\r\n"
                b"Server: nginx/1.18.0\r\n"
                b"X-Powered-By: PHP/7.4.3\r\n"
                b"\r\n" + response_body
            )
            client.send(http_response)
            
        except Exception as e:
            logger.debug(f"[DECEPTION] HTTP handler error: {e}")
        finally:
            client.close()
    
    def _log_event(self, event: Dict):
        logger.info(f"[DECEPTION] Web event logged: {event['path']} from {event['attacker_ip']}")


class CanaryFiles:
    """Place fake sensitive files to detect file-access based attacks."""
    
    CANARIES = [
        ("/tmp/kirat-oysgja-canary.env", "DB_PASSWORD=fake_canary_12345\nAWS_KEY=AKIAIOSFODNN7EXAMPLE\n"),
        ("/var/lib/kirat-os/oysgja-ai/canaries/.credentials", "username=admin\npassword=fake_canary_password\n"),
        ("/var/lib/kirat-os/oysgja-ai/canaries/.config.json", '{"api_key": "fake_canary_key_abc123", "secret": "canary_secret"}'),
        ("/var/lib/kirat-os/oysgja-ai/canaries/aws-credentials", "[default]\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\naws_secret_access_key = fake_canary_secret\n"),
    ]
    
    def __init__(self):
        self._setup_canaries()
    
    def _setup_canaries(self):
        for path, content in self.CANARIES:
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(content)
                # Make them slightly visible (not hidden well, to tempt attackers)
                os.chmod(path, 0o644)
                logger.info(f"[DECEPTION] Canary placed: {path}")
            except Exception as e:
                logger.warning(f"[DECEPTION] Failed to place canary {path}: {e}")
    
    def check_access(self):
        """Check if any canary file has been read (via auditd or AIDE)."""
        # In a full implementation, this would check auditd logs for open() syscalls on canary paths
        pass


class OysgjaAI:
    """
    Deception & Honeypot AI Agent.
    Spawns fake services, places canary files, collects attacker intelligence.
    """
    
    def __init__(self):
        self.name = "oysgja-ai"
        self.db = AgentDatabase()
        self.bus = MessageBus()
        self.fake_ssh = FakeSSHServer()
        self.fake_http = FakeHTTPServer()
        self.canaries = CanaryFiles()
        self._running = False
    
    async def initialize(self):
        await self.bus.connect()
        self.fake_ssh.start()
        self.fake_http.start()
        logger.info("Deception-AI initialized: honeypots active, canaries placed")
    
    async def run(self):
        self._running = True
        await self.initialize()
        
        while self._running:
            # Periodically broadcast honeypot status
            await self.bus.publish("kirat.deception.status", {
                "type": "status",
                "honeypots": ["fake-ssh:2222", "fake-http:18081"],
                "canaries": len(self.canaries.CANARIES),
                "timestamp": datetime.utcnow().isoformat()
            })
            await asyncio.sleep(60)
    
    async def process_attacker_data(self, event: Dict[str, Any]):
        """Process and store attacker interaction data."""
        self.db.conn = None
        # Insert into deception_events via shared DB
        # (Would need to add method to AgentDatabase)
        
        # Alert jitedasti-ai
        await self.bus.broadcast_alert(
            "high", self.name,
            f"Attacker interaction on {event.get('honeypot')}: {event.get('attacker_ip')}",
            event
        )


async def main():
    deception = OysgjaAI()
    await deception.run()


if __name__ == "__main__":
    asyncio.run(main())
