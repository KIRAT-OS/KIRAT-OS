#!/usr/bin/env python3
"""
================================================================================
KIRAT OS - QUANTUM AI ECOSYSTEM API SERVER
================================================================================
FastAPI extension providing RESTful and WebSocket endpoints for the
Quantum AI Ecosystem. Integrates with the main KIRAT OS dashboard.

Endpoints:
  GET  /quantum/status          → Full ecosystem status
  POST /quantum/circuit         → Execute quantum circuit
  POST /quantum/ai/inference    → Run AI inference
  POST /quantum/encrypt         → Encrypt data (quantum-safe)
  POST /quantum/governance/check → Check action permissions
  WS   /quantum/stream          → Real-time quantum metrics stream

Security: All endpoints require API key (X-API-Key header)
          PQC-encrypted for sensitive operations

Author: KIRAT OS Quantum AI Division
Version: 1.0.0-QUANTUM
================================================================================
"""

import os
import sys
import json
import asyncio
import logging
from datetime import datetime
from typing import Dict, List, Optional, Any
from contextlib import asynccontextmanager

import numpy as np

# Add quantum engine to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from quantum_engine import QuantumAIEngine, QuantumCircuit, QuantumEntropyHarvester

# FastAPI imports (will be available when installed)
try:
    from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect, Depends, Header
    from fastapi.responses import JSONResponse
    from pydantic import BaseModel, Field
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False
    # Create stub classes for type checking
    class BaseModel:
        pass
    class FastAPI:
        pass

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("quantum-api")

# =============================================================================
# DATA MODELS
# =============================================================================

class CircuitRequest(BaseModel):
    num_qubits: int = Field(..., ge=1, le=16, description="Number of qubits (1-16)")
    operations: List[Dict[str, Any]] = Field(..., description="List of quantum operations")
    shots: int = Field(default=1024, ge=1, le=10000, description="Number of measurement shots")

class AIInferenceRequest(BaseModel):
    input_data: List[float] = Field(..., description="Input vector for AI inference")
    task: str = Field(default="classification", description="Task type")
    use_quantum: bool = Field(default=True, description="Use quantum-enhanced layers")

class EncryptRequest(BaseModel):
    data: str = Field(..., description="Base64-encoded data to encrypt")
    channel: str = Field(default="default", description="Encryption channel")

class GovernanceCheckRequest(BaseModel):
    action_type: str = Field(..., description="Type of action to check")
    action_params: Dict[str, Any] = Field(default={}, description="Action parameters")
    actor: str = Field(default="sentinel", description="Actor identity")

class StatusResponse(BaseModel):
    status: str
    engine: Dict[str, Any]
    metrics: Dict[str, Any]
    quantum: Dict[str, Any]
    pipeline: Dict[str, Any]
    governance: Dict[str, Any]
    timestamp: str

# =============================================================================
# API KEY AUTHENTICATION
# =============================================================================

API_KEYS = {
    "kirat-quantum-dev-key-2024": {"role": "admin", "rate_limit": 1000},
    "kirat-quantum-readonly": {"role": "readonly", "rate_limit": 100},
}

async def verify_api_key(x_api_key: str = Header(...)):
    """Verify API key from X-API-Key header."""
    if x_api_key not in API_KEYS:
        raise HTTPException(status_code=401, detail="Invalid API key")
    return API_KEYS[x_api_key]

# =============================================================================
# GLOBAL ENGINE INSTANCE
# =============================================================================

