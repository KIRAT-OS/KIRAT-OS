"""
KIRAT OS Server - Real-Time Monitoring Dashboard
FastAPI application with WebSocket support for live streaming system metrics.
"""

import os
import time
import json
import asyncio
import hmac
import secrets
from datetime import datetime
from typing import Dict, List, Optional, Any
from urllib.parse import urlsplit
from contextlib import asynccontextmanager

import psutil
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Depends, Request, status
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field, validator
from slowapi import Limiter, _rate_limit_exceeded_handler
from slowapi.util import get_remote_address
from slowapi.errors import RateLimitExceeded
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Configuration. There is intentionally no development/default credential.
API_KEY = os.getenv("DASHBOARD_API_KEY", "")
CORS_ORIGINS = [origin.strip() for origin in os.getenv(
    "CORS_ORIGINS", "http://localhost:3000,http://localhost:8000,http://127.0.0.1:8000"
).split(",") if origin.strip()]
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
MAX_WS_CONNECTIONS = int(os.getenv("MAX_WS_CONNECTIONS", "50"))
METRICS_INTERVAL = float(os.getenv("METRICS_INTERVAL", "1.0"))
MAX_WS_MESSAGE_BYTES = 1024
SESSION_COOKIE_NAME = "kirat_dashboard_session"
SESSION_TTL_SECONDS = int(os.getenv("DASHBOARD_SESSION_TTL_SECONDS", "900"))
MAX_SESSIONS = int(os.getenv("DASHBOARD_MAX_SESSIONS", "1000"))
# Random token -> monotonic expiry. Sessions are intentionally memory-only.
sessions: Dict[str, float] = {}

# Rate limiter
limiter = Limiter(key_func=get_remote_address)

# Security
security = HTTPBearer(auto_error=False)

# Connection manager for WebSockets
class ConnectionManager:
    def __init__(self):
        self.active_connections: List[WebSocket] = []
        self.connection_count = 0
    
    async def connect(self, websocket: WebSocket):
        if len(self.active_connections) >= MAX_WS_CONNECTIONS:
            await websocket.close(code=1013, reason="Server at capacity")
            return False
        await websocket.accept()
        self.active_connections.append(websocket)
        self.connection_count += 1
        return True
    
    def disconnect(self, websocket: WebSocket):
        if websocket in self.active_connections:
            self.active_connections.remove(websocket)
    
    async def broadcast(self, message: dict):
        disconnected = []
        for connection in self.active_connections:
            try:
                await connection.send_json(message)
            except Exception:
                disconnected.append(connection)
        
        # Clean up disconnected clients
        for conn in disconnected:
            self.disconnect(conn)

manager = ConnectionManager()

# Pydantic models
class CommandRequest(BaseModel):
    command: str = Field(..., min_length=1, max_length=256, description="Command to send to Sentinel")
    target: Optional[str] = Field(default="sentinel", description="Target service")
    params: Optional[Dict[str, Any]] = Field(default={}, description="Command parameters")
    
    @validator('command')
    def validate_command(cls, v):
        forbidden = ['rm', 'dd', 'mkfs', 'format', 'del', 'delete']
        if any(f in v.lower() for f in forbidden):
            raise ValueError('Command contains forbidden keywords')
        return v.strip()

class MetricsSnapshot(BaseModel):
    timestamp: float
    cpu: Dict[str, Any]
    memory: Dict[str, Any]
    disk: Dict[str, Any]
    network: Dict[str, Any]
    thermal: Dict[str, Any]
    load: Dict[str, float]
    processes: Dict[str, int]
    ai_status: Dict[str, Any]
    threats: List[Dict[str, Any]]
    honeypot: Dict[str, Any]

class HealthResponse(BaseModel):
    status: str
    version: str
    uptime: float
    connections: int
    environment: str

