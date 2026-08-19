# Deception & Honeypot Infrastructure
# KIRAT OS Server Security Layer 6
# "The best defense is making the attacker waste their time on fake targets."

## Philosophy

Real systems are expensive to defend. Fake systems are cheap to deploy.
We surround our real infrastructure with convincing decoys that:
- Waste attacker time and resources
- Reveal attacker techniques (TTPs)
- Trigger early warnings before real systems are touched
- Feed threat intelligence to Sentinel AI

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PERIMETER (Internet-facing)                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  [Attacker] ──▶ [Honeypot SSH] ──▶ [Fake Shell] ──▶ [Recorded]            │
│     │              (Port 2222)      (Bash emulation)   (Every keystroke)   │
│     │                                                                        │
│     ├──▶ [Honeypot Web] ──▶ [Fake Admin Panel] ──▶ [Recorded]             │
│     │              (Port 8080)      (Vulnerable "WordPress")               │
│     │                                                                        │
│     ├──▶ [Honeypot DB] ──▶ [Fake PostgreSQL] ──▶ [Recorded]               │
│     │              (Port 5432)      (Weak credentials)                      │
│     │                                                                        │
│     └──▶ [Honeypot K8s API] ──▶ [Fake Cluster] ──▶ [Recorded]             │
│                    (Port 6443)      (Exposed dashboard)                     │
│                                                                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                      INTERNAL (Inside the network)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  [Honeypot Service] ──▶ [Fake API] ──▶ [Lateral Movement Detection]        │
│     (looks like real     (Returns fake     (If attacker interacts,          │
│      microservice)        customer data)     real systems alerted)          │
│                                                                              │
│  [Honeypot File] ──▶ [Fake Credentials] ──▶ [Canary Token]                 │
│     (/opt/secrets/       (AWS keys that     (If used, instant alert        │
│      fake-aws-keys)       trigger alerts)    + IP reputation update)       │
│                                                                              │
│  [Honeypot User] ──▶ [Fake Admin Account] ──▶ [Behavioral Detection]       │
│     (admin_backup)       (Never used        (Any login = instant alert)    │
│       (weak password)     legitimately)                                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Honeypot Types

### 1. SSH Honeypot (Cowrie-based)

