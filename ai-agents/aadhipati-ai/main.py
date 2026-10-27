#!/usr/bin/env python3
"""
================================================================================
KIRAT OS — AADHIPATI AI (आधिपति)
Supreme CEO & AI Sovereign of KIRAT OS
================================================================================
The central intelligence that commands all other AI agents.

Capabilities:
  1. VOICE COMMAND INTERFACE — Understands Nepali + English commands
  2. AGENT ORCHESTRATION — Directs Jitedasti, Galinja, Oysgja, Suyarma, Papa
  3. AGENT FACTORY — Deploys new agents from templates
  4. PERMISSION MATRIX — Controls what each agent can do
  5. BUSINESS DASHBOARD — Empire-wide status and control
  6. NEPALI NLP — Natural language processing for Nepali commands

Voice Architecture:
  - Audio capture via microphone or file
  - Whisper model (supports Nepali natively)
  - Command classification
  - Execution routing to appropriate agent

Command Examples (Nepali + English):
  - "सबै एजेन्टको स्थिति देखाउनुहोस्" → Show all agent status
  - "जितेदास्ती, तुरुन्तै स्क्यान गर" → Jitedasti, scan immediately
  - "गलन्जा, आपतकालीन सुरक्षा सक्रिय गर" → Galinja, activate emergency protection
  - "Create a database monitoring agent" → Deploys new agent from template
  - "What is my security score?" → Reports overall posture
================================================================================
"""

import os
import sys
import json
import time
import wave
import asyncio
import logging
import tempfile
import subprocess
from datetime import datetime
from typing import Dict, List, Any, Optional, Callable
from dataclasses import dataclass, asdict

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from shared import OllamaClient, AgentDatabase, MessageBus
from shared.privileged import PrivilegedExecutor, destructive_actions_enabled

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger("aadhipati-ai")


# =============================================================================
# NEPALI VOCABULARY & TRANSLATION MAP
# =============================================================================

NEPALI_COMMAND_MAP = {
    # Agent names
    "जितेदास्ती": "jitedasti",
    "जिते": "jitedasti",
    "गलन्जा": "galinja",
    "गल": "galinja",
    "ओय्सग्जा": "oysgja",
    "ओय": "oysgja",
    "सुयर्मा": "suyarma",
    "सु": "suyarma",
    "पापा": "papa",
    "पा": "papa",
    "आधिपति": "aadhipati",
    
    # Actions
    "स्क्यान": "scan",
    "सुरक्षा": "protect",
    "स्थिति": "status",
    "रिपोर्ट": "report",
    "सुरु": "start",
    "रोक": "stop",
    "बनाउ": "create",
    "हटाउ": "remove",
    "अनुमति": "permission",
    "सहायता": "help",
    
    # Common
    "सबै": "all",
    "तुरुन्तै": "immediately",
    "अहिले": "now",
    "कृपया": "please",
    "धन्यवाद": "thank you",
}