# Metrics collector
class MetricsCollector:
    def __init__(self):
        self.start_time = time.time()
        self.network_last = psutil.net_io_counters()
        self.disk_last = psutil.disk_io_counters()
        self.last_time = time.time()
        # Integrations that do not exist remain empty/unavailable, never demo data.
        self.threat_history: List[Dict] = []
    
    def get_cpu_metrics(self) -> Dict[str, Any]:
        """Collect CPU metrics."""
        cpu_percent = psutil.cpu_percent(interval=None, percpu=True)
        cpu_freq = psutil.cpu_freq()
        cpu_count = psutil.cpu_count()
        
        return {
            "percent_per_core": cpu_percent,
            "percent_average": sum(cpu_percent) / len(cpu_percent) if cpu_percent else 0,
            "count": cpu_count,
            "freq_current": cpu_freq.current if cpu_freq else 0,
            "freq_max": cpu_freq.max if cpu_freq else 0,
            "freq_min": cpu_freq.min if cpu_freq else 0,
            "ctx_switches": psutil.cpu_stats().ctx_switches if hasattr(psutil, 'cpu_stats') else 0
        }
    
    def get_memory_metrics(self) -> Dict[str, Any]:
        """Collect memory metrics."""
        mem = psutil.virtual_memory()
        swap = psutil.swap_memory()
        
        return {
            "total": mem.total,
            "available": mem.available,
            "used": mem.used,
            "percent": mem.percent,
            "free": mem.free,
            "buffers": getattr(mem, 'buffers', 0),
            "cached": getattr(mem, 'cached', 0),
            "swap_total": swap.total,
            "swap_used": swap.used,
            "swap_percent": swap.percent
        }
    
    def get_disk_metrics(self) -> Dict[str, Any]:
        """Collect disk metrics."""
        disk = psutil.disk_usage('/')
        disk_io = psutil.disk_io_counters()
        
        current_time = time.time()
        time_delta = current_time - self.last_time
        
        read_bytes_sec = 0
        write_bytes_sec = 0
        
        if disk_io and self.disk_last:
            read_bytes_sec = max(0, (disk_io.read_bytes - self.disk_last.read_bytes) / time_delta)
            write_bytes_sec = max(0, (disk_io.write_bytes - self.disk_last.write_bytes) / time_delta)
            self.disk_last = disk_io
        
        return {
            "total": disk.total,
            "used": disk.used,
            "free": disk.free,
            "percent": disk.percent,
            "read_bytes_sec": read_bytes_sec,
            "write_bytes_sec": write_bytes_sec,
            "io_read_count": disk_io.read_count if disk_io else 0,
            "io_write_count": disk_io.write_count if disk_io else 0
        }
    
    def get_network_metrics(self) -> Dict[str, Any]:
        """Collect network metrics."""
        net_io = psutil.net_io_counters()
        
        current_time = time.time()
        time_delta = current_time - self.last_time
        
        rx_bytes_sec = 0
        tx_bytes_sec = 0
        
        if net_io and self.network_last:
            rx_bytes_sec = max(0, (net_io.bytes_recv - self.network_last.bytes_recv) / time_delta)
            tx_bytes_sec = max(0, (net_io.bytes_sent - self.network_last.bytes_sent) / time_delta)
            self.network_last = net_io
        
        return {
            "bytes_recv": net_io.bytes_recv if net_io else 0,
            "bytes_sent": net_io.bytes_sent if net_io else 0,
            "packets_recv": net_io.packets_recv if net_io else 0,
            "packets_sent": net_io.packets_sent if net_io else 0,
            "rx_bytes_sec": rx_bytes_sec,
            "tx_bytes_sec": tx_bytes_sec,
            "errors_in": net_io.errin if net_io else 0,
            "errors_out": net_io.errout if net_io else 0
        }
    
    def get_thermal_metrics(self) -> Dict[str, Any]:
        """Collect thermal metrics."""
        temps = {}
        try:
            if hasattr(psutil, 'sensors_temperatures'):
                sensors = psutil.sensors_temperatures()
                if sensors:
                    for name, entries in sensors.items():
                        temps[name] = [
                            {"label": e.label or f"{name}_{i}", "current": e.current, "high": e.high, "critical": e.critical}
                            for i, e in enumerate(entries)
                        ]
        except Exception:
            pass
        
        cpu_temp = None
        for name, entries in temps.items():
            if any(marker in name.lower() for marker in ("cpu", "coretemp", "k10temp", "zenpower")) and entries:
                cpu_temp = entries[0]["current"]
                break

        return {
            "available": cpu_temp is not None,
            "sensors": temps,
            "cpu_temp": cpu_temp,
            "unit": "celsius",
            "status": "unavailable" if cpu_temp is None else "normal" if cpu_temp < 70 else "warning" if cpu_temp < 85 else "critical"
        }
    
    def get_load_metrics(self) -> Dict[str, float]:
        """Collect system load averages."""
        try:
            load1, load5, load15 = os.getloadavg()
        except (OSError, AttributeError):
            # Windows fallback
            load1 = load5 = load15 = psutil.cpu_percent(interval=None) / 100 * psutil.cpu_count()
        
        return {
            "load1": load1,
            "load5": load5,
            "load15": load15
        }
    
    def get_process_metrics(self) -> Dict[str, int]:
        """Collect process metrics."""
        processes = list(psutil.process_iter(['pid', 'status']))

        # p.info may lack 'status' if the process vanished mid-scan — use .get() (KeyError fix)
        zombie_count = sum(1 for p in processes if p.info.get('status') == psutil.STATUS_ZOMBIE)
        thread_count = 0
        for p in psutil.process_iter(['num_threads']):
            try:
                thread_count += p.num_threads()
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                continue

        return {
            "total": len(processes),
            "threads": thread_count,
            "zombies": zombie_count,
            "running": sum(1 for p in processes if p.info.get('status') == psutil.STATUS_RUNNING)
        }
    
    def get_ai_status(self) -> Dict[str, Any]:
        """Report honestly until an authenticated AI metrics integration exists."""
        return {
            "available": False,
            "status": "unavailable",
            "detail": "AI runtime metrics integration is not configured",
            "inference_requests_sec": None,
            "total_requests": None,
            "model_loaded": None,
            "gpu_utilization": None,
            "batch_size": None,
            "last_inference": None,
            "uptime": None
        }

    def get_threats(self) -> List[Dict[str, Any]]:
        """No threat feed is configured; an empty list is not a synthetic feed."""
        return []

    def get_honeypot_metrics(self) -> Dict[str, Any]:
        """Report honeypot telemetry as unavailable rather than inventing it."""
        return {
            "available": False,
            "status": "unavailable",
            "detail": "Honeypot metrics integration is not configured",
            "total_triggers": None,
            "active_sessions": None,
            "blocked_ips": None,
            "last_trigger": None,
            "honeypots": []
        }
    
    def get_all_metrics(self) -> Dict[str, Any]:
        """Collect all metrics in one call."""
        self.last_time = time.time()
        
        return {
            "timestamp": self.last_time,
            "cpu": self.get_cpu_metrics(),
            "memory": self.get_memory_metrics(),
            "disk": self.get_disk_metrics(),
            "network": self.get_network_metrics(),
            "thermal": self.get_thermal_metrics(),
            "load": self.get_load_metrics(),
            "processes": self.get_process_metrics(),
            "ai_status": self.get_ai_status(),
            "threats": self.get_threats(),
            "honeypot": self.get_honeypot_metrics()
        }

