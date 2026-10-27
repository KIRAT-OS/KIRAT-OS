#!/usr/bin/env python3
"""Static regression tests for the native installer; never execute an install."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "install-native.sh"


class InstallNativeSecurityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = INSTALLER.read_text(encoding="utf-8")

    def test_bash_syntax(self):
        candidates = [Path(r"C:\Program Files\Git\bin\bash.exe"), Path("/bin/bash"), Path("/usr/bin/bash")]
        bash = next((path for path in candidates if path.is_file()), None)
        if bash is None:
            self.skipTest("A local Bash interpreter is not available")
        subprocess.run([str(bash), "-n", "scripts/install-native.sh"], cwd=ROOT, check=True)

    def test_dangerous_legacy_content_is_gone(self):
        forbidden = (
            "2.0.7-PRODUCTION",
            "100% operational",
            "100% OPERATIONAL",
            "100/100",
            "fully operational",
            "quantum-proof",
            "releases/latest/download",
            "OLLAMA_HOST=0.0.0.0",
            "--host 0.0.0.0",
            "ufw allow 3000/tcp",
            "ufw allow 8080/tcp",
            "ufw allow 8081/tcp",
            "PermitRootLogin prohibit-password",
            "AllowTcpForwarding yes",
            "kirat-temp-db",
            "CREATE USER kirat_admin",
            "backup-passphrase",
            "/usr/bin/docker ps",
            "/usr/bin/docker build",
            "ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519",
            "admin.key",
            "admin.pub",
            "Ed25519PrivateKey",
            "Ed25519PublicKey",
            "ADMIN_SIG",
            "SIGNATURE=$(python3",
            "ALLOWED_CMDS=(",
            "for prefix in",
            'bash -c "$CMD"',
            '"agent":"$AGENT"',
            '"created":',
            "orchestrator-dispatch.sh",
            "executor-queue",
        )
        for value in forbidden:
            with self.subTest(value=value):
                self.assertNotIn(value, self.text)

    def test_canonical_rbac_integration(self):
        for expected in (
            ".admin-ed25519-secret",
            "admin-ed25519.pub",
            "ed25519-sign.py genkey",
            'python3 "$RBAC/ed25519-sign.py" sign "$FILE"',
            'exec "$RBAC/executor-run.sh" "$FILE"',
            '"instruction_id": instruction_id',
            '"issuer": "kirat-admin"',
            '"target": "kirat-ai-executor"',
            '"command": command',
            '"issued_at": stamp(now)',
            '"expiry": stamp(now + timedelta(minutes=5))',
            '"nonce": os.urandom(16).hex()',
            "chmod 600 /opt/kirat-os/security/rbac/.admin-ed25519-secret",
            "for agent in galinja-ai aadhipati-ai papa-ai suyarma-ai",
            "sudo -n /opt/kirat-os/security/rbac/executor-run.sh",
            "/opt/kirat-os/security/rbac/executed-ids",
            "chown -R root:root /opt/kirat-os/security/rbac",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.text)

    def test_network_and_secret_configuration(self):
        for expected in (
            'KIRAT_VERSION="2.0.8-PRE-RELEASE"',
            "SENTINEL_API_KEY=$(openssl rand -hex 32)",
            "DASHBOARD_API_KEY=$(openssl rand -hex 32)",
            "EnvironmentFile=/etc/kirat-os/sentinel.env",
            "EnvironmentFile=/etc/kirat-os/dashboard.env",
            "--host 127.0.0.1 --port 8080",
            'Environment="OLLAMA_HOST=127.0.0.1:11434"',
            "proxy_pass http://127.0.0.1:8080;",
            'proxy_set_header Upgrade \\$http_upgrade;',
            'proxy_set_header Connection "upgrade";',
            "DisableForwarding yes",
            "PermitRootLogin no",
            "NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.text)
        self.assertNotIn("location /quantum/", self.text)
        self.assertNotIn("location /sentinel/", self.text)

    def test_verified_ollama_and_opt_in_downloads(self):
        for expected in (
            'OLLAMA_VERSION="0.40.11"',
            "releases/download/v",
            "OLLAMA_SHA256",
            "7bedab90dd122661be78798e9f0edf37fccf0cccf2699d2c58ea1a3afdc04b6d",
            "sha256sum -c -",
            "ConditionPathExists=/etc/kirat-os/ollama-pull-models.enabled",
            'chroot "$INSTALL_MOUNT" /usr/local/sbin/kirat-ollama-install || die',
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.text)
        self.assertNotIn('"$URL.sha256"', self.text)

    def test_runtime_permissions_and_quantum_fail_closed(self):
        for expected in (
            "chown root:ai-agents /var/lib/kirat-os/executor-requests",
            "chmod 0750 /var/lib/kirat-os/executor-requests",
            "chown root:root /data/backups",
            "chmod 0700 /data/backups",
            "ReadWritePaths=/var/lib/kirat-os /data/business",
            'Native Quantum service integration is not supported',
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.text)
        self.assertNotIn("ReadWritePaths=/opt/kirat-os /data/business", self.text)
        self.assertNotIn("QUANTUM_API_KEY=%s", self.text.replace("KIRAT_QUANTUM_ADMIN_API_KEY=%s", ""))

    def test_native_ai_runtime_dependencies_are_installed_and_verified(self):
        for expected in (
            "python3-nacl",
            "python3 -m venv /opt/kirat-os/venv",
            "--requirement /opt/kirat-os/dashboard/requirements.txt",
            "import fastapi, uvicorn, httpx, psutil, jinja2, slowapi, dotenv, redis",
            "/opt/kirat-os/venv/bin/python",
            "jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.text)
        self.assertNotIn("ExecStart=/usr/bin/python3", self.text)

    def test_first_boot_resume_and_final_verification(self):
        for expected in (
            "first-boot-wizard.sh backup-dr.sh",
            "exec /opt/kirat-os/scripts/first-boot-wizard.sh",
            'if [ "$(id -un)" = "kirat-admin" ]',
            "grub-efi-amd64-signed",
            "--uefi-secure-boot",
            'mountpoint -q "$INSTALL_MOUNT/data" || mount /dev/mapper/kirat-data "$INSTALL_MOUNT/data"',
            "sync \"$STAGE_MARKER\"",
            "cryptsetup close kirat-data",
            "cryptsetup close kirat-root",
            'chroot "$INSTALL_MOUNT" nginx -t',
            'chroot "$INSTALL_MOUNT" sshd -t',
            "systemctl is-enabled",
            "BACKUP_GPG_RECIPIENT",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, self.text)


if __name__ == "__main__":
    unittest.main()
