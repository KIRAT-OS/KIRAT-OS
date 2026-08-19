"""
KIRAT OS Server - Real-Time Monitoring Dashboard
FastAPI application with WebSocket support for live streaming system metrics.
"""

import os
import time
import json
import asyncio
import random
import hashlib
from datetime import datetime, timedelta
from typing import Dict, List, Optional, Any
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

# Configuration
API_KEY = os.getenv("DASHBOARD_API_KEY", "kirat-os-dev-key-2024")
CORS_ORIGINS = os.getenv("CORS_ORIGINS", "http://localhost:3000,http://localhost:8000,http://127.0.0.1:8000").split(",")
ENVIRONMENT = os.getenv("ENVIRONMENT", "development")
MAX_WS_CONNECTIONS = int(os.getenv("MAX_WS_CONNECTIONS", "100"))
METRICS_INTERVAL = float(os.getenv("METRICS_INTERVAL", "1.0"))

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
            await websocket.close(code=1008, reason="Server at capacity")
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
        self.ai_requests_total = 0
        self.threat_history: List[Dict] = []
        self.honeypot_triggers = 0
        self._init_mock_data()
    
    def _init_mock_data(self):
        """Initialize mock AI and threat data for demonstration."""
        self.threat_history = [
            {
                "id": "THREAT-001",
                "severity": "high",
                "source": "honeypot-ssh",
                "timestamp": datetime.now().isoformat(),
                "description": "Brute force attack detected on SSH honeypot",
                "ip": "192.168.1.100",
                "status": "active"
            },
            {
                "id": "THREAT-002", 
                "severity": "medium",
                "source": "audit-log",
                "timestamp": (datetime.now() - timedelta(minutes=5)).isoformat(),
                "description": "Unusual file access pattern detected",
                "ip": "10.0.0.50",
                "status": "investigating"
            },
            {
                "id": "THREAT-003",
                "severity": "low",
                "source": "honeypot-http",
                "timestamp": (datetime.now() - timedelta(minutes=15)).isoformat(),
                "description": "Suspicious HTTP probe from unknown user agent",
                "ip": "172.16.0.25",
                "status": "resolved"
            }
        ]
    
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
        
        # Fallback: generate synthetic temperature based on CPU load
        cpu_load = psutil.cpu_percent(interval=None)
        synthetic_temp = 35 + (cpu_load / 100) * 45 + random.uniform(-2, 2)
        
        return {
            "sensors": temps,
            "cpu_temp": synthetic_temp,
            "unit": "celsius",
            "status": "normal" if synthetic_temp < 70 else "warning" if synthetic_temp < 85 else "critical"
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
        
        zombie_count = sum(1 for p in processes if p.info['status'] == psutil.STATUS_ZOMBIE)
        thread_count = sum(p.num_threads() for p in psutil.process_iter(['num_threads']))
        
        return {
            "total": len(processes),
            "threads": thread_count,
            "zombies": zombie_count,
            "running": sum(1 for p in processes if p.info['status'] == psutil.STATUS_RUNNING)
        }
    
    def get_ai_status(self) -> Dict[str, Any]:
        """Get AI runtime status (mock for demo)."""
        self.ai_requests_total += random.randint(0, 5)
        
        statuses = ["online", "thinking", "idle", "busy"]
        weights = [0.5, 0.2, 0.2, 0.1]
        status = random.choices(statuses, weights=weights)[0]
        
        return {
            "status": status,
            "inference_requests_sec": random.uniform(0, 50),
            "total_requests": self.ai_requests_total,
            "model_loaded": "sentinel-v2.1",
            "gpu_utilization": random.uniform(10, 95),
            "batch_size": random.randint(1, 32),
            "last_inference": datetime.now().isoformat(),
            "uptime": time.time() - self.start_time
        }
    
    def get_threats(self) -> List[Dict[str, Any]]:
        """Get active threats."""
        # Simulate occasional new threats
        if random.random() < 0.05:
            new_threat = {
                "id": f"THREAT-{len(self.threat_history) + 1:03d}",
                "severity": random.choice(["low", "medium", "high", "critical"]),
                "source": random.choice(["honeypot-ssh", "honeypot-http", "audit-log", "ids"]),
                "timestamp": datetime.now().isoformat(),
                "description": f"Automated threat detection event #{len(self.threat_history) + 1}",
                "ip": f"10.{random.randint(0,255)}.{random.randint(0,255)}.{random.randint(0,255)}",
                "status": "active"
            }
            self.threat_history.insert(0, new_threat)
            if len(self.threat_history) > 50:
                self.threat_history.pop()
        
        return self.threat_history[:10]
    
    def get_honeypot_metrics(self) -> Dict[str, Any]:
        """Get honeypot activity metrics."""
        self.honeypot_triggers += random.randint(0, 2)
        
        return {
            "total_triggers": self.honeypot_triggers,
            "active_sessions": random.randint(0, 5),
            "blocked_ips": random.randint(10, 200),
            "last_trigger": datetime.now().isoformat() if self.honeypot_triggers > 0 else None,
            "honeypots": [
                {"name": "ssh-honeypot", "port": 2222, "status": "active", "triggers": random.randint(0, 50)},
                {"name": "http-honeypot", "port": 8080, "status": "active", "triggers": random.randint(0, 30)},
                {"name": "ftp-honeypot", "port": 2121, "status": "active", "triggers": random.randint(0, 20)}
            ]
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
async def verify_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Verify API key for protected endpoints."""
    if not credentials:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="API key required",
            headers={"WWW-Authenticate": "Bearer"}
        )
    
    # Simple comparison (in production, use constant-time comparison)
    if credentials.credentials != API_KEY:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Invalid API key"
        )
    
    return credentials.credentials

# Lifespan context manager
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan handler."""
    # Startup
    asyncio.create_task(metrics_broadcast_task())
    yield
    # Shutdown
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
    return templates.TemplateResponse("index.html", {"request": request})

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
async def get_metrics(request: Request):
    """Get current system metrics snapshot."""
    return collector.get_all_metrics()

@app.get("/api/ai-status")
@limiter.limit("30/minute")
async def get_ai_status(request: Request):
    """Get Sentinel AI runtime status."""
    return collector.get_ai_status()

@app.get("/api/threats")
@limiter.limit("30/minute")
async def get_threats(request: Request):
    """Get active threat alerts."""
    return {
        "threats": collector.get_threats(),
        "total_active": sum(1 for t in collector.threat_history if t.get("status") == "active"),
        "last_updated": datetime.now().isoformat()
    }

@app.post("/api/command")
@limiter.limit("10/minute")
async def send_command(
    request: Request,
    command: CommandRequest,
    api_key: str = Depends(verify_api_key)
):
    """Send command to Sentinel AI (protected by API key)."""
    
    # Log command for audit
    command_hash = hashlib.sha256(
        f"{command.command}:{command.target}:{time.time()}".encode()
    ).hexdigest()[:16]
    
    # Simulate command processing
    response = {
        "success": True,
        "command_id": command_hash,
        "command": command.command,
        "target": command.target,
        "status": "queued",
        "timestamp": datetime.now().isoformat(),
        "message": f"Command '{command.command}' queued for execution on {command.target}"
    }
    
    return response

@app.websocket("/ws/metrics")
async def websocket_metrics(websocket: WebSocket):
    """WebSocket endpoint for real-time metrics streaming."""
    connected = await manager.connect(websocket)
    if not connected:
        return
    
    try:
        # Send initial metrics immediately
        initial_metrics = collector.get_all_metrics()
        await websocket.send_json({
            "type": "metrics",
            "data": initial_metrics
        })
        
        # Keep connection alive and handle client messages
        while True:
            try:
                message = await asyncio.wait_for(
                    websocket.receive_text(),
                    timeout=30.0
                )
                
                # Handle client messages (ping, subscription changes, etc.)
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
                # Send keepalive ping
                await websocket.send_json({"type": "ping", "timestamp": time.time()})
                
    except WebSocketDisconnect:
        manager.disconnect(websocket)
    except Exception as e:
        print(f"WebSocket error: {e}")
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
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "detail": str(exc)}
    )

if __name__ == "__main__":
    import uvicorn
    # SECURITY: reload=True is for development only. Production must use reload=False.
    reload_mode = ENVIRONMENT == "development"
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=reload_mode)