collector = MetricsCollector()

# API Key validation
def api_key_matches(provided: Optional[str]) -> bool:
    """Fail closed and compare credentials in constant time."""
    return bool(API_KEY) and bool(provided) and hmac.compare_digest(
        provided.encode("utf-8"), API_KEY.encode("utf-8")
    )


async def verify_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Require the long-term API key only when creating a browser session."""
    if not API_KEY:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Dashboard API key is not configured")
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="API key required",
            headers={"WWW-Authenticate": "Bearer"}
        )
    if not api_key_matches(credentials.credentials):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid API key")
    return credentials.credentials


def cleanup_expired_sessions(now: Optional[float] = None) -> None:
    now = time.monotonic() if now is None else now
    for token, expiry in list(sessions.items()):
        if expiry <= now:
            sessions.pop(token, None)


def session_expiry(token: Optional[str]) -> Optional[float]:
    if not token:
        return None
    expiry = sessions.get(token)
    if expiry is None:
        return None
    if expiry <= time.monotonic():
        sessions.pop(token, None)
        return None
    return expiry


async def verify_access(
    request: Request,
    credentials: HTTPAuthorizationCredentials = Depends(security),
):
    """Accept a Bearer key for CLI or an expiring HttpOnly session for browsers."""
    if not API_KEY:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "Dashboard API key is not configured")
    if credentials:
        if not api_key_matches(credentials.credentials):
            raise HTTPException(status.HTTP_403_FORBIDDEN, detail="Invalid API key")
        return "bearer"
    if session_expiry(request.cookies.get(SESSION_COOKIE_NAME)) is not None:
        return "session"
    raise HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Valid session or Bearer API key required",
        headers={"WWW-Authenticate": "Bearer"},
    )


def websocket_is_same_origin(websocket: WebSocket) -> bool:
    """Reject cross-origin browser WebSockets (including missing Origin)."""
    origin = websocket.headers.get("origin")
    host = websocket.headers.get("host")
    if not origin or not host:
        return False
    parsed = urlsplit(origin)
    expected_scheme = "https" if websocket.url.scheme == "wss" else "http"
    return parsed.scheme == expected_scheme and parsed.netloc.lower() == host.lower() and not parsed.path.strip("/")


def websocket_is_authorized(websocket: WebSocket) -> bool:
    authorization = websocket.headers.get("authorization", "")
    if authorization.lower().startswith("bearer "):
        return api_key_matches(authorization[7:])
    return session_expiry(websocket.cookies.get(SESSION_COOKIE_NAME)) is not None

# Lifespan context manager
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Run and cleanly cancel the bounded metrics broadcaster."""
    task = asyncio.create_task(metrics_broadcast_task())
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass

# Create FastAPI app
app = FastAPI(
    title="KIRAT OS Server Dashboard",
    description="Real-time monitoring dashboard for KIRAT OS Server AI-native system",
    version="2.1.0",
    lifespan=lifespan
)

# Add rate limiter
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS if ENVIRONMENT == "development" else [o for o in CORS_ORIGINS if "localhost" not in o],
    allow_credentials=True,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
    max_age=600
)

# Static files and templates
app.mount("/static", StaticFiles(directory="static"), name="static")
templates = Jinja2Templates(directory="templates")

# Background task for broadcasting metrics
async def metrics_broadcast_task():
    """Broadcast metrics to all connected WebSocket clients."""
    while True:
        try:
            metrics = collector.get_all_metrics()
            await manager.broadcast({
                "type": "metrics",
                "data": metrics
            })
            await asyncio.sleep(METRICS_INTERVAL)
        except Exception as e:
            print(f"Error in metrics broadcast: {e}")
            await asyncio.sleep(1)

# Routes
@app.get("/", response_class=HTMLResponse)
async def dashboard(request: Request):
    """Serve the main dashboard page."""
    return templates.TemplateResponse(request=request, name="index.html")

@app.post("/api/session")
@limiter.limit("10/minute")
async def create_session(request: Request, _api_key: str = Depends(verify_api_key)):
    """Exchange a Bearer API key for a short-lived, server-side session."""
    cleanup_expired_sessions()
    if len(sessions) >= MAX_SESSIONS:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Session capacity reached")
    token = secrets.token_urlsafe(32)
    sessions[token] = time.monotonic() + SESSION_TTL_SECONDS
    response = JSONResponse(
        {"authenticated": True, "expires_in": SESSION_TTL_SECONDS},
        headers={"Cache-Control": "no-store"},
    )
    response.set_cookie(
        SESSION_COOKIE_NAME,
        token,
        max_age=SESSION_TTL_SECONDS,
        expires=SESSION_TTL_SECONDS,
        path="/",
        secure=True,
        httponly=True,
        samesite="strict",
    )
    return response


@app.get("/api/session")
async def session_status(_auth: str = Depends(verify_access)):
    """Allow the browser to reuse an existing valid cookie without prompting."""
    return JSONResponse({"authenticated": True}, headers={"Cache-Control": "no-store"})


@app.post("/api/logout")
async def logout(request: Request):
    """Revoke the server-side token and expire the browser cookie."""
    sessions.pop(request.cookies.get(SESSION_COOKIE_NAME), None)
    response = JSONResponse({"authenticated": False}, headers={"Cache-Control": "no-store"})
    response.delete_cookie(
        SESSION_COOKIE_NAME,
        path="/",
        secure=True,
        httponly=True,
        samesite="strict",
    )
    return response


