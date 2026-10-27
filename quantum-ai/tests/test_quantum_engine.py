import importlib.util
from pathlib import Path
import sys
import time

import numpy as np
import pytest

from quantum_engine import (
    MAX_QUBITS,
    QuantumAIEngine,
    QuantumCircuit,
    QuantumEntropyHarvester,
    QuantumGateLibrary,
    QuantumState,
)


def zero_state(qubits):
    amplitudes = np.zeros(1 << qubits, dtype=complex)
    amplitudes[0] = 1
    return QuantumState(qubits, amplitudes)


def test_import_wrappers_and_hyphenated_real_backend():
    import ecosystem_api  # noqa: F401
    path = Path(__file__).resolve().parents[1] / "quantum-engine-real.py"
    spec = importlib.util.spec_from_file_location("test_quantum_engine_real", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    result = module.RealQuantumCircuit(2, backend="numpy").h(0).cnot(0, 1).execute(200)
    assert set(result["counts"]) <= {"00", "11"}
    assert result["hardware"] is False


def test_hadamard_is_normalized_on_selected_qubit():
    state = zero_state(2).apply_gate(QuantumGateLibrary.hadamard(), [1])
    assert np.allclose(state.amplitudes, [1 / np.sqrt(2), 1 / np.sqrt(2), 0, 0])
    assert np.isclose(np.linalg.norm(state.amplitudes), 1)


def test_x_gate():
    assert QuantumCircuit(1).x(0).execute(100)["counts"] == {"1": 100}


def test_cnot_on_control_and_target():
    assert QuantumCircuit(2).x(0).cnot(0, 1).execute(100)["counts"] == {"11": 100}
    assert QuantumCircuit(2).cnot(0, 1).execute(100)["counts"] == {"00": 100}


def test_bell_circuit_only_returns_00_and_11():
    result = QuantumCircuit(2).h(0).cnot(0, 1).execute(2000)
    assert set(result["counts"]) == {"00", "11"}
    assert sum(result["counts"].values()) == 2000
    assert np.isclose(result["final_entropy"], 1.0)


def test_nonadjacent_multiqubit_gate_and_invalid_inputs():
    state = zero_state(3).apply_gate(QuantumGateLibrary.pauli_x(), [0])
    state = state.apply_gate(QuantumGateLibrary.cnot(), [0, 2])
    assert state.probability(0b101) == pytest.approx(1.0)
    with pytest.raises(ValueError):
        state.apply_gate(QuantumGateLibrary.cnot(), [0])
    with pytest.raises(ValueError):
        state.apply_gate(QuantumGateLibrary.hadamard(), [0, 0])
    with pytest.raises(ValueError):
        QuantumCircuit(MAX_QUBITS + 1)


def test_engine_start_stop_and_entropy_progress():
    engine = QuantumAIEngine()
    engine.start()
    engine.start()
    assert engine._running
    assert engine.entropy._running
    assert len(engine.entropy.harvest(32)) == 32
    time.sleep(0.06)
    assert engine.entropy.pool_index > 0
    engine.stop()
    engine.stop()
    assert not engine._running
    assert not engine.entropy._running
    assert engine.entropy._harvest_thread is None


def test_entropy_bounds_and_continuous_restart():
    harvester = QuantumEntropyHarvester(pool_size=64)
    with pytest.raises(ValueError):
        harvester.harvest(65)
    harvester.start_continuous(interval_ms=10)
    harvester.stop()
    harvester.start_continuous(interval_ms=10)
    harvester.stop()
    assert len(harvester.harvest(16)) == 16