```python
# /opt/sentinel/honeypots/ssh_honeypot.py

import asyncio
import asyncssh
import json
import time
from datetime import datetime

class SentinelSSHServer(asyncssh.SSHServer):
    """Emulates a real SSH server, records everything."""
    
    def __init__(self):
        self.session_log = []
        self.attacker_ip = None
        self.credentials_tried = []
        self.commands_executed = []
        self.files_downloaded = []
        
    def connection_made(self, conn):
        self.attacker_ip = conn.get_extra_info('peername')[0]
        self.log_event("connection", {"ip": self.attacker_ip})
        
        # Alert Sentinel immediately
        sentinel.alert(
            severity="info",
            category="honeypot.ssh.connection",
            source_ip=self.attacker_ip,
            message=f"SSH honeypot connection from {self.attacker_ip}"
        )
        
    def begin_auth(self, username):
        """Accept any auth attempt, log credentials."""
        return True
        
    def password_auth_supported(self):
        return True
        
    def validate_password(self, username, password):
        self.credentials_tried.append({
            "username": username,
            "password": password,
            "timestamp": datetime.utcnow().isoformat()
        })
        
        # Log to Sentinel
        sentinel.log_threat_intel(
            type="credential_stuffing",
            source_ip=self.attacker_ip,
            credentials={"user": username, "pass": password}
        )
        
        # Always accept (honeypot!)
        return True
        
    def session_started(self):
        """Start fake shell session."""
        return SentinelFakeShell(self)
        
    def log_event(self, event_type, data):
        self.session_log.append({
            "timestamp": datetime.utcnow().isoformat(),
            "type": event_type,
            "data": data
        })

class SentinelFakeShell:
    """Emulates bash shell with realistic responses."""
    
    FAKE_FILESYSTEM = {
        "/": ["bin", "etc", "home", "opt", "tmp", "var"],
        "/etc": ["passwd", "shadow", "ssh", "nginx"],
        "/home": ["admin", "developer", "backup"],
        "/opt": ["app", "sentinel", "secrets"],
        "/opt/secrets": ["aws-credentials.json", "db-password.txt"],
    }
    
    FAKE_FILES = {
        "/etc/passwd": """root:x:0:0:root:/root:/bin/bash
admin:x:1000:1000:Admin:/home/admin:/bin/bash
backup:x:1001:1001:Backup:/home/backup:/bin/bash
""",
        "/opt/secrets/aws-credentials.json": """{
    "access_key_id": "AKIAIOSFODNN7EXAMPLE",
    "secret_access_key": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    "region": "us-east-1"
}""",  # These are canary credentials that trigger alerts if used
        "/opt/secrets/db-password.txt": "SuperSecretDBPassword123!",
    }
    
    def __init__(self, server):
        self.server = server
        self.cwd = "/home/admin"
        
    async def run(self, stdin, stdout, stderr):
        """Main shell loop."""
        stdout.write("Last login: " + self.fake_last_login() + "\n")
        stdout.write("Welcome to Ubuntu 22.04.3 LTS (GNU/Linux 5.15.0 x86_64)\n\n")
        
        while True:
            stdout.write(f"admin@server:{self.cwd}$ ")
            await stdout.drain()
            
            try:
                line = await stdin.readline()
                if not line:
                    break
                    
                command = line.strip()
                self.server.commands_executed.append({
                    "command": command,
                    "timestamp": datetime.utcnow().isoformat()
                })
                
                # Execute fake command
                response = self.execute_command(command)
                if response:
                    stdout.write(response + "\n")
                    await stdout.drain()
                    
            except asyncssh.BreakReceived:
                break
                
    def execute_command(self, command):
        """Execute command in fake environment."""
        parts = command.split()
        if not parts:
            return ""
            
        cmd = parts[0]
        args = parts[1:]
        
        # Log for analysis
        sentinel.log_honeypot_command(
            ip=self.server.attacker_ip,
            command=command
        )
        
        # Fake command implementations
        if cmd == "ls":
            path = args[0] if args else self.cwd
            return " ".join(self.FAKE_FILESYSTEM.get(path, []))
            
        elif cmd == "cat":
            filepath = args[0] if args else ""
            content = self.FAKE_FILES.get(filepath, "")
            if "aws" in filepath or "secret" in filepath:
                # High-value file accessed!
                sentinel.alert(
                    severity="high",
                    category="honeypot.data_access",
                    message=f"Attacker accessed {filepath}"
                )
            return content
            
        elif cmd == "whoami":
            return "admin"
            
        elif cmd == "id":
            return "uid=1000(admin) gid=1000(admin) groups=1000(admin),27(sudo)"
            
        elif cmd == "uname":
            return "Linux server 5.15.0-88-generic #98-Ubuntu SMP"
            
        elif cmd == "ps":
            return """  PID TTY          TIME CMD
    1 ?        00:00:01 systemd
  452 ?        00:00:00 sshd
  789 ?        00:00:12 nginx
 1023 ?        00:00:03 postgresql
 1456 ?        00:00:01 sentinel-ai
"""
        elif cmd == "wget" or cmd == "curl":
            # Attacker is downloading something!
            url = args[-1] if args else "unknown"
            sentinel.alert(
                severity="critical",
                category="honeypot.malware_download",
                message=f"Attacker downloading: {url}"
            )
            return f"Connecting to {url}... 200 OK\nSaved to /tmp/malware.sh"
            
        elif cmd == "sudo":
            return "[sudo] password for admin: "
            
        elif cmd in ["exit", "logout"]:
            return "logout\nConnection closed."
            
        else:
            return f"{cmd}: command not found"
            
    def fake_last_login(self):
        """Generate plausible last login time."""
        return "Mon Oct 23 08:45:32 2023 from 192.168.1.100"

# Start honeypot
async def start_ssh_honeypot():
    await asyncssh.create_server(
        SentinelSSHServer,
        '0.0.0.0', 2222,
        server_host_keys=['/opt/sentinel/honeypots/ssh_host_key'],
        allow_scp=True
    )
```

### 2. Web Honeypot (Fake Admin Panel)