class NepaliNLP:
    """
    Natural Language Processing for Nepali + English mixed commands.
    Uses rule-based translation + LLM fallback.
    """
    
    def __init__(self, ollama: OllamaClient):
        self.ollama = ollama
    
    def translate_nepali_tokens(self, text: str) -> str:
        """Replace known Nepali words with English equivalents."""
        words = text.lower().split()
        translated = []
        for word in words:
            # Remove punctuation
            clean = word.strip(".,!?;:")
            if clean in NEPALI_COMMAND_MAP:
                translated.append(NEPALI_COMMAND_MAP[clean])
            else:
                translated.append(word)
        return " ".join(translated)
    
    async def parse_command(self, text: str) -> Dict[str, Any]:
        """
        Parse a natural language command into structured action.
        Returns: {"agent": str, "action": str, "params": dict, "confidence": float}
        """
        # Step 1: Translate Nepali tokens
        translated = self.translate_nepali_tokens(text)
        
        # Step 2: Rule-based parsing
        parsed = self._rule_based_parse(translated)
        if parsed["confidence"] > 0.7:
            return parsed
        
        # Step 3: LLM fallback for complex commands
        return await self._llm_parse(translated)
    
    def _rule_based_parse(self, text: str) -> Dict[str, Any]:
        text_lower = text.lower()
        
        # Detect agent
        agent = None
        for name in ["jitedasti", "galinja", "oysgja", "suyarma", "papa", "aadhipati", "all"]:
            if name in text_lower:
                agent = name
                break
        
        # Detect action
        action = "status"  # Default
        if any(w in text_lower for w in ["scan", "स्क्यान", "खोज"]):
            action = "scan"
        elif any(w in text_lower for w in ["protect", "suraksha", "सुरक्षा", "lockdown", "बन्द"]):
            action = "protect"
        elif any(w in text_lower for w in ["start", "surur", "सुरु", "activate"]):
            action = "start"
        elif any(w in text_lower for w in ["stop", "rok", "रोक", "deactivate"]):
            action = "stop"
        elif any(w in text_lower for w in ["create", "banau", "बनाउ", "spawn", "deploy"]):
            action = "create"
        elif any(w in text_lower for w in ["report", "ripot", "रिपोर्ट", "score", "status", "स्थिति"]):
            action = "report"
        elif any(w in text_lower for w in ["permission", "anumati", "अनुमति", "access", "allow"]):
            action = "permission"
        
        # Confidence based on how many keywords matched
        confidence = 0.5
        if agent:
            confidence += 0.3
        if action != "status":
            confidence += 0.2
        
        return {
            "agent": agent or "all",
            "action": action,
            "params": {},
            "confidence": min(confidence, 1.0),
            "original": text
        }
    
    async def _llm_parse(self, text: str) -> Dict[str, Any]:
        prompt = f"""Parse this server administration command:

Command: "{text}"

Respond with ONLY valid JSON:
{{"agent": "name or all", "action": "scan|protect|start|stop|create|report|permission", "params": {{}}, "confidence": 0.0-1.0}}

Agents: jitedasti (threat hunter), galinja (healer), oysgja (deception), suyarma (oracle), papa (biometric), aadhipati (ceo), all"""
        
        result = await self.ollama.generate(prompt, system="You parse server commands into JSON only.", temperature=0.1, max_tokens=100)
        try:
            return json.loads(result.get("response", "{}"))
        except:
            return {"agent": "all", "action": "report", "params": {}, "confidence": 0.3, "original": text}


# =============================================================================
# VOICE RECOGNITION (Whisper)
# =============================================================================

class VoiceInterface:
    """
    Captures audio and transcribes using Whisper.
    Supports Nepali, English, and mixed Nepali-English (Hinglish/Nenglish).
    """
    
    def __init__(self, model_size: str = "base"):
        self.model_size = model_size
        self.unavailable_reason = ""
        self.last_error = ""
        self._whisper_available = self._check_whisper()

    def _check_whisper(self) -> bool:
        if os.getenv("AADHIPATI_VOICE_ENABLED", "false").lower() not in ("1", "true", "yes", "on"):
            self.unavailable_reason = "Voice interface is disabled; set AADHIPATI_VOICE_ENABLED=true after installing openai-whisper"
            logger.warning("[AADHIPATI] %s", self.unavailable_reason)
            return False
        try:
            import whisper  # noqa: F401
            return True
        except ImportError:
            self.unavailable_reason = "Voice interface unavailable: openai-whisper is not installed"
            logger.warning("[AADHIPATI] %s", self.unavailable_reason)
            return False
    
    def transcribe(self, audio_path: str) -> str:
        """Transcribe audio file to text."""
        if not self._whisper_available:
            return ""
        
        try:
            import whisper
            model = whisper.load_model(self.model_size)
            result = model.transcribe(audio_path, language="ne")  # Nepali
            return result.get("text", "").strip()
        except Exception as e:
            self.last_error = str(e)
            logger.error(f"[AADHIPATI] Whisper transcription failed: {e}")
            return ""
    
    def transcribe_auto_language(self, audio_path: str) -> str:
        """Auto-detect language and transcribe."""
        if not self._whisper_available:
            return ""
        
        try:
            import whisper
            model = whisper.load_model(self.model_size)
            result = model.transcribe(audio_path)
            return result.get("text", "").strip()
        except Exception as e:
            self.last_error = str(e)
            logger.error(f"[AADHIPATI] Whisper auto-transcription failed: {e}")
            return ""


