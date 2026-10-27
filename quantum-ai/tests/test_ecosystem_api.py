import pytest

pytest.importorskip("fastapi")
pytest.importorskip("httpx")
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import ecosystem_api as api

ADMIN = {"X-API-Key": "test-admin-key-0123456789abcdef0123456789"}
READONLY = {"X-API-Key": "test-readonly-key-0123456789abcdef012345"}


def test_auth_roles_lifecycle_and_disabled_crypto():
    with TestClient(api.app) as client:
        assert client.get("/quantum/health").status_code == 200
        assert client.get("/quantum/status").status_code == 401
        assert client.get("/quantum/status", headers=READONLY).status_code == 200
        circuit = {"num_qubits": 1, "operations": [{"gate": "X", "target": 0}], "shots": 10}
        assert client.post("/quantum/circuit", headers=READONLY, json=circuit).status_code == 403
        response = client.post("/quantum/circuit", headers=ADMIN, json=circuit)
        assert response.status_code == 200
        assert response.json()["result"]["counts"] == {"1": 10}
        encrypted = client.post("/quantum/encrypt", headers=ADMIN, json={"data": "aGVsbG8="})
        assert encrypted.status_code == 404
        assert "not ML-KEM" in encrypted.json()["detail"]
    assert api._impl._engine is None


def test_auth_fails_closed_without_environment_keys(monkeypatch):
    monkeypatch.setattr(api._impl, "API_KEYS", {})
    with TestClient(api.app) as client:
        assert client.get("/quantum/status", headers=ADMIN).status_code == 503


def test_websocket_requires_authentication_and_streams_with_key():
    with TestClient(api.app) as client:
        with pytest.raises(WebSocketDisconnect) as rejected:
            with client.websocket_connect("/quantum/stream"):
                pass
        assert rejected.value.code == 1008
        with client.websocket_connect("/quantum/stream", headers=READONLY) as stream:
            message = stream.receive_json()
            assert message["type"] == "quantum_metrics"
            assert message["data"]["hardware"] is False


def test_resource_limits_are_enforced_by_request_validation():
    with TestClient(api.app) as client:
        response = client.post(
            "/quantum/circuit", headers=ADMIN,
            json={"num_qubits": api.MAX_QUBITS + 1, "operations": [], "shots": 1},
        )
        assert response.status_code == 422
        response = client.post(
            "/quantum/circuit", headers=ADMIN,
            json={"num_qubits": 1, "operations": [], "shots": api.MAX_SHOTS + 1},
        )
        assert response.status_code == 422
