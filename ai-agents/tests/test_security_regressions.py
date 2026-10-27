import asyncio
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR))

# The managed test runtime does not ship the agents' optional HTTP dependency.
if importlib.util.find_spec("httpx") is None:
    httpx_stub = types.ModuleType("httpx")
    httpx_stub.AsyncClient = object
    sys.modules["httpx"] = httpx_stub

from shared import AgentDatabase, MessageBus
from shared.privileged import PrivilegedExecutor


def load_agent(directory: str, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, AGENTS_DIR / directory / "main.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


galinja = load_agent("galinja-ai", "galinja_main")
aadhipati = load_agent("aadhipati-ai", "aadhipati_main")
oysgja = load_agent("oysgja-ai", "oysgja_main")


class IncidentPersistenceTests(unittest.TestCase):
    def test_claim_and_action_records_survive_reopen_and_deduplicate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "agents.db")
            db = AgentDatabase(path)
            self.assertTrue(db.claim_incident(42, "galinja-ai"))
            self.assertFalse(db.claim_incident(42, "galinja-ai"))
            self.assertTrue(db.record_incident_action(42, "galinja-ai", "isolate_and_wait", True, "wait"))
            self.assertTrue(db.record_incident_action(42, "galinja-ai", "isolate_and_wait", True, "wait"))
            reopened = AgentDatabase(path)
            self.assertFalse(reopened.claim_incident(42, "galinja-ai"))
            actions = reopened.get_incident_actions(42)
            self.assertEqual(len(actions), 1)
            self.assertEqual(actions[0]["success"], 1)

    def test_action_requires_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = AgentDatabase(os.path.join(tmp, "agents.db"))
            self.assertFalse(db.record_incident_action(7, "galinja-ai", "restart_service", False))


class FakeBus:
    def __init__(self):
        self.alerts = []

    async def broadcast_alert(self, *args):
        self.alerts.append(args)
        return True


class FakeForensics:
    def __init__(self):
        self.calls = 0

    def collect(self, category):
        self.calls += 1
        return "/var/lib/kirat-os/galinja-ai/forensics/test-case"


class FakeOllama:
    def __init__(self, response):
        self.response = response

    async def generate(self, *args, **kwargs):
        return {"response": self.response}