# =============================================================================
# AGENT FACTORY
# =============================================================================

@dataclass
class AgentTemplate:
    name: str
    description: str
    category: str
    python_template: str
    service_template: str
    required_packages: List[str]
    default_ports: List[int]
    permissions: List[str]


class AgentFactory:
    """
    Creates new AI agents from pre-built templates.
    Not true code generation — but deploys configurable agents rapidly.
    """
    
    TEMPLATES = {
        "network-monitor": AgentTemplate(
            name="network-monitor",
            description="Monitors network traffic for anomalies",
            category="defense",
            python_template="""
import asyncio, logging
from shared import MessageBus, AgentDatabase
logger = logging.getLogger("{{AGENT_NAME}}")
class {{AGENT_CLASS}}:
    def __init__(self):
        self.name = "{{AGENT_NAME}}"
        self.bus = MessageBus()
    async def run(self):
        await self.bus.connect()
        while True:
            # Monitor network connections
            await asyncio.sleep(60)
agent = {{AGENT_CLASS}}()
asyncio.run(agent.run())
""",
            service_template="""
[Unit]
Description=KIRAT OS — {{AGENT_NAME}}
After=network-online.target
[Service]
Type=simple
User={{AGENT_NAME}}
ExecStart=/usr/bin/python3 /opt/kirat-os/ai-agents/{{AGENT_NAME}}/main.py
Restart=always
[Install]
WantedBy=multi-user.target
""",
            required_packages=["scapy", "psutil"],
            default_ports=[],
            permissions=["read_network", "publish_alerts"]
        ),
        "database-guard": AgentTemplate(
            name="database-guard",
            description="Protects PostgreSQL from injection and unauthorized access",
            category="defense",
            python_template="""
import asyncio, logging, re
from shared import MessageBus
logger = logging.getLogger("{{AGENT_NAME}}")
class {{AGENT_CLASS}}:
    def __init__(self):
        self.name = "{{AGENT_NAME}}"
        self.bus = MessageBus()
    async def run(self):
        await self.bus.connect()
        while True:
            # Monitor PostgreSQL logs
            await asyncio.sleep(30)
agent = {{AGENT_CLASS}}()
asyncio.run(agent.run())
""",
            service_template="""
[Unit]
Description=KIRAT OS — {{AGENT_NAME}}
After=postgresql.service
[Service]
Type=simple
User={{AGENT_NAME}}
ExecStart=/usr/bin/python3 /opt/kirat-os/ai-agents/{{AGENT_NAME}}/main.py
Restart=always
[Install]
WantedBy=multi-user.target
""",
            required_packages=["psycopg2-binary"],
            default_ports=[],
            permissions=["read_logs", "publish_alerts"]
        ),
        "backup-sentinel": AgentTemplate(
            name="backup-sentinel",
            description="Verifies backup integrity and automates disaster recovery",
            category="resilience",
            python_template="""
import asyncio, logging, os
from shared import MessageBus
logger = logging.getLogger("{{AGENT_NAME}}")
class {{AGENT_CLASS}}:
    def __init__(self):
        self.name = "{{AGENT_NAME}}"
        self.bus = MessageBus()
    async def run(self):
        await self.bus.connect()
        while True:
            # Check backup integrity
            await asyncio.sleep(3600)
agent = {{AGENT_CLASS}}()
asyncio.run(agent.run())
""",
            service_template="""
[Unit]
Description=KIRAT OS — {{AGENT_NAME}}
[Service]
Type=simple
User={{AGENT_NAME}}
ExecStart=/usr/bin/python3 /opt/kirat-os/ai-agents/{{AGENT_NAME}}/main.py
Restart=always
[Install]
WantedBy=multi-user.target
""",
            required_packages=[],
            default_ports=[],
            permissions=["read_filesystem", "publish_alerts"]
        ),
    }
    
    def __init__(self, executor: Optional[PrivilegedExecutor] = None):
        self.executor = executor or PrivilegedExecutor("aadhipati-ai")

    def list_templates(self) -> List[Dict]:
        return [{"name": k, "description": v.description, "category": v.category} for k, v in self.TEMPLATES.items()]

    def create_agent(self, template_name: str, instance_name: str) -> bool:
        """Deployment is a signed administrative operation, never a direct write."""
        if template_name not in self.TEMPLATES or not instance_name:
            logger.error("[FACTORY] Unknown template or missing instance name")
            return False
        result = self.executor.execute_configured("create-agent", timeout=300)
        if not result.success:
            logger.error("[FACTORY] Signed deployment not performed: %s", result.message)
        return result.success

    def destroy_agent(self, instance_name: str) -> bool:
        """Removal requires a pre-signed exact administrative instruction."""
        if not instance_name:
            return False
        result = self.executor.execute_configured("destroy-agent", timeout=300)
        if not result.success:
            logger.error("[FACTORY] Signed removal not performed: %s", result.message)
        return result.success


