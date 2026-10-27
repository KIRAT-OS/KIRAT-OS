"""
KIRAT OS — Resource Profiles for AI Agents
Adjusts AI agent behavior based on available system RAM.
Loaded by each agent at startup to tune memory limits, batch sizes,
and model selection.
"""

import os
import psutil


def get_system_ram_gb() -> int:
    """Return total system RAM in GB."""
    return psutil.virtual_memory().total // (1024 ** 3)


class ResourceProfile:
    """
    Defines resource limits for AI agents based on system capacity.
    """

    def __init__(self):
        self.ram_gb = get_system_ram_gb()
        self.profile = self._select_profile()

    def _select_profile(self) -> dict:
        if self.ram_gb >= 32:
            return self._high_profile()
        elif self.ram_gb >= 16:
            return self._medium_profile()
        elif self.ram_gb >= 8:
            return self._low_profile()
        else:
            return self._minimal_profile()

    def _high_profile(self) -> dict:
        return {
            "name": "high",
            "ram_gb": self.ram_gb,
            "ollama_model": "gemma4:latest",
            "whisper_model": "base",
            "max_concurrent_agents": 6,
            "log_buffer_size": 10000,
            "network_scan_threads": 8,
            "honeypot_instances": 5,
            "backup_parallel_jobs": 4,
            "ai_memory_limit": "4G",
            "description": "Full performance — all features enabled"
        }

    def _medium_profile(self) -> dict:
        return {
            "name": "medium",
            "ram_gb": self.ram_gb,
            "ollama_model": "gemma4:latest",
            "whisper_model": "base",
            "max_concurrent_agents": 6,
            "log_buffer_size": 5000,
            "network_scan_threads": 4,
            "honeypot_instances": 3,
            "backup_parallel_jobs": 2,
            "ai_memory_limit": "2G",
            "description": "Balanced performance — most features enabled"
        }

    def _low_profile(self) -> dict:
        return {
            "name": "low",
            "ram_gb": self.ram_gb,
            "ollama_model": "qwen3.6:latest",
            "whisper_model": "tiny",
            "max_concurrent_agents": 4,
            "log_buffer_size": 1000,
            "network_scan_threads": 2,
            "honeypot_instances": 2,
            "backup_parallel_jobs": 1,
            "ai_memory_limit": "1G",
            "description": "Reduced footprint — core features only"
        }

    def _minimal_profile(self) -> dict:
        return {
            "name": "minimal",
            "ram_gb": self.ram_gb,
            "ollama_model": "qwen3.6:latest",
            "whisper_model": "tiny",
            "max_concurrent_agents": 2,
            "log_buffer_size": 500,
            "network_scan_threads": 1,
            "honeypot_instances": 1,
            "backup_parallel_jobs": 1,
            "ai_memory_limit": "512M",
            "description": "Emergency mode — single agent, minimal features"
        }

    def to_env(self) -> dict:
        """Export profile as environment variables for systemd services."""
        return {
            "KIRAT_PROFILE": self.profile["name"],
            "KIRAT_OLLAMA_MODEL": self.profile["ollama_model"],
            "KIRAT_WHISPER_MODEL": self.profile["whisper_model"],
            "KIRAT_AI_MEMORY": self.profile["ai_memory_limit"],
        }

    def apply(self):
        """Apply profile settings to running environment."""
        for key, value in self.to_env().items():
            os.environ[key] = value

    def report(self) -> str:
        p = self.profile
        return f"""
┌─────────────────────────────────────────┐
│  KIRAT OS Resource Profile: {p['name'].upper():8}      │
├─────────────────────────────────────────┤
│  System RAM:     {p['ram_gb']:3} GB                    │
│  AI Model:       {p['ollama_model']:20} │
│  Voice Model:    {p['whisper_model']:20} │
│  Max Agents:     {p['max_concurrent_agents']:3}                      │
│  Memory Limit:   {p['ai_memory_limit']:8}                 │
│  Honeypots:      {p['honeypot_instances']:3}                      │
├─────────────────────────────────────────┤
│  {p['description']:37} │
└─────────────────────────────────────────┘
"""


# Auto-apply on import if running as main
if __name__ == "__main__":
    profile = ResourceProfile()
    print(profile.report())
