import asyncio
import importlib.util
import os
from pathlib import Path
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect as WebSocketDenialResponse


ROOT = Path(__file__).resolve().parents[1]
os.environ["SENTINEL_API_KEY"] = "sentinel-test-secret"
spec = importlib.util.spec_from_file_location("sentinel_main_real", ROOT / "sentinel-core" / "main-real.py")
sentinel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sentinel)


class FakeSentinel:
    def get_status(self):
        return {"running": True}


@pytest.fixture
def client():
    sentinel._sentinel = FakeSentinel()
    client = TestClient(sentinel.app)
    yield client
    client.close()


def auth(key="sentinel-test-secret"):
    return {"Authorization": f"Bearer {key}"}


def test_health_is_public_and_minimal(client):
    response = client.get("/health")
    assert response.status_code == 200
    assert set(response.json()) == {"status", "version"}


def test_http_routes_fail_closed_when_key_unset(client, monkeypatch):
    monkeypatch.setattr(sentinel, "SENTINEL_API_KEY", "")
    requests = [
        ("get", "/status", None),
        ("post", "/chat", {"message": "hello"}),
        ("post", "/execute", {"command": "uptime", "reason": "health check"}),
        ("post", "/analyze-threat", {"threat_id": "1", "severity": "low", "source": "test", "description": "test"}),
    ]
    for method, path, body in requests:
        response = getattr(client, method)(path, json=body) if body else getattr(client, method)(path)
        assert response.status_code == 503, path


def test_status_requires_valid_bearer(client):
    assert client.get("/status").status_code == 401
    assert client.get("/status", headers=auth("wrong")).status_code == 403
    response = client.get("/status", headers=auth())
    assert response.status_code == 200
    assert response.json() == {"running": True}


def test_websocket_requires_key_and_supports_ping(client):
    with pytest.raises(WebSocketDenialResponse):
        with client.websocket_connect("/ws"):
            pass
    with client.websocket_connect("/ws", headers=auth()) as websocket:
        websocket.send_json({"type": "ping"})
        assert websocket.receive_json() == {"type": "pong"}


def test_command_parser_rejects_shell_and_unlisted_argv():
    denied = [
        "uptime; id",
        "uptime && id",
        "uptime | cat",
        "echo $(id)",
        "echo `id`",
        "df -h > /tmp/out",
        "/bin/df -h",
        "df --human-readable",
        "unclosed '",
        "rm -rf /",
        "",
    ]
    for command in denied:
        with pytest.raises(ValueError):
            sentinel.parse_read_only_argv(command)
    assert sentinel.parse_read_only_argv('"df" "-h"') == ["df", "-h"]


def test_execute_denials_never_run_subprocess_or_raise_keyerror():
    core = sentinel.SentinelCore()
    with patch.object(sentinel.subprocess, "run") as run:
        result = asyncio.run(core.execute("uptime; id", "test denial"))
    run.assert_not_called()
    assert result["success"] is False
    assert result["approved"] is False
    assert result["reason"]
    assert result["returncode"] is None


def test_execute_uses_exact_argv_without_shell_or_llm():
    core = sentinel.SentinelCore()
    completed = sentinel.subprocess.CompletedProcess(["uptime"], 0, "ok\n", "")
    with patch.object(core.governance, "check_command") as llm_review, patch.object(
        sentinel.subprocess, "run", return_value=completed
    ) as run:
        result = asyncio.run(core.execute("uptime", "read-only health check"))
    llm_review.assert_not_called()
    run.assert_called_once_with(["uptime"], shell=False, capture_output=True, text=True, timeout=10)
    assert result["success"] is True
    assert result["stdout"] == "ok\n"


def test_default_bind_is_loopback():
    assert sentinel.API_HOST == "127.0.0.1"