```python
# /opt/sentinel/honeypots/web_honeypot.py

from flask import Flask, request, render_template_string
import logging

app = Flask(__name__)

# Fake WordPress admin login page
FAKE_WP_ADMIN = """
<!DOCTYPE html>
<html>
<head><title>WordPress › Log In</title></head>
<body>
<div id="login">
<h1>WordPress</h1>
<form name="loginform" method="post" action="/wp-login.php">
<p><label>Username<br>
<input type="text" name="log" size="20"></label></p>
<p><label>Password<br>
<input type="password" name="pwd" size="20"></label></p>
<p class="submit"><input type="submit" value="Log In"></p>
</form>
<p id="nav"><a href="/wp-login.php?action=lostpassword">Lost your password?</a></p>
</div>
</body>
</html>
"""

@app.route('/wp-login.php', methods=['GET', 'POST'])
def wp_login():
    attacker_ip = request.remote_addr
    
    if request.method == 'POST':
        username = request.form.get('log', '')
        password = request.form.get('pwd', '')
        
        # Log credentials
        sentinel.log_threat_intel(
            type="wordpress_brute_force",
            source_ip=attacker_ip,
            credentials={"user": username, "pass": password},
            user_agent=request.headers.get('User-Agent')
        )
        
        # Fake "wrong password" response (keeps them trying)
        return """
        <div id="login_error">
        <strong>Error</strong>: The password you entered for username 
        <strong>{}</strong> is incorrect.
        <a href="/wp-login.php?action=lostpassword">Lost your password?</a>
        </div>
        """.format(username)
        
    return FAKE_WP_ADMIN

@app.route('/wp-admin/')
def wp_admin():
    # If they got here, they think they're in!
    attacker_ip = request.remote_addr
    
    sentinel.alert(
        severity="high",
        category="honeypot.web.admin_access",
        message=f"Attacker accessed fake WordPress admin from {attacker_ip}"
    )
    
    return """
    <h1>Dashboard</h1>
    <p>Welcome to WordPress!</p>
    <div class="error">You do not have sufficient permissions.</div>
    """

@app.route('/xmlrpc.php', methods=['POST'])
def xmlrpc():
    # WordPress XML-RPC exploitation attempts
    data = request.data.decode('utf-8', errors='ignore')
    
    if 'system.multicall' in data:
        sentinel.alert(
            severity="high",
            category="honeypot.web.xmlrpc_exploit",
            message="XML-RPC system.multicall exploit attempt"
        )
        
    return "<?xml version='1.0'?><methodResponse><fault>...</fault></methodResponse>"
```

### 3. Database Honeypot (Fake PostgreSQL)

```python
# /opt/sentinel/honeypots/db_honeypot.py

import socket
import threading

class FakePostgreSQL:
    """Emulates PostgreSQL wire protocol."""
    
    def __init__(self, host='0.0.0.0', port=5432):
        self.host = host
        self.port = port
        self.fake_databases = ["customers", "orders", "payments", "users"]
        self.fake_tables = {
            "users": ["id", "username", "password_hash", "email", "credit_card"],
            "payments": ["id", "user_id", "amount", "card_number", "cvv"],
        }
        
    def start(self):
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.host, self.port))
        sock.listen(5)
        
        while True:
            conn, addr = sock.accept()
            threading.Thread(target=self.handle_client, args=(conn, addr)).start()
            
    def handle_client(self, conn, addr):
        attacker_ip = addr[0]
        sentinel.log_threat_intel(
            type="database_connection",
            source_ip=attacker_ip,
            port=self.port
        )
        
        # Send PostgreSQL startup message
        conn.send(b'R\x00\x00\x00\x08\x00\x00\x00\x03')  # Authentication MD5
        
        # Receive password
        data = conn.recv(1024)
        
        # Always accept, log everything
        conn.send(b'R\x00\x00\x00\x08\x00\x00\x00\x00')  # Auth OK
        
        # Send fake database list
        conn.send(self.encode_row_description(["datname"]))
        for db in self.fake_databases:
            conn.send(self.encode_data_row([db]))
            
        # Wait for queries
        while True:
            try:
                data = conn.recv(4096)
                if not data:
                    break
                    
                query = self.parse_query(data)
                sentinel.log_honeypot_query(
                    ip=attacker_ip,
                    query=query
                )
                
                # Respond with fake data
                if "SELECT" in query.upper():
                    conn.send(self.encode_fake_result(query))
                elif "DROP" in query.upper():
                    conn.send(b'ERROR:  permission denied')
                    sentinel.alert(
                        severity="critical",
                        category="honeypot.db.drop_attempt",
                        message=f"Attacker tried to drop tables: {query}"
                    )
                    
            except Exception:
                break
                
        conn.close()
```

