"""Import-compatible wrapper for the hyphenated deployment source file."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys

_SOURCE = Path(__file__).with_name("quantum-engine.py")
_spec = spec_from_file_location("kirat_quantum_engine_impl", _SOURCE)
if _spec is None or _spec.loader is None:
    raise ImportError(f"Cannot load quantum engine from {_SOURCE}")
_impl = module_from_spec(_spec)
sys.modules[_spec.name] = _impl
_spec.loader.exec_module(_impl)

QuantumState = _impl.QuantumState
QuantumGateLibrary = _impl.QuantumGateLibrary
QuantumCircuit = _impl.QuantumCircuit
QuantumEntropyHarvester = _impl.QuantumEntropyHarvester
QuantumSafePipeline = _impl.QuantumSafePipeline
AIGovernance = _impl.AIGovernance
QuantumAINetwork = _impl.QuantumAINetwork
QuantumAIEngine = _impl.QuantumAIEngine
MAX_QUBITS = _impl.MAX_QUBITS
MAX_SHOTS = _impl.MAX_SHOTS
MAX_OPERATIONS = _impl.MAX_OPERATIONS

__all__ = [
    "QuantumState", "QuantumGateLibrary", "QuantumCircuit",
    "QuantumEntropyHarvester", "QuantumSafePipeline", "AIGovernance",
    "QuantumAINetwork", "QuantumAIEngine", "MAX_QUBITS", "MAX_SHOTS",
    "MAX_OPERATIONS",
]
