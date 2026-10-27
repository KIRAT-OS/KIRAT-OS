import os
import sys
from pathlib import Path

QUANTUM_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(QUANTUM_DIR))
os.environ.setdefault("KIRAT_QUANTUM_ADMIN_API_KEY", "test-admin-key-0123456789abcdef0123456789")
os.environ.setdefault("KIRAT_QUANTUM_READONLY_API_KEY", "test-readonly-key-0123456789abcdef012345")
