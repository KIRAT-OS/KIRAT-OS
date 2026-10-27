import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect as WebSocketDenialResponse


ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "dashboard"
os.environ["DASHBOARD_API_KEY"] = "dashboard-test-secret"
os.chdir(DASHBOARD)
spec = importlib.util.spec_from_file_location("dashboard_main_security", DASHBOARD / "main.py")
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)


@pytest.fixture
def client():
    dashboard.sessions.clear()
    client = TestClient(dashboard.app, base_url="https://testserver")
    yield client
    client.close()
    dashboard.sessions.clear()


def auth(key="dashboard-test-secret"):
    return {"Authorization": f"Bearer {key}"}


def create_session(client, key="dashboard-test-secret"):
    return client.post("/api/session", headers=auth(key))


def test_session_cookie_protects_read_endpoints_without_bearer(client):
    assert create_session(client).status_code == 200
    assert client.cookies.get(dashboard.SESSION_COOKIE_NAME)
    assert client.get("/api/session").status_code == 200
    assert client.get("/api/ai-status").status_code == 200


def test_session_cookie_is_random_short_lived_and_browser_protected(client):
    response = create_session(client)
    cookie = response.headers["set-cookie"]
    token = client.cookies.get(dashboard.SESSION_COOKIE_NAME)
    assert len(token) >= 40
    assert token in dashboard.sessions
    assert "HttpOnly" in cookie
    assert "Secure" in cookie
    assert "SameSite=strict" in cookie
    assert f"Max-Age={dashboard.SESSION_TTL_SECONDS}" in cookie
    assert response.headers["cache-control"] == "no-store"
    assert create_session(client).status_code == 200
    assert client.cookies.get(dashboard.SESSION_COOKIE_NAME) != token


def test_session_creation_requires_valid_bearer(client):
    assert client.post("/api/session").status_code == 401
    assert create_session(client, "wrong").status_code == 403
    assert not dashboard.sessions


def test_session_expiry_is_enforced_and_cleaned_up(client):
    create_session(client)
    token = client.cookies.get(dashboard.SESSION_COOKIE_NAME)
    dashboard.sessions[token] = dashboard.time.monotonic() - 1
    assert client.get("/api/session").status_code == 401
    assert token not in dashboard.sessions


def test_logout_revokes_session_and_expires_cookie(client):
    create_session(client)
    token = client.cookies.get(dashboard.SESSION_COOKIE_NAME)
    response = client.post("/api/logout")
    assert response.status_code == 200
    assert token not in dashboard.sessions
    assert client.get("/api/session").status_code == 401
    assert 'Max-Age=0' in response.headers["set-cookie"]


def test_no_hardcoded_fallback_key():
    assert dashboard.API_KEY == "dashboard-test-secret"
    assert dashboard.api_key_matches("dashboard-test-secret")
    assert not dashboard.api_key_matches("kirat-os-dev-key-2024")


def test_protected_http_routes_fail_closed_without_configuration(client, monkeypatch):
    monkeypatch.setattr(dashboard, "API_KEY", "")
    for path in ("/api/metrics", "/api/ai-status", "/api/threats"):
        assert client.get(path).status_code == 503
    assert client.post("/api/command", json={"command": "uptime"}).status_code == 503
    assert client.post("/api/session", headers=auth()).status_code == 503
    assert client.get("/api/health").status_code == 200


def test_metrics_requires_valid_key_and_preserves_psutil_shape(client):
    assert client.get("/api/metrics").status_code == 401
    assert client.get("/api/metrics", headers=auth("wrong")).status_code == 403
    response = client.get("/api/metrics", headers=auth())
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data["cpu"]["percent_average"], (int, float))
    assert isinstance(data["memory"]["total"], int)
    assert isinstance(data["disk"]["total"], int)
    assert isinstance(data["network"]["bytes_recv"], int)


def test_unavailable_integrations_do_not_emit_synthetic_operational_data(client):
    ai = client.get("/api/ai-status", headers=auth()).json()
    assert ai["available"] is False
    assert ai["status"] == "unavailable"
    assert ai["model_loaded"] is None
    assert ai["inference_requests_sec"] is None

    threats = client.get("/api/threats", headers=auth()).json()
    assert threats["available"] is False
    assert threats["threats"] == []
    assert threats["total_active"] is None

    honeypot = dashboard.collector.get_honeypot_metrics()
    assert honeypot["available"] is False
    assert honeypot["honeypots"] == []
    assert honeypot["total_triggers"] is None


def test_missing_temperature_sensor_is_unavailable_not_synthetic():
    with patch.object(dashboard.psutil, "sensors_temperatures", return_value={}, create=True):
        thermal = dashboard.collector.get_thermal_metrics()
    assert thermal["available"] is False
    assert thermal["cpu_temp"] is None
    assert thermal["status"] == "unavailable"


def test_command_is_not_falsely_queued(client):
    response = client.post("/api/command", json={"command": "uptime"}, headers=auth())
    assert response.status_code == 501
    assert "unavailable" in response.json()["error"]
    assert "command_id" not in response.json()


def test_same_origin_validation():
    websocket = SimpleNamespace(
        headers={"origin": "https://dashboard.example", "host": "dashboard.example"},
        url=SimpleNamespace(scheme="wss"),
    )
    assert dashboard.websocket_is_same_origin(websocket)
    websocket.headers["origin"] = "https://attacker.example"
    assert not dashboard.websocket_is_same_origin(websocket)
    websocket.headers.pop("origin")
    assert not dashboard.websocket_is_same_origin(websocket)


def test_websocket_requires_auth_and_same_origin(client):
    # Starlette 0.35's websocket_connect uses ws://testserver by default.
    origin = {"origin": "http://testserver"}
    with pytest.raises(WebSocketDenialResponse):
        with client.websocket_connect("/ws/metrics", headers=origin):
            pass
    with pytest.raises(WebSocketDenialResponse):
        with client.websocket_connect("/ws/metrics?api_key=dashboard-test-secret", headers=origin):
            pass
    with pytest.raises(WebSocketDenialResponse):
        with client.websocket_connect("/ws/metrics", headers={**origin, **auth(), "origin": "https://attacker.example"}):
            pass
    with client.websocket_connect("/ws/metrics", headers={**origin, **auth()}) as websocket:
        message = websocket.receive_json()
        assert message["type"] == "metrics"
        assert message["data"]["ai_status"]["status"] == "unavailable"


def test_websocket_accepts_http_only_session_cookie(client):
    create_session(client)
    token = client.cookies.get(dashboard.SESSION_COOKIE_NAME)
    headers = {
        "origin": "http://testserver",
        "cookie": f"{dashboard.SESSION_COOKIE_NAME}={token}",
    }
    with client.websocket_connect("/ws/metrics", headers=headers) as websocket:
        assert websocket.receive_json()["type"] == "metrics"


def test_production_docker_and_javascript_transport():
    dockerfile = (DASHBOARD / "Dockerfile").read_text(encoding="utf-8")
    javascript = (DASHBOARD / "static" / "js" / "dashboard.js").read_text(encoding="utf-8")
    assert "--reload" not in dockerfile
    assert "window.location.protocol === 'https:' ? 'wss:' : 'ws:'" in javascript
    assert "new WebSocket(WS_PATH)" in javascript
    assert "fetch('/api/session'" in javascript
    assert "kirat-os-dev-key-2024" not in javascript
    assert "sessionStorage" not in javascript
    assert "localStorage" not in javascript
    assert "?api_key=" not in javascript
    assert "encodeURIComponent(apiKey)" not in javascript
