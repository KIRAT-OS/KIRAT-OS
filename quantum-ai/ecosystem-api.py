#!/usr/bin/env python3
"""Authenticated API for the local quantum simulator and experimental AI tools.

No endpoint claims access to quantum hardware. The legacy custom crypto transform
is disabled by default and is not ML-KEM or production cryptography.
"""

import asyncio
import base64
import binascii
import hmac
import logging
import os
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

import numpy as np
from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel, Field

from quantum_engine import MAX_OPERATIONS, MAX_QUBITS, MAX_SHOTS, QuantumAIEngine

logger = logging.getLogger("quantum-api")
API_PORT = 18082
EXECUTION_TIMEOUT_SECONDS = min(max(float(os.environ.get("KIRAT_QUANTUM_EXECUTION_TIMEOUT", "10")), 0.1), 60.0)
MAX_CONCURRENT_EXECUTIONS = min(max(int(os.environ.get("KIRAT_QUANTUM_MAX_CONCURRENCY", "2")), 1), 16)
CUSTOM_CRYPTO_ENABLED = os.environ.get("KIRAT_QUANTUM_ENABLE_EXPERIMENTAL_CRYPTO", "").lower() in {"1", "true", "yes"}
MAX_ENCRYPT_BYTES = 1024 * 1024
_execution_slots = asyncio.Semaphore(MAX_CONCURRENT_EXECUTIONS)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_api_keys() -> Dict[str, Dict[str, Any]]:
    """Load secrets only from the environment; empty configuration fails closed."""
    keys = {}
    for variable, role, default_limit in (
        ("KIRAT_QUANTUM_ADMIN_API_KEY", "admin", 120),
        ("KIRAT_QUANTUM_READONLY_API_KEY", "readonly", 60),
    ):
        value = os.environ.get(variable, "").strip()
        if value:
            if len(value) < 32:
                raise RuntimeError(f"{variable} must contain at least 32 characters")
            limit = int(os.environ.get(f"{variable}_RATE_LIMIT", default_limit))
            if not 1 <= limit <= 10000:
                raise RuntimeError(f"{variable}_RATE_LIMIT must be between 1 and 10000")
            keys[value] = {"role": role, "rate_limit": limit}
    return keys


API_KEYS = _load_api_keys()
_rate_windows: Dict[str, deque] = defaultdict(deque)


def _authenticate_secret(secret: Optional[str]) -> Dict[str, Any]:
    if not API_KEYS:
        raise HTTPException(status_code=503, detail="Quantum API authentication is not configured")
    if not secret:
        raise HTTPException(status_code=401, detail="Missing API key")
    for configured, identity in API_KEYS.items():
        if hmac.compare_digest(secret, configured):
            now = time.monotonic()
            window = _rate_windows[configured]
            while window and window[0] <= now - 60.0:
                window.popleft()
            if len(window) >= identity["rate_limit"]:
                raise HTTPException(status_code=429, detail="API key rate limit exceeded")
            window.append(now)
            return identity
    raise HTTPException(status_code=401, detail="Invalid API key")