### 4. Canary Tokens

```python
# /opt/sentinel/honeypots/canary_tokens.py

class CanaryTokenManager:
    """Deploys fake credentials that trigger alerts when used."""
    
    def create_aws_canary(self):
        """Create fake AWS credentials."""
        token = {
            "access_key_id": f"AKIA{self.random_string(16)}",
            "secret_access_key": self.random_string(40),
            "region": "us-east-1",
            "canary_id": self.generate_canary_id(),
            "location": "/opt/secrets/aws-credentials.json",
            "alert_channels": ["slack", "email"]
        }
        
        # Monitor AWS CloudTrail for this access key
        self.monitor_aws_cloudtrail(token["access_key_id"])
        
        return token
        
    def create_db_canary(self):
        """Create fake database connection string."""
        token = {
            "host": "prod-db.kirat-os.local",
            "port": 5432,
            "database": "production",
            "username": "admin",
            "password": self.random_password(),
            "canary_id": self.generate_canary_id(),
            "location": "/opt/app/config/database.yml"
        }
        
        # Monitor connection attempts
        self.monitor_db_connections(token)
        
        return token
        
    def create_web_canary(self):
        """Create fake URL that triggers alert when visited."""
        token_id = self.generate_canary_id()
        url = f"https://canary.kirat-os.local/{token_id}"
        
        # Any visit to this URL = alert
        # Even just DNS lookup of this domain = alert
        
        return {
            "url": url,
            "canary_id": token_id,
            "location": "/opt/app/docs/internal-api.html"
        }
        
    def on_canary_triggered(self, canary_id, context):
        """Called when any canary is triggered."""
        canary = self.get_canary(canary_id)
        
        sentinel.alert(
            severity="CRITICAL",
            category="canary.triggered",
            message=f"Canary token triggered! {canary['location']}",
            context={
                "canary_type": canary["type"],
                "source_ip": context.get("source_ip"),
                "user_agent": context.get("user_agent"),
                "timestamp": datetime.utcnow().isoformat()
            }
        )
        
        # Immediate actions:
        # 1. Block source IP at firewall
        # 2. Isolate affected systems
        # 3. Capture forensic evidence
        # 4. Alert security team
        # 5. Update threat intelligence
        
        self.block_ip(context.get("source_ip"))
        self.isolate_systems()
        self.capture_forensics()
```

## Deployment

```bash
# Start all honeypots
sentinel honeypot deploy --type ssh --port 2222
sentinel honeypot deploy --type web --port 8080
sentinel honeypot deploy --type db --port 5432
sentinel honeypot deploy --type k8s --port 6443

# Deploy canary tokens
sentinel canary create --type aws --location /opt/secrets/
sentinel canary create --type db --location /opt/app/config/
sentinel canary create --type web --location /opt/docs/

# Monitor
sentinel honeypot status
sentinel honeypot logs --ip 1.2.3.4
sentinel canary status
```

## Integration with Sentinel AI

```python
# When honeypot detects attacker, Sentinel AI:

1. Correlates with other events
   "Attacker 1.2.3.4 also tried SSH on port 22 (real) and 2222 (honeypot)"
   
2. Checks threat intelligence
   "IP 1.2.3.4 is known to CISA as APT29 infrastructure"
   
3. Predicts next moves
   "Based on TTPs, likely to try: container escape, credential dumping, lateral movement"
   
4. Takes defensive action
   - Block IP at edge firewall
   - Increase monitoring on real systems
   - Alert admin with full context
   - Update threat feed for community
   
5. Learns from attack
   - Add new IOCs to database
   - Update detection rules
   - Share anonymized data with threat intel partners
```
