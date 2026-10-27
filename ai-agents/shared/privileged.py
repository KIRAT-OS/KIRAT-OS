"""Conservative access to KIRAT OS's canonical signed command executor.

Agents never invoke privileged operating-system commands directly.  The installer
or an administrator must provide an Ed25519-signed instruction JSON file and
whitelist its exact command in executor-run.sh.
"""

import json
import logging
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

logger = logging.getLogger("privileged-executor")

CANONICAL_EXECUTOR = "/opt/kirat-os/security/rbac/executor-run.sh"
DEFAULT_INSTRUCTION_DIR = "/var/lib/kirat-os/executor-requests"
DESTRUCTIVE_ACTIONS_ENV = "KIRAT_OS_ENABLE_DESTRUCTIVE_ACTIONS"


@dataclass
class ExecutionResult:
    success: bool
    status: str
    message: str
    returncode: Optional[int] = None


def destructive_actions_enabled() -> bool:
    """Destructive automation is opt-in; signed instructions are still required."""
    return os.getenv(DESTRUCTIVE_ACTIONS_ENV, "false").strip().lower() in {
        "1", "true", "yes", "on",
    }


class PrivilegedExecutor:
    def __init__(
        self,
        agent: str,
        executor_path: str = CANONICAL_EXECUTOR,
        instruction_dir: Optional[str] = None,
    ):
        self.agent = agent
        self.executor_path = executor_path
        self.instruction_dir = Path(
            instruction_dir
            or os.getenv("KIRAT_OS_SIGNED_INSTRUCTION_DIR", DEFAULT_INSTRUCTION_DIR)
        )

    def configured_instruction(self, action: str) -> Path:
        if not action or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for c in action):
            raise ValueError("Invalid signed-instruction action name")
        return self.instruction_dir / f"{self.agent}-{action}.json"

    def execute_configured(self, action: str, timeout: int = 60) -> ExecutionResult:
        try:
            path = self.configured_instruction(action)
        except ValueError as exc:
            return ExecutionResult(False, "invalid_request", str(exc))
        return self.execute_signed(path, timeout=timeout)

    def execute_signed(self, instruction_path, timeout: int = 60) -> ExecutionResult:
        """Run only a validated, pre-signed instruction through the canonical executor."""
        path = Path(instruction_path)
        try:
            root = self.instruction_dir.resolve(strict=True)
            if path.is_symlink():
                return ExecutionResult(False, "permission_denied", "Symbolic-link instructions are not allowed")
            resolved = path.resolve(strict=True)
            if resolved.parent != root or resolved.suffix != ".json" or not resolved.is_file():
                return ExecutionResult(False, "permission_denied", "Instruction must be a regular JSON file directly inside the signed-instruction directory")
            with resolved.open("r", encoding="utf-8") as handle:
                instruction = json.load(handle)
            if not isinstance(instruction, dict) or not instruction.get("command"):
                return ExecutionResult(False, "invalid_request", "Signed instruction has no command")
            if instruction.get("target") != self.agent:
                return ExecutionResult(False, "permission_denied", "Signed instruction target does not match the caller")
            if instruction.get("signature_alg") != "Ed25519" or not instruction.get("admin_signature"):
                return ExecutionResult(False, "permission_denied", "An Ed25519 admin signature is required")
        except FileNotFoundError:
            return ExecutionResult(
                False,
                "permission_denied",
                f"Signed instruction unavailable: {path}; administrator approval is required",
            )
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            return ExecutionResult(False, "invalid_request", f"Cannot read signed instruction: {exc}")

        if not os.path.isfile(self.executor_path):
            return ExecutionResult(False, "unavailable", f"Canonical signed executor not installed: {self.executor_path}")

        # A non-root agent may elevate only into the canonical executor, never
        # into the requested command itself. sudo -n must fail rather than prompt.
        if os.geteuid() == 0:
            command = [self.executor_path, str(resolved)]
        else:
            command = ["sudo", "-n", self.executor_path, str(resolved)]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return ExecutionResult(False, "failed", f"Signed executor failed: {exc}")

        output = (result.stderr or result.stdout or "").strip()
        if result.returncode != 0:
            status = "permission_denied" if "signature" in output.lower() or "permission" in output.lower() or "sudo" in output.lower() else "rejected"
            return ExecutionResult(False, status, output or f"Signed executor exited {result.returncode}", result.returncode)
        return ExecutionResult(True, "executed", output or "Signed instruction executed", result.returncode)