async def verify_api_key(x_api_key: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    return _authenticate_secret(x_api_key)


async def require_admin(identity: Dict[str, Any] = Depends(verify_api_key)) -> Dict[str, Any]:
    if identity["role"] != "admin":
        raise HTTPException(status_code=403, detail="Admin role required")
    return identity


class CircuitRequest(BaseModel):
    num_qubits: int = Field(..., ge=1, le=MAX_QUBITS)
    operations: List[Dict[str, Any]] = Field(..., max_length=MAX_OPERATIONS)
    shots: int = Field(default=1024, ge=1, le=MAX_SHOTS)


class AIInferenceRequest(BaseModel):
    input_data: List[float] = Field(..., min_length=1, max_length=4096)
    task: str = Field(default="classification", max_length=64)
    use_quantum: bool = Field(default=True, description="Use quantum-inspired layers")


class EncryptRequest(BaseModel):
    data: str = Field(..., max_length=(MAX_ENCRYPT_BYTES * 4 // 3) + 16)
    channel: str = Field(default="default", min_length=1, max_length=64)


class GovernanceCheckRequest(BaseModel):
    action_type: str = Field(..., min_length=1, max_length=64)
    action_params: Dict[str, Any] = Field(default_factory=dict)
    actor: str = Field(default="sentinel", min_length=1, max_length=64)


class StatusResponse(BaseModel):
    status: str
    engine: Dict[str, Any]
    metrics: Dict[str, Any]
    quantum: Dict[str, Any]
    pipeline: Dict[str, Any]
    governance: Dict[str, Any]
    timestamp: str


_engine: Optional[QuantumAIEngine] = None


def get_engine() -> QuantumAIEngine:
    if _engine is None or not _engine._running:
        raise HTTPException(status_code=503, detail="Quantum engine not initialized")
    return _engine


async def _bounded_call(function, *args):
    """Run bounded synchronous work off the event loop with a timeout."""
    async with _execution_slots:
        try:
            return await asyncio.wait_for(
                run_in_threadpool(function, *args), timeout=EXECUTION_TIMEOUT_SECONDS
            )
        except asyncio.TimeoutError as exc:
            raise HTTPException(status_code=504, detail="Quantum operation timed out") from exc


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _engine
    engine = QuantumAIEngine()
    await run_in_threadpool(engine.start)
    _engine = engine
    try:
        yield
    finally:
        _engine = None
        await run_in_threadpool(engine.stop)


app = FastAPI(
    title="KIRAT OS Quantum AI API",
    description="Local quantum simulation and quantum-inspired AI; no quantum hardware.",
    version="1.1.0",
    lifespan=lifespan,
)


@app.get("/quantum/status", response_model=StatusResponse)
async def get_status(identity: Dict[str, Any] = Depends(verify_api_key)):
    status = get_engine().get_full_status()
    return {
        "status": "operational", "engine": status["engine"], "metrics": status["metrics"],
        "quantum": status["quantum_simulator"], "pipeline": status["pipeline"],
        "governance": status["governance"], "timestamp": _now(),
    }


@app.get("/quantum/health")
async def health_check():
    return {
        "status": "healthy" if _engine and _engine._running else "unhealthy",
        "service": "quantum-ai", "backend": "classical-simulation", "timestamp": _now(),
    }


@app.post("/quantum/circuit")
async def execute_circuit(request: CircuitRequest, identity: Dict[str, Any] = Depends(require_admin)):
    started = time.perf_counter()
    try:
        result = await _bounded_call(
            get_engine().execute_quantum_circuit,
            request.num_qubits, request.operations, request.shots,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {
        "success": True, "result": result,
        "execution_time_ms": round((time.perf_counter() - started) * 1000, 3),
        "timestamp": _now(),
    }


@app.post("/quantum/ai/inference")
async def ai_inference(request: AIInferenceRequest, identity: Dict[str, Any] = Depends(require_admin)):
    try:
        input_array = np.asarray(request.input_data, dtype=float)
        if not np.isfinite(input_array).all():
            raise ValueError("input_data must contain only finite numbers")
        result = await _bounded_call(get_engine().ai_inference, input_array, request.task)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {"success": True, "result": result, "timestamp": _now()}


@app.post("/quantum/encrypt")
async def encrypt_data(request: EncryptRequest, identity: Dict[str, Any] = Depends(require_admin)):
    if not CUSTOM_CRYPTO_ENABLED:
        raise HTTPException(
            status_code=404,
            detail="Disabled: experimental toy transform, not ML-KEM or production encryption",
        )
    try:
        data = base64.b64decode(request.data, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(status_code=422, detail="Invalid base64 data") from exc
    if len(data) > MAX_ENCRYPT_BYTES:
        raise HTTPException(status_code=413, detail="Data exceeds 1 MiB limit")
    encrypted = await _bounded_call(get_engine().encrypt_system_data, data, request.channel)
    return {
        "success": True,
        "experimental": True,
        "warning": "Toy transform only; not ML-KEM and never for production data",
        "encrypted": base64.b64encode(encrypted).decode(),
        "original_size": len(data), "encrypted_size": len(encrypted),
        "channel": request.channel, "timestamp": _now(),
    }


@app.post("/quantum/governance/check")
async def governance_check(request: GovernanceCheckRequest, identity: Dict[str, Any] = Depends(require_admin)):
    allowed, reason = await _bounded_call(
        get_engine().governance.check_action,
        request.action_type, request.action_params, request.actor,
    )
    return {
        "allowed": allowed, "reason": reason, "action_type": request.action_type,
        "actor": request.actor, "timestamp": _now(),
    }


@app.get("/quantum/governance/audit")
async def governance_audit(
    limit: int = Query(default=100, ge=1, le=1000),
    identity: Dict[str, Any] = Depends(verify_api_key),
):
    engine = get_engine()
    return {
        "decisions": engine.governance.get_audit_log(limit),
        "violations": engine.governance.get_violations(limit),
        "total_decisions": len(engine.governance.decisions),
        "total_violations": len(engine.governance.violations), "timestamp": _now(),
    }


@app.websocket("/quantum/stream")
async def quantum_stream(websocket: WebSocket):
    try:
        _authenticate_secret(websocket.headers.get("x-api-key"))
    except HTTPException as exc:
        await websocket.close(code=1008, reason=exc.detail)
        return
    await websocket.accept()
    try:
        while True:
            engine = get_engine()
            status = engine.get_full_status()
            history = status["ai_network"]["history"]["quantum_entropy"] if status["ai_network"] else []
            await websocket.send_json({
                "type": "quantum_metrics", "timestamp": _now(),
                "data": {
                    "circuits_executed": status["metrics"]["quantum_circuits_executed"],
                    "ai_inferences": status["metrics"]["ai_inferences"],
                    "keys_generated": status["metrics"]["keys_generated"],
                    "entropy_pool_index": status["entropy"]["pool_index"],
                    "governance_decisions": status["governance"]["total_decisions"],
                    "violation_rate": status["governance"]["violation_rate"],
                    "quantum_entropy": history[-1] if history else 0,
                    "hardware": False,
                },
            })
            await asyncio.sleep(1.0)
    except (WebSocketDisconnect, HTTPException):
        pass
    except Exception:
        logger.exception("Quantum stream failed")
        await websocket.close(code=1011)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=API_PORT, log_level="info")
