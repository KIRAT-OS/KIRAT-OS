#!/usr/bin/env python3
"""
sentinel-core/src/main.py
Minimal Sentinel Core service entrypoint.

This script is the userspace companion to the kirat-ai kernel module.
It provides:
  - A netlink listener for kernel events (OOM, thermal, panic alerts)
  - A simple HTTP health endpoint for systemd / container probes
  - Periodic system snapshot collection via /dev/kirat-ai
  - Basic signal handling for graceful shutdown

Intended to be run as a systemd service.
"""

import os
import sys
import time
import signal
import struct
import socket
import argparse
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler

# Configuration
DEFAULT_DEVICE = "/dev/kirat-ai"
DEFAULT_NETLINK_FAMILY = 31
DEFAULT_HTTP_PORT = 8080
SNAPSHOT_INTERVAL_SEC = 5

# Global shutdown flag
_shutdown_event = threading.Event()


class HealthHandler(BaseHTTPRequestHandler):
    """Minimal HTTP handler for systemd/container health probes."""

    def log_message(self, format, *args):
        # Suppress default logging to keep output clean
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}\n')
        else:
            self.send_response(404)
            self.end_headers()


def start_http_server(port: int):
    """Start a background HTTP server for health checks."""
    server = HTTPServer(("0.0.0.0", port), HealthHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"[sentinel] HTTP health endpoint on http://0.0.0.0:{port}/health")
    return server


def netlink_listener(family: int):
    """
    Listen for multicast netlink events from the kirat-ai kernel module.
    This is a best-effort listener; if netlink is unavailable we log and continue.
    """
    try:
        sock = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, family)
        # Bind to multicast group 1 (matches KIRAT_NL_MCGRP in kernel module)
        sock.bind((0, 1))
        sock.settimeout(1.0)
        print(f"[sentinel] Netlink listener started (family={family}, group=1)")
    except OSError as e:
        print(f"[sentinel] Netlink not available: {e}")
        return

    while not _shutdown_event.is_set():
        try:
            data, addr = sock.recvfrom(4096)
            if len(data) >= 4:
                event_type = struct.unpack_from("<I", data, 0)[0]
                payload = data[4:]
                print(f"[sentinel] Kernel event type={event_type:#x} len={len(payload)}")
        except socket.timeout:
            continue
        except OSError:
            break

    sock.close()
    print("[sentinel] Netlink listener stopped")


def snapshot_collector(device_path: str):
    """
    Periodically read system snapshot from /dev/kirat-ai.
    This keeps the kernel module's telemetry fresh and validates device access.
    """
    while not _shutdown_event.is_set():
        try:
            with open(device_path, "rb") as f:
                data = f.read(8192)
                if data:
                    # In a full implementation, parse JSON and forward to metrics backend
                    print(f"[sentinel] Snapshot collected ({len(data)} bytes)")
        except OSError as e:
            print(f"[sentinel] Snapshot read failed: {e}")

        _shutdown_event.wait(SNAPSHOT_INTERVAL_SEC)

    print("[sentinel] Snapshot collector stopped")


def signal_handler(signum, frame):
    """Handle SIGTERM/SIGINT for graceful shutdown under systemd."""
    print(f"[sentinel] Received signal {signum}, shutting down...")
    _shutdown_event.set()


def main():
    parser = argparse.ArgumentParser(description="Sentinel Core — KIRAT AI Userspace Bridge")
    parser.add_argument("--device", default=DEFAULT_DEVICE, help="Path to /dev/kirat-ai")
    parser.add_argument("--netlink-family", type=int, default=DEFAULT_NETLINK_FAMILY,
                        help="Netlink protocol family number")
    parser.add_argument("--http-port", type=int, default=DEFAULT_HTTP_PORT,
                        help="HTTP health probe port")
    args = parser.parse_args()

    # Validate device exists
    if not os.path.exists(args.device):
        print(f"[sentinel] WARNING: Device {args.device} not found. Kernel module may not be loaded.")

    # Register signal handlers for systemd integration
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    print("=" * 50)
    print(" Sentinel Core — KIRAT AI Userspace Bridge")
    print("=" * 50)

    # Start HTTP health endpoint
    http_server = start_http_server(args.http_port)

    # Start background threads
    threads = [
        threading.Thread(target=netlink_listener, args=(args.netlink_family,), daemon=True),
        threading.Thread(target=snapshot_collector, args=(args.device,), daemon=True),
    ]
    for t in threads:
        t.start()

    # Block until shutdown signal
    try:
        while not _shutdown_event.is_set():
            _shutdown_event.wait(1.0)
    except KeyboardInterrupt:
        _shutdown_event.set()

    # Graceful cleanup
    http_server.shutdown()
    for t in threads:
        t.join(timeout=2.0)

    print("[sentinel] Shutdown complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