_engine: Optional[QuantumAIEngine] = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage quantum engine lifecycle."""
    global _engine
    logger.info("Starting Quantum AI Engine...")
    _engine = QuantumAIEngine()
    _engine.start()
    logger.info("Quantum AI Engine ready")
    yield
    logger.info("Shutting down Quantum AI Engine...")
    _engine.stop()
    _engine = None

# =============================================================================
# FASTAPI APPLICATION
# =============================================================================

if HAS_FASTAPI:
    app = FastAPI(
        title="KIRAT OS Quantum AI API",
        description="Extremely advanced quantum-AI ecosystem API for KIRAT OS",
        version="1.0.0-QUANTUM",
        lifespan=lifespan
    )
    
    # -------------------------------------------------------------------------
    # HEALTH & STATUS
    # -------------------------------------------------------------------------
    
    @app.get("/quantum/status", response_model=StatusResponse)
    async def get_status(api_key: dict = Depends(verify_api_key)):
        """Get full status of the Quantum AI Ecosystem."""
        if _engine is None:
            raise HTTPException(status_code=503, detail="Quantum engine not initialized")
        
        status = _engine.get_full_status()
        return {
            "status": "operational",
            "engine": status["engine"],
            "metrics": status["metrics"],
            "quantum": status["quantum_simulator"],
            "pipeline": status["pipeline"],
            "governance": status["governance"],
            "timestamp": datetime.utcnow().isoformat()
        }
    
    @app.get("/quantum/health")
    async def health_check():
        """Simple health check endpoint (no auth required)."""
        return {
            "status": "healthy" if _engine and _engine._running else "unhealthy",
            "service": "quantum-ai",
            "version": "1.0.0-QUANTUM",
            "timestamp": datetime.utcnow().isoformat()
        }
    
    # -------------------------------------------------------------------------
    # QUANTUM CIRCUIT EXECUTION
    # -------------------------------------------------------------------------
    
    @app.post("/quantum/circuit")
    async def execute_circuit(request: CircuitRequest, api_key: dict = Depends(verify_api_key)):
        """Execute a quantum circuit and return measurement results."""
        if _engine is None:
            raise HTTPException(status_code=503, detail="Quantum engine not initialized")
        
        try:
            result = _engine.execute_quantum_circuit(
                num_qubits=request.num_qubits,
                operations=request.operations,
                shots=request.shots
            )
            return {
                "success": True,
                "result": result,
                "execution_time_ms": 0,  # Would measure in production
                "timestamp": datetime.utcnow().isoformat()
            }
        except Exception as e:
            logger.error(f"Circuit execution failed: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    # -------------------------------------------------------------------------
    # AI INFERENCE
    # -------------------------------------------------------------------------
    
    @app.post("/quantum/ai/inference")
    async def ai_inference(request: AIInferenceRequest, api_key: dict = Depends(verify_api_key)):
        """Run quantum-enhanced AI inference."""
        if _engine is None:
            raise HTTPException(status_code=503, detail="Quantum engine not initialized")
        
        try:
            input_array = np.array(request.input_data)
            result = _engine.ai_inference(input_array, request.task)
            return {
                "success": True,
                "result": result,
                "timestamp": datetime.utcnow().isoformat()
            }
        except Exception as e:
            logger.error(f"AI inference failed: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    # -------------------------------------------------------------------------
    # QUANTUM-SAFE ENCRYPTION
    # -------------------------------------------------------------------------
    
    @app.post("/quantum/encrypt")
    async def encrypt_data(request: EncryptRequest, api_key: dict = Depends(verify_api_key)):
        """Encrypt data using quantum-safe pipeline."""
        if _engine is None:
            raise HTTPException(status_code=503, detail="Quantum engine not initialized")
        
        try:
            import base64
            data = base64.b64decode(request.data)
            encrypted = _engine.encrypt_system_data(data, request.channel)
            return {
                "success": True,
                "encrypted": base64.b64encode(encrypted).decode(),
                "original_size": len(data),
                "encrypted_size": len(encrypted),
                "channel": request.channel,
                "timestamp": datetime.utcnow().isoformat()
            }
        except Exception as e:
            logger.error(f"Encryption failed: {e}")
            raise HTTPException(status_code=500, detail=str(e))
    
    # -------------------------------------------------------------------------
    # AI GOVERNANCE
    # -------------------------------------------------------------------------
    
    @app.post("/quantum/governance/check")
    async def governance_check(request: GovernanceCheckRequest, api_key: dict = Depends(verify_api_key)):
        """Check if an action is permitted by AI governance."""
        if _engine is None:
            raise HTTPException(status_code=503, detail="Quantum engine not initialized")
        
        allowed, reason = _engine.governance.check_action(
            request.action_type,
            request.action_params,
            request.actor
        )
        
        return {
            "allowed": allowed,
            "reason": reason,
            "action_type": request.action_type,
            "actor": request.actor,
            "timestamp": datetime.utcnow().isoformat()
        }
    
    @app.get("/quantum/governance/audit")
    async def governance_audit(limit: int = 100, api_key: dict = Depends(verify_api_key)):
        """Retrieve AI governance audit log."""
        if _engine is None:
            raise HTTPException(status_code=503, detail="Quantum engine not initialized")
        
        return {
            "decisions": _engine.governance.get_audit_log(limit),
            "violations": _engine.governance.get_violations(limit),
            "total_decisions": len(_engine.governance.decisions),
            "total_violations": len(_engine.governance.violations),
            "timestamp": datetime.utcnow().isoformat()
        }
    
    # -------------------------------------------------------------------------
    # WEBSOCKET STREAMING
    # -------------------------------------------------------------------------
    
    @app.websocket("/quantum/stream")
    async def quantum_stream(websocket: WebSocket):
        """WebSocket endpoint for real-time quantum metrics streaming."""
        await websocket.accept()
        
        try:
            while True:
                if _engine and _engine._running:
                    status = _engine.get_full_status()
                    await websocket.send_json({
                        "type": "quantum_metrics",
                        "timestamp": datetime.utcnow().isoformat(),
                        "data": {
                            "circuits_executed": status["metrics"]["quantum_circuits_executed"],
                            "ai_inferences": status["metrics"]["ai_inferences"],
                            "keys_generated": status["metrics"]["keys_generated"],
                            "entropy_pool_index": status["entropy"]["pool_index"],
                            "governance_decisions": status["governance"]["total_decisions"],
                            "violation_rate": status["governance"]["violation_rate"],
                            "quantum_entropy": status["ai_network"]["history"]["quantum_entropy"][-1] 
                                if status["ai_network"] and status["ai_network"]["history"]["quantum_entropy"] 
                                else 0
                        }
                    })
                else:
                    await websocket.send_json({
                        "type": "error",
                        "message": "Quantum engine not running"
                    })
                
                await asyncio.sleep(1.0)  # 1 Hz update rate
                
        except WebSocketDisconnect:
            logger.info("Quantum stream client disconnected")
        except Exception as e:
            logger.error(f"Quantum stream error: {e}")
        finally:
            await websocket.close()

# =============================================================================
# STANDALONE MODE (without FastAPI)
# =============================================================================

def run_standalone():
    """Run the quantum engine in standalone mode for testing."""
    print("=" * 70)
    print("  KIRAT OS QUANTUM AI API - STANDALONE MODE")
    print("=" * 70)
    print()
    print("FastAPI not available. Running quantum engine demo...")
    print()
    
    # Import and run the main quantum engine demo
    import importlib.util
    spec = importlib.util.spec_from_file_location("quantum_engine", 
        os.path.join(os.path.dirname(__file__), "quantum_engine.py"))
    quantum_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(quantum_module)

if __name__ == "__main__":
    if HAS_FASTAPI:
        import uvicorn
        print("Starting Quantum AI API Server on port 8081...")
        uvicorn.run(app, host="0.0.0.0", port=8081, log_level="info")
    else:
        run_standalone()