@app.get("/api/health", response_model=HealthResponse)
@limiter.limit("60/minute")
async def health_check(request: Request):
    """Health check endpoint."""
    return HealthResponse(
        status="healthy",
        version="2.1.0",
        uptime=time.time() - collector.start_time,
        connections=len(manager.active_connections),
        environment=ENVIRONMENT
    )

@app.get("/api/metrics")
@limiter.limit("30/minute")
async def get_metrics(request: Request, _key: str = Depends(verify_access)):
    """Get current system metrics snapshot."""
    return collector.get_all_metrics()

@app.get("/api/ai-status")
@limiter.limit("30/minute")
async def get_ai_status(request: Request, _key: str = Depends(verify_access)):
    """Get Sentinel AI runtime status."""
    return collector.get_ai_status()

@app.get("/api/threats")
@limiter.limit("30/minute")
async def get_threats(request: Request, _key: str = Depends(verify_access)):
    """Return no events and an explicit unavailable state without a real feed."""
    return {
        "available": False,
        "status": "unavailable",
        "detail": "Threat metrics integration is not configured",
        "threats": [],
        "total_active": None,
        "last_updated": None
    }

@app.post("/api/command")
@limiter.limit("10/minute")
async def send_command(
    request: Request,
    command: CommandRequest,
    api_key: str = Depends(verify_access)
):
    """Never claim queueing without a real authenticated Sentinel integration."""
    raise HTTPException(
        status.HTTP_501_NOT_IMPLEMENTED,
        "Command execution is unavailable: no authenticated Sentinel integration is configured"
    )

@app.websocket("/ws/metrics")
async def websocket_metrics(websocket: WebSocket):
    """Authenticated, same-origin, bounded real-time metrics streaming."""
    if not API_KEY:
        await websocket.close(code=1008, reason="Dashboard API key is not configured")
        return
    if not websocket_is_same_origin(websocket):
        await websocket.close(code=1008, reason="Same-origin connection required")
        return
    if not websocket_is_authorized(websocket):
        await websocket.close(code=1008, reason="Invalid or expired session")
        return

    authorization = websocket.headers.get("authorization", "")
    browser_session_token = None if authorization else websocket.cookies.get(SESSION_COOKIE_NAME)
    connected = await manager.connect(websocket)
    if not connected:
        return

    try:
        initial_metrics = collector.get_all_metrics()
        await websocket.send_json({"type": "metrics", "data": initial_metrics})

        while True:
            if browser_session_token and session_expiry(browser_session_token) is None:
                await websocket.close(code=1008, reason="Session expired or revoked")
                break
            try:
                message = await asyncio.wait_for(websocket.receive_text(), timeout=30.0)
                if len(message.encode("utf-8")) > MAX_WS_MESSAGE_BYTES:
                    await websocket.close(code=1009, reason="Message too large")
                    break
                try:
                    data = json.loads(message)
                    msg_type = data.get("type", "")
                    if msg_type == "ping":
                        await websocket.send_json({"type": "pong", "timestamp": time.time()})
                    elif msg_type == "subscribe":
                        await websocket.send_json({"type": "ack", "message": "Subscribed to metrics stream"})
                    else:
                        await websocket.send_json({"type": "error", "message": "Unknown message type"})
                except json.JSONDecodeError:
                    await websocket.send_json({"type": "error", "message": "Invalid JSON"})
            except asyncio.TimeoutError:
                await websocket.send_json({"type": "ping", "timestamp": time.time()})
    except WebSocketDisconnect:
        pass
    finally:
        manager.disconnect(websocket)

# Error handlers
@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.detail, "status_code": exc.status_code}
    )

@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    return JSONResponse(status_code=500, content={"error": "Internal server error"})

if __name__ == "__main__":
    import uvicorn
    # SECURITY: reload=True is for development only. Production must use reload=False.
    reload_mode = ENVIRONMENT == "development"
    uvicorn.run("main:app", host="127.0.0.1", port=8080, reload=reload_mode)