# =============================================================================
# PERMISSION MATRIX
# =============================================================================

class PermissionMatrix:
    """
    Controls what each AI agent is allowed to do.
    Enforced at the guardian level.
    """
    
    DEFAULT_PERMISSIONS = {
        # Core 5 agents
        "jitedasti-ai": ["read_logs", "publish_alerts", "read_network", "trigger_scan"],
        "galinja-ai": ["read_logs", "publish_alerts", "modify_firewall", "restart_service", "restore_baseline"],
        "oysgja-ai": ["bind_port", "publish_alerts", "read_network"],
        "suyarma-ai": ["read_packages", "publish_alerts", "trigger_patch"],
        "papa-ai": ["read_sessions", "publish_alerts", "terminate_session"],
        
        # CEO
        "aadhipati-ai": ["*"],  # All permissions
        
        # Legacy
        "sentinel-ai": ["read_system", "publish_alerts", "execute_whitelisted"],
    }
    
    CRITICAL_PERMISSIONS = [
        "modify_firewall", "restart_service", "terminate_session",
        "trigger_patch", "restore_baseline", "set_immutable"
    ]
    
    def __init__(self, db: AgentDatabase):
        self.db = db
        self.permissions: Dict[str, List[str]] = dict(self.DEFAULT_PERMISSIONS)
    
    def has_permission(self, agent: str, action: str) -> bool:
        """Check if an agent has permission to perform an action."""
        agent_perms = self.permissions.get(agent, [])
        if "*" in agent_perms:
            return True
        return action in agent_perms
    
    def grant(self, agent: str, permission: str):
        """Grant a permission to an agent."""
        if agent not in self.permissions:
            self.permissions[agent] = []
        if permission not in self.permissions[agent]:
            self.permissions[agent].append(permission)
            logger.info(f"[PERMISSION] Granted {permission} to {agent}")
    
    def revoke(self, agent: str, permission: str):
        """Revoke a permission from an agent."""
        if agent in self.permissions and permission in self.permissions[agent]:
            self.permissions[agent].remove(permission)
            logger.info(f"[PERMISSION] Revoked {permission} from {agent}")
    
    def set_role(self, agent: str, role: str):
        """Set a predefined role for an agent."""
        roles = {
            "observer": ["read_logs", "publish_alerts"],
            "defender": ["read_logs", "publish_alerts", "modify_firewall", "restart_service"],
            "executor": ["read_logs", "publish_alerts", "execute_whitelisted"],
            "admin": ["*"],
        }
        if role in roles:
            self.permissions[agent] = roles[role]
            logger.info(f"[PERMISSION] Set {agent} role to {role}")


# =============================================================================
# AADHIPATI AI — CEO
# =============================================================================

