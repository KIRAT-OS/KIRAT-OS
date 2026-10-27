#!/usr/bin/env python3
"""Focused regression tests for KIRAT backup, first-boot, and RBAC hardening."""

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "ai-agents"))
from shared.privileged import PrivilegedExecutor

SIGNER = ROOT / "security/rbac/ed25519-sign.py"
EXECUTOR = (ROOT / "security/rbac/executor-run.sh").as_posix()
BACKUP = (ROOT / "scripts/backup-dr.sh").as_posix()
FIRST_BOOT = ROOT / "scripts/first-boot-wizard.sh"
USER_MODEL = ROOT / "security/rbac/user-model.sh"
if os.name == "nt":
    BASH = os.environ.get("BASH", "C:/Program Files/Git/bin/bash.exe")
else:
    BASH = os.environ.get("BASH", "/bin/bash")


def timestamp(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(command, **kwargs):
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


def msys_path(path):
    if os.name == "nt" and shutil.which("cygpath"):
        return subprocess.check_output(["cygpath", "-u", str(path)], text=True).strip()
    return str(path)


class EnvelopeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.rbac = self.base / "rbac"
        self.env = os.environ.copy()
        self.env["KIRAT_RBAC_DIR"] = self.rbac.as_posix()
        result = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "genkey"],
                     env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)

    def instruction(self, command="df -h"):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        return {
            "instruction_id": "inst-test-001",
            "issuer": "kirat-admin",
            "target": "kirat-ai-executor",
            "command": command,
            "issued_at": timestamp(now),
            "expiry": timestamp(now + timedelta(minutes=5)),
            "nonce": "0123456789abcdef0123456789abcdef",
        }

    def sign(self, instruction=None, max_age=None):
        instruction = instruction or self.instruction()
        path = self.base / "instruction.json"
        path.write_text(json.dumps(instruction), encoding="utf-8")
        env = self.env.copy()
        if max_age is not None:
            env["KIRAT_MAX_INSTRUCTION_AGE"] = str(max_age)
        result = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "sign", str(path)],
                     env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        return path

    def execute(self, path):
        return run([BASH, str(EXECUTOR), str(path)], env=self.env)

    def test_valid_envelope_executes_and_verifies(self):
        path = self.sign()
        verified = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "verify", str(path)],
                       env=self.env)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        executed = self.execute(path)
        self.assertEqual(executed.returncode, 0, executed.stderr)

    def test_tampered_signed_command_is_rejected(self):
        path = self.sign()
        envelope = json.loads(path.read_text(encoding="utf-8"))
        envelope["command"] = "free -h"
        path.write_text(json.dumps(envelope), encoding="utf-8")
        result = self.execute(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verification failed", result.stderr)

    def test_expiry_is_enforced(self):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        instruction = self.instruction()
        instruction["issued_at"] = timestamp(now - timedelta(seconds=1))
        instruction["expiry"] = timestamp(now + timedelta(seconds=5))
        path = self.sign(instruction)
        time.sleep(6)
        result = self.execute(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verification failed", result.stderr)

    def test_stale_issue_time_is_rejected_even_before_expiry(self):
        now = datetime.now(timezone.utc).replace(microsecond=0)
        instruction = self.instruction()
        instruction["issued_at"] = timestamp(now - timedelta(minutes=10))
        instruction["expiry"] = timestamp(now + timedelta(minutes=5))
        path = self.sign(instruction, max_age=1200)
        result = self.execute(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.rbac / "executed-ids/inst-test-001").exists())

    def test_replay_is_rejected_after_success(self):
        path = self.sign()
        first = self.execute(path)
        self.assertEqual(first.returncode, 0, first.stderr)
        second = self.execute(path)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("Duplicate instruction ID", second.stderr)

    def test_concurrent_replay_has_exactly_one_winner(self):
        path = self.sign()
        processes = [subprocess.Popen([BASH, str(EXECUTOR), str(path)], env=self.env,
                                      text=True, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE) for _ in range(2)]
        results = [process.communicate(timeout=30) + (process.returncode,)
                   for process in processes]
        self.assertEqual(sum(code == 0 for _, _, code in results), 1, results)
        self.assertEqual(sum(code != 0 and "Duplicate instruction ID" in err
                             for _, err, code in results), 1, results)

    def test_exact_allowlist_rejects_shell_suffix(self):
        path = self.sign(self.instruction("df -h; touch /tmp/must-not-exist"))
        result = self.execute(path)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exact allowlist", result.stderr)

    def test_missing_canonical_field_cannot_be_signed(self):
        instruction = self.instruction()
        del instruction["nonce"]
        path = self.base / "missing.json"
        path.write_text(json.dumps(instruction), encoding="utf-8")
        result = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "sign", str(path)],
                     env=self.env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("seven signed fields", result.stderr)


class AgentExecutorIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0,
                         "Root is required for the real canonical executor integration test")
    def test_signed_agent_request_passes_both_layers_and_replay_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            requests = base / "requests"
            requests.mkdir()
            env = os.environ.copy()
            env["KIRAT_RBAC_DIR"] = (base / "rbac").as_posix()
            env.pop("KIRAT_EXECUTOR_TARGET", None)
            generated = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "genkey"], env=env)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            now = datetime.now(timezone.utc).replace(microsecond=0)
            instruction = {
                "instruction_id": "galinja-integration-001",
                "issuer": "kirat-admin",
                "target": "galinja-ai",
                "command": "uptime",
                "issued_at": timestamp(now),
                "expiry": timestamp(now + timedelta(minutes=5)),
                "nonce": "abcdef0123456789abcdef0123456789",
            }
            request = requests / "galinja-ai-status.json"
            request.write_text(json.dumps(instruction), encoding="utf-8")
            signed = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "sign", str(request)], env=env)
            self.assertEqual(signed.returncode, 0, signed.stderr)

            with patch.dict(os.environ, env, clear=True):
                executor = PrivilegedExecutor("galinja-ai", EXECUTOR, str(requests))
                first = executor.execute_signed(request)
                self.assertTrue(first.success, first.message)
                replay = executor.execute_signed(request)
                self.assertFalse(replay.success)
                self.assertIn("Duplicate instruction ID", replay.message)

            wrong_target = dict(instruction)
            wrong_target.update({"instruction_id": "galinja-integration-002", "target": "unregistered-ai"})
            wrong_request = requests / "galinja-ai-wrong-target.json"
            wrong_request.write_text(json.dumps(wrong_target), encoding="utf-8")
            signed = run([os.environ.get("PYTHON", "python3"), str(SIGNER), "sign", str(wrong_request)], env=env)
            self.assertEqual(signed.returncode, 0, signed.stderr)
            rejected = run([BASH, str(EXECUTOR), str(wrong_request)], env=env)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Unexpected target", rejected.stderr)


class BackupTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gpg") and shutil.which("tar"),
                         "gpg and tar are required")
    def test_encrypted_artifact_verify_upload_and_safe_retention(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            home = base / "gnupg"
            backup_dir = base / "backups"
            home.mkdir(mode=0o700)
            env = os.environ.copy()
            env.update({"GNUPGHOME": msys_path(home), "BACKUP_DIR": msys_path(backup_dir),
                        "BACKUP_GPG_RECIPIENT": "backup@example.invalid",
                        "RETENTION_DAYS": "30"})
            generated = run([BASH, "-c",
                             "gpg --batch --pinentry-mode loopback --passphrase '' "
                             "--quick-generate-key 'KIRAT Test <backup@example.invalid>' "
                             "default default never"], env=env)
            self.assertEqual(generated.returncode, 0, generated.stderr)

            upload_log = base / "upload.log"
            bin_dir = base / "bin"
            bin_dir.mkdir()
            aws = bin_dir / "aws"
            aws.write_text("#!/bin/bash\nprintf '%s\\n' \"$*\" > \"$UPLOAD_LOG\"\n",
                           encoding="utf-8")
            aws.chmod(aws.stat().st_mode | stat.S_IXUSR)
            env.update({"PATH": str(bin_dir) + os.pathsep + env["PATH"],
                        "UPLOAD_LOG": str(upload_log),
                        "REMOTE_TARGET": "s3://example-backup-test"})
            backup = run([BASH, str(BACKUP), "--action", "backup"], env=env)
            self.assertEqual(backup.returncode, 0, backup.stderr + backup.stdout)
            artifacts = list(backup_dir.glob("*.tar.gz.gpg"))
            self.assertEqual(len(artifacts), 1)
            self.assertEqual(list(backup_dir.glob("*.tar.gz")), [])
            self.assertIn(".tar.gz.gpg", upload_log.read_text(encoding="utf-8"))
            self.assertNotIn(" sync ", upload_log.read_text(encoding="utf-8"))

            old = backup_dir / "kirat-backup-20000101T000000Z.tar.gz.gpg"
            unrelated = backup_dir / "do-not-delete.txt"
            old.write_bytes(b"old")
            unrelated.write_bytes(b"keep")
            ancient = time.time() - 40 * 86400
            os.utime(old, (ancient, ancient))
            second = run([BASH, str(BACKUP), "--action", "backup"], env=env)
            self.assertEqual(second.returncode, 0, second.stderr + second.stdout)
            self.assertFalse(old.exists())
            self.assertTrue(unrelated.exists())

            verify = run([BASH, str(BACKUP), "--action", "verify"], env=env)
            self.assertEqual(verify.returncode, 0, verify.stderr + verify.stdout)
            dr_test = run([BASH, str(BACKUP), "--action", "dr-test"], env=env)
            self.assertEqual(dr_test.returncode, 0, dr_test.stderr + dr_test.stdout)
            self.assertIn("full DR recoverability is NOT proven", dr_test.stdout)

            newest = max(backup_dir.glob("*.tar.gz.gpg"), key=lambda path: path.stat().st_mtime)
            corrupted = bytearray(newest.read_bytes())
            corrupted[-1] ^= 1
            newest.write_bytes(corrupted)
            rejected = run([BASH, str(BACKUP), "--action", "verify"], env=env)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("Authenticated decryption failed", rejected.stderr)

    def test_backup_requires_encryption_recipient(self):
        with tempfile.TemporaryDirectory() as temporary:
            env = os.environ.copy()
            env["BACKUP_DIR"] = temporary
            env.pop("BACKUP_GPG_RECIPIENT", None)
            result = run([BASH, str(BACKUP), "--action", "backup"], env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("plaintext backups are disabled", result.stderr)


class FirstBootAndLegacyTests(unittest.TestCase):
    def test_dns_validation_rejects_shell_and_malformed_names(self):
        source = FIRST_BOOT.read_text(encoding="utf-8")
        match = re.search(r"^valid_dns_name\(\) \{.*?^\}", source,
                          flags=re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(match)
        checks = match.group(0) + """
valid_dns_name localhost
valid_dns_name example.com
valid_dns_name a-b.example
! valid_dns_name 'example.com$(touch /tmp/pwned)'
! valid_dns_name 'example.com/reboot'
! valid_dns_name '-bad.example'
! valid_dns_name 'bad_name.example'
! valid_dns_name 'bad..example'
"""
        result = run([BASH, "-c", checks])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_first_boot_has_no_root_unlock_or_private_key_generation(self):
        source = FIRST_BOOT.read_text(encoding="utf-8")
        self.assertNotRegex(source, r"(?m)^\s*passwd\s*$")
        self.assertNotIn("ssh-keygen -t", source)
        self.assertIn("passwd -l root", source)
        self.assertIn("subjectAltName=DNS:", source)
        self.assertIn("TLS_CERT_DAYS:-30", source)

    def test_legacy_user_model_fails_when_run_or_sourced(self):
        direct = run([BASH, USER_MODEL.as_posix()])
        sourced = run([BASH, "-c", f"source '{USER_MODEL.as_posix()}'"])
        self.assertNotEqual(direct.returncode, 0)
        self.assertNotEqual(sourced.returncode, 0)
        source = USER_MODEL.read_text(encoding="utf-8")
        self.assertNotIn("shell=True", source)
        self.assertNotIn("KIRAT-ADMIN-SEED", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
