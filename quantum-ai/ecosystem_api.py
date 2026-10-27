"""ASGI import-compatible wrapper for ecosystem-api.py."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import sys

_SOURCE = Path(__file__).with_name("ecosystem-api.py")
_spec = spec_from_file_location("kirat_quantum_ecosystem_api_impl", _SOURCE)
if _spec is None or _spec.loader is None:
    raise ImportError(f"Cannot load quantum API from {_SOURCE}")
_impl = module_from_spec(_spec)
sys.modules[_spec.name] = _impl
_spec.loader.exec_module(_impl)

app = _impl.app
lifespan = _impl.lifespan
verify_api_key = _impl.verify_api_key
MAX_QUBITS = _impl.MAX_QUBITS
MAX_SHOTS = _impl.MAX_SHOTS
MAX_OPERATIONS = _impl.MAX_OPERATIONS

__all__ = [
    "app", "lifespan", "verify_api_key", "MAX_QUBITS", "MAX_SHOTS",
    "MAX_OPERATIONS",
]