class AadhipatiAI:
    """
    Supreme CEO of KIRAT OS.
    Commands all agents, understands voice, manages permissions, creates new agents.
    """
    
    AGENT_UNITS = {
        "jitedasti": "jitedasti-ai", "galinja": "galinja-ai",
        "oysgja": "oysgja-ai", "suyarma": "suyarma-ai",
        "papa": "papa-ai", "aadhipati": "aadhipati-ai",
    }

    def __init__(self, executor: Optional[PrivilegedExecutor] = None):
        self.name = "aadhipati-ai"
        self.title = "आधिपति — Sovereign of KIRAT OS"
        self.ollama = OllamaClient()
        self.db = AgentDatabase()
        self.bus = MessageBus()
        self.nlp = NepaliNLP(self.ollama)
        self.voice = VoiceInterface()
        self.executor = executor or PrivilegedExecutor(self.name)
        self.factory = AgentFactory(self.executor)
        self.permissions = PermissionMatrix(self.db)
        self._running = False

    async def initialize(self):
        await self.bus.connect()
        logger.info("[AADHIPATI] %s initialized", self.title)
        logger.info("[AADHIPATI] Available agent templates: %d", len(self.factory.list_templates()))

    async def run(self):
        self._running = True
        await self.initialize()
        while self._running:
            await asyncio.sleep(1)

    def _unit_name(self, agent: str) -> Optional[str]:
        if agent in self.AGENT_UNITS.values():
            return agent
        return self.AGENT_UNITS.get(agent)

    def _authorized(self, agent: str, permission: str) -> bool:
        target = self._unit_name(agent)
        caller_allowed = self.permissions.has_permission(self.name, permission)
        target_allowed = target is not None and self.permissions.has_permission(target, permission)
        if not caller_allowed or not target_allowed:
            logger.warning("[PERMISSION] Denied %s for %s (caller or target lacks permission)", permission, agent)
            return False
        return True

    async def process_voice_command(self, audio_path: str) -> str:
        if not self.voice._whisper_available:
            return f"Voice command unavailable: {self.voice.unavailable_reason}"
        text = self.voice.transcribe_auto_language(audio_path)
        if not text:
            return f"Voice transcription failed: {self.voice.last_error or 'no speech was recognized'}"
        logger.info("[AADHIPATI] Heard: %s", text)
        command = await self.nlp.parse_command(text)
        result = await self.execute_command(command)
        return await self._generate_response(result, text)

    async def process_text_command(self, text: str) -> str:
        command = await self.nlp.parse_command(text)
        result = await self.execute_command(command)
        return await self._generate_response(result, text)

    async def execute_command(self, command: Dict[str, Any]) -> Dict[str, Any]:
        agent = command.get("agent", "all")
        action = command.get("action", "status")
        params = command.get("params") or {}
        logger.info("[AADHIPATI] Executing: %s.%s()", agent, action)
        if action in ("status", "report"):
            return await self._cmd_status(agent)
        if action == "scan":
            return await self._cmd_scan(agent)
        if action == "protect":
            return await self._cmd_protect(agent)
        if action == "create":
            return await self._cmd_create(params)
        if action == "permission":
            return await self._cmd_permission(params)
        return {"success": False, "message": f"Unknown action: {action}"}

    async def _cmd_status(self, agent: str) -> Dict[str, Any]:
        agents_to_check = list(self.AGENT_UNITS.values())[:-1] if agent == "all" else [self._unit_name(agent)]
        if not agents_to_check[0]:
            return {"success": False, "message": f"Unknown agent: {agent}"}
        statuses = {}
        for unit in agents_to_check:
            try:
                result = subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True, timeout=10)
                statuses[unit] = "active" if result.returncode == 0 else "inactive"
            except (OSError, subprocess.TimeoutExpired):
                statuses[unit] = "unknown"
        return {"success": True, "statuses": statuses, "message": f"Agent statuses: {statuses}"}

    async def _cmd_scan(self, agent: str) -> Dict[str, Any]:
        if agent not in ("jitedasti", "jitedasti-ai", "all"):
            return {"success": False, "message": f"Agent {agent} does not support scan"}
        if not self._authorized("jitedasti", "trigger_scan"):
            return {"success": False, "message": "Permission denied: trigger_scan"}
        result = self.executor.execute_configured("scan-jitedasti")
        return {"success": result.success, "message": result.message if not result.success else "Signed jitedasti-ai scan instruction executed"}

    async def _cmd_protect(self, agent: str) -> Dict[str, Any]:
        if agent not in ("galinja", "galinja-ai", "all"):
            return {"success": False, "message": f"Agent {agent} does not support protect"}
        if not self._authorized("galinja", "modify_firewall"):
            return {"success": False, "message": "Permission denied: modify_firewall"}
        if not destructive_actions_enabled():
            return {"success": False, "message": "Emergency protection is disabled by default; destructive actions require explicit enablement"}
        result = self.executor.execute_configured("protect-galinja")
        return {"success": result.success, "message": result.message if not result.success else "Signed emergency protection instruction executed"}

    async def _cmd_create(self, params: Dict) -> Dict[str, Any]:
        if not self.permissions.has_permission(self.name, "manage_agents"):
            return {"success": False, "message": "Permission denied: manage_agents"}
        if not destructive_actions_enabled():
            return {"success": False, "message": "Agent deployment is disabled by default; destructive actions require explicit enablement"}
        template = params.get("template", "network-monitor")
        name = params.get("name", f"agent-{int(time.time())}")
        success = self.factory.create_agent(template, name)
        return {"success": success, "message": f"Signed deployment {'executed' if success else 'was not performed'} for {name}; see executor audit log"}

    async def _cmd_permission(self, params: Dict) -> Dict[str, Any]:
        if not self.permissions.has_permission(self.name, "manage_permissions"):
            return {"success": False, "message": "Permission denied: manage_permissions"}
        agent = self._unit_name(params.get("agent", "")) or params.get("agent", "")
        perm = params.get("permission", "")
        action = params.get("action", "grant")
        if not agent or not perm or action not in ("grant", "revoke"):
            return {"success": False, "message": "Valid agent, permission, and grant/revoke action required"}
        if action == "grant":
            self.permissions.grant(agent, perm)
        else:
            self.permissions.revoke(agent, perm)
        return {"success": True, "message": f"{action}ed {perm} for {agent} in the active permission matrix"}
    
    async def _generate_response(self, result: Dict, original_text: str) -> str:
        """Generate a response in the same language as the input."""
        is_nepali = any(char in original_text for char in "अआइईउऊएऐओऔकखगघचछजझटठडढणतथदधनपफबभमयरलवशषसह")
        
        if result["success"]:
            if is_nepali:
                return f"काम सफल भयो। {result.get('message', '')}"
            else:
                return f"Success. {result.get('message', '')}"
        else:
            if is_nepali:
                return f"माफ गर्नुहोस्, त्रुटि भयो। {result.get('message', '')}"
            else:
                return f"Error: {result.get('message', '')}"
    
    def get_empire_status(self) -> Dict[str, Any]:
        """Get complete empire-wide status."""
        base_dir = "/opt/kirat-os/ai-agents"
        try:
            deployed = sum(1 for name in os.listdir(base_dir) if name != "shared")
        except OSError:
            deployed = 0
        return {
            "ceo": self.title,
            "timestamp": datetime.utcnow().isoformat(),
            "agents": {
                "core": list(self.AGENT_UNITS.values())[:-1],
                "deployed": deployed,
                "templates": len(self.factory.list_templates()),
            },
            "security_score": self._calculate_security_score(),
            "permissions": dict(self.permissions.permissions),
            "voice_available": self.voice._whisper_available,
            "voice_status": self.voice.unavailable_reason or "available",
        }

    def _calculate_security_score(self) -> int:
        """Calculate overall security score."""
        score = 70  # Base
        for unit in list(self.AGENT_UNITS.values())[:-1]:
            try:
                result = subprocess.run(["systemctl", "is-active", unit], capture_output=True, timeout=10)
                if result.returncode == 0:
                    score += 2
            except (OSError, subprocess.TimeoutExpired):
                pass
        
        # +10 for PQC
        if os.path.exists("/etc/ssh/sshd_config.d/kirat-production.conf"):
            score += 10
        
        # +10 for disk encryption
        if os.path.exists("/dev/mapper/kirat-root"):
            score += 10
        
        return min(score, 100)


async def main():
    aadhipati = AadhipatiAI()
    await aadhipati.run()


if __name__ == "__main__":
    asyncio.run(main())
