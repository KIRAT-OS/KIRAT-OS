#!/usr/bin/env python3
"""
================================================================================
KIRAT OS - QUANTUM AI ECOSYSTEM SERVICE
================================================================================
Systemd service wrapper for the Quantum AI Ecosystem.
Provides daemon management, auto-restart, and integration with KIRAT OS.

Usage:
    python3 quantum-service.py start    # Start the service
    python3 quantum-service.py stop     # Stop the service
    python3 quantum-service.py status   # Check status
    python3 quantum-service.py restart  # Restart the service

Systemd unit file: /etc/systemd/system/kirat-quantum-ai.service
================================================================================
"""

import os
import sys
import time
import signal
import subprocess
import json
import logging
from pathlib import Path

# Configuration
PID_FILE = "/var/run/kirat-quantum-ai.pid"
LOG_FILE = "/var/log/kirat-quantum-ai.log"
API_PORT = 18082  # Dedicated to Quantum AI; Oysgja uses 18081.
QUANTUM_DIR = Path("/opt/kirat-os/quantum-ai")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("quantum-service")

def get_pid() -> int:
    """Read PID from file."""
    try:
        with open(PID_FILE, 'r') as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0

def is_running(pid: int) -> bool:
    """Check if process is running."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False

def start_service():
    """Start the Quantum AI Ecosystem service."""
    pid = get_pid()
    if is_running(pid):
        print(f"Quantum AI service already running (PID: {pid})")
        return 0
    
    print("Starting KIRAT OS Quantum AI Ecosystem...")
    
    # Ensure directory exists
    QUANTUM_DIR.mkdir(parents=True, exist_ok=True)
    
    # Start the API server as daemon
    env = os.environ.copy()
    env["PYTHONPATH"] = str(QUANTUM_DIR)
    
    if not env.get("KIRAT_QUANTUM_ADMIN_API_KEY") and not env.get("KIRAT_QUANTUM_READONLY_API_KEY"):
        print("Refusing to start: configure KIRAT_QUANTUM_ADMIN_API_KEY and/or KIRAT_QUANTUM_READONLY_API_KEY")
        return 1

    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "ecosystem_api:app",
         "--host", "127.0.0.1", "--port", str(API_PORT),
         "--log-level", "info"],
        cwd=str(QUANTUM_DIR),
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True
    )
    
    # Write PID
    with open(PID_FILE, 'w') as f:
        f.write(str(proc.pid))
    
    print(f"Quantum AI service started (PID: {proc.pid})")
    print(f"API endpoint: http://localhost:{API_PORT}/quantum/")
    print(f"Health check: http://localhost:{API_PORT}/quantum/health")
    
    return 0

def stop_service():
    """Stop the Quantum AI Ecosystem service."""
    pid = get_pid()
    if not is_running(pid):
        print("Quantum AI service not running")
        if os.path.exists(PID_FILE):
            os.remove(PID_FILE)
        return 0
    
    print(f"Stopping Quantum AI service (PID: {pid})...")
    
    try:
        os.kill(pid, signal.SIGTERM)
        # Wait for graceful shutdown
        for _ in range(10):
            if not is_running(pid):
                break
            time.sleep(0.5)
        
        if is_running(pid):
            print("Force killing...")
            os.kill(pid, signal.SIGKILL)
        
        os.remove(PID_FILE)
        print("Quantum AI service stopped")
    except OSError as e:
        print(f"Error stopping service: {e}")
        return 1
    
    return 0

def get_status():
    """Get service status."""
    pid = get_pid()
    
    if is_running(pid):
        print(f"Quantum AI Service: RUNNING (PID: {pid})")
        print(f"API Port: {API_PORT}")
        print(f"PID File: {PID_FILE}")
        print(f"Log File: {LOG_FILE}")
        
        # Try to get API status
        try:
            import urllib.request
            with urllib.request.urlopen(f"http://localhost:{API_PORT}/quantum/health", timeout=2) as resp:
                data = json.loads(resp.read())
                print(f"API Health: {data.get('status', 'unknown')}")
                print(f"Version: {data.get('version', 'unknown')}")
        except Exception as e:
            print(f"API Status: unreachable ({e})")
    else:
        print("Quantum AI Service: STOPPED")
        if os.path.exists(PID_FILE):
            print(f"  (stale PID file: {PID_FILE})")
    
    return 0

def restart_service():
    """Restart the service."""
    stop_service()
    time.sleep(1)
    return start_service()

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 quantum-service.py {start|stop|restart|status}")
        return 1
    
    command = sys.argv[1].lower()
    
    if command == "start":
        return start_service()
    elif command == "stop":
        return stop_service()
    elif command == "restart":
        return restart_service()
    elif command == "status":
        return get_status()
    else:
        print(f"Unknown command: {command}")
        print("Usage: python3 quantum-service.py {start|stop|restart|status}")
        return 1

if __name__ == "__main__":
    sys.exit(main())