class GalinjaRegressionTests(unittest.IsolatedAsyncioTestCase):
    async def test_none_llm_response_is_safe_and_duplicate_is_not_reprocessed(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = AgentDatabase(os.path.join(tmp, "agents.db"))
            forensics = FakeForensics()
            agent_class = getattr(galinja, "Galinja" + "AI")
            agent = agent_class(
                db=db, bus=FakeBus(), ollama=FakeOllama(None),
                restorer=Mock(), forensics=forensics, executor=Mock(),
            )
            anomaly = {"id": 11, "severity": "high", "category": None, "description": None}
            self.assertTrue(await agent._respond_to_threat(anomaly))
            self.assertFalse(await agent._respond_to_threat(anomaly))
            self.assertEqual(forensics.calls, 1)
            self.assertEqual(len(db.get_incident_actions(11)), 1)

    async def test_destructive_action_is_disabled_without_executor_call(self):
        executor = Mock()
        firewall = galinja.FirewallEmergency(executor)
        with patch.dict(os.environ, {"KIRAT_OS_ENABLE_DESTRUCTIVE_ACTIONS": "false"}):
            self.assertFalse(firewall.isolate())
        executor.execute_configured.assert_not_called()


class PrivilegedExecutorTests(unittest.TestCase):
    def make_request(self, root: Path, signed=True) -> Path:
        request = root / "galinja-ai-isolate.json"
        payload = {"command": "ufw status verbose", "target": "galinja-ai"}
        if signed:
            payload.update({"signature_alg": "Ed25519", "admin_signature": "c2ln"})
        request.write_text(json.dumps(payload), encoding="utf-8")
        return request

    def test_nonroot_can_only_invoke_sudo_canonical_executor(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            request = self.make_request(root)
            executor_path = root / "executor-run.sh"
            executor_path.write_text("#!/bin/sh\n", encoding="utf-8")
            executor = PrivilegedExecutor("galinja-ai", str(executor_path), str(root))
            completed = subprocess.CompletedProcess([], 0, stdout="ok", stderr="")
            with patch("os.geteuid", return_value=1000, create=True), patch("subprocess.run", return_value=completed) as run:
                result = executor.execute_signed(request)
            self.assertTrue(result.success)
            command = run.call_args.args[0]
            self.assertEqual(command[:2], ["sudo", "-n"])
            self.assertEqual(command[2], str(executor_path))
            self.assertNotIn("ufw", command)

    def test_unsigned_request_is_denied_without_process_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            request = self.make_request(root, signed=False)
            executor = PrivilegedExecutor("galinja-ai", str(root / "missing-executor"), str(root))
            with patch("subprocess.run") as run:
                result = executor.execute_signed(request)
            self.assertFalse(result.success)
            self.assertEqual(result.status, "permission_denied")
            run.assert_not_called()


class MessageBusTests(unittest.IsolatedAsyncioTestCase):
    async def test_disconnected_publish_reports_not_delivered(self):
        bus = MessageBus()
        self.assertFalse(await bus.publish("kirat.alerts", {"type": "alert"}))

    async def test_redis_asyncio_is_used_for_real_publish(self):
        fake_redis = Mock()
        fake_redis.ping = Mock(return_value=asyncio.Future())
        fake_redis.ping.return_value.set_result(True)
        fake_redis.publish = Mock(return_value=asyncio.Future())
        fake_redis.publish.return_value.set_result(1)
        redis_module = types.ModuleType("redis")
        asyncio_module = types.ModuleType("redis.asyncio")
        asyncio_module.from_url = Mock(return_value=fake_redis)
        with patch.dict(sys.modules, {"redis": redis_module, "redis.asyncio": asyncio_module}):
            bus = MessageBus()
            self.assertTrue(await bus.connect())
            self.assertTrue(await bus.publish("kirat.alerts", {"type": "alert"}))
        asyncio_module.from_url.assert_called_once()
        fake_redis.publish.assert_called_once()

    async def test_subscription_receives_actual_pubsub_message(self):
        received = asyncio.Event()
        payloads = []

        class PubSub:
            def __init__(self):
                self.channels = None
                self.sent = False

            async def subscribe(self, *channels):
                self.channels = channels

            async def get_message(self, **kwargs):
                if not self.sent:
                    self.sent = True
                    return {"type": "message", "channel": "kirat.alerts", "data": '{"type":"alert"}'}
                await asyncio.sleep(0.01)
                return None

            async def close(self):
                return None

        pubsub = PubSub()
        fake_redis = Mock()
        fake_redis.pubsub = Mock(return_value=pubsub)

        async def close():
            return None
        fake_redis.close = close
        bus = MessageBus()
        bus._redis = fake_redis

        async def callback(channel, payload):
            payloads.append((channel, payload))
            received.set()

        await bus.subscribe("kirat.alerts", callback)
        await asyncio.wait_for(received.wait(), timeout=1)
        await bus.close()
        self.assertEqual(pubsub.channels, ("kirat.alerts",))
        self.assertEqual(payloads, [("kirat.alerts", {"type": "alert"})])


class AadhipatiAndConfigurationTests(unittest.IsolatedAsyncioTestCase):
    async def test_sensitive_action_checks_permission_before_executor(self):
        agent = aadhipati.AadhipatiAI.__new__(aadhipati.AadhipatiAI)
        agent.name = "aadhipati-ai"
        agent.permissions = Mock()
        agent.permissions.has_permission.return_value = False
        agent.executor = Mock()
        result = await agent._cmd_protect("galinja")
        self.assertFalse(result["success"])
        self.assertIn("Permission denied", result["message"])
        agent.executor.execute_configured.assert_not_called()

    async def test_status_uses_installed_systemd_unit_names(self):
        agent = aadhipati.AadhipatiAI.__new__(aadhipati.AadhipatiAI)
        with patch("subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as run:
            result = await agent._cmd_status("jitedasti")
        self.assertIn("jitedasti-ai", result["statuses"])
        self.assertEqual(run.call_args.args[0], ["systemctl", "is-active", "jitedasti-ai"])

    async def test_voice_disabled_is_explicit(self):
        agent = aadhipati.AadhipatiAI.__new__(aadhipati.AadhipatiAI)
        with patch.dict(os.environ, {"AADHIPATI_VOICE_ENABLED": "false"}):
            agent.voice = aadhipati.VoiceInterface()
            result = await agent.process_voice_command("unused.wav")
        self.assertIn("Voice command unavailable", result)
        self.assertIn("disabled", result)

    async def test_oysgja_port_and_canary_write_locations(self):
        self.assertEqual(oysgja.FakeHTTPServer().port, 18081)
        for path, _ in oysgja.CanaryFiles.CANARIES:
            self.assertTrue(path.startswith("/tmp/") or path.startswith("/var/lib/kirat-os/"))

    async def test_cli_has_no_legacy_core_unit_names(self):
        cli = (AGENTS_DIR / "kirat-agent").read_text(encoding="utf-8")
        self.assertIn("AGENTS=(jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai)", cli)
        self.assertNotIn("sudo ufw", cli)
        self.assertNotIn("sudo apt-get", cli)
        self.assertNotIn("sudo systemctl", cli)


if __name__ == "__main__":
    unittest.main()

