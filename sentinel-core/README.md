# sentinel-core
# Sentinel System Intelligence Engine
# The AI brain that lives inside your server

## Architecture

```
sentinel-core/
├── src/
│   ├── main.py                 # Entry point, service orchestration
│   ├── collector/              # Data collection from kernel & system
│   │   ├── ebpf_collector.py   # eBPF tracepoint/kprobe data
│   │   ├── proc_collector.py   # /proc filesystem parser
│   │   ├── sysfs_collector.py  # /sys filesystem parser
│   │   ├── hwmon_collector.py  # Hardware sensors (temp, voltage, fan)
│   │   └── kernel_bridge.py    # Communication with kirat-ai.ko
│   ├── analyzer/               # Intelligence & analysis
│   │   ├── anomaly_detector.py # Statistical anomaly detection
│   │   ├── forecaster.py       # Time-series forecasting ( Prophet / custom )
│   │   ├── correlator.py       # Event correlation engine
│   │   └── root_cause.py       # Root cause analysis
│   ├── actor/                  # Automated actions
│   │   ├── auto_healer.py      # Self-healing logic
│   │   ├── auto_scaler.py      # Predictive scaling
│   │   ├── security_actor.py   # Threat response
│   │   └── optimizer.py        # Performance optimization
│   ├── memory/                 # Knowledge & learning
│   │   ├── vector_store.py     # ChromaDB / pgvector for embeddings
│   │   ├── event_log.py        # Structured event history
│   │   ├── pattern_db.py       # Learned patterns & baselines
│   │   └── playbook.py         # Known solutions & procedures
│   ├── llm/                    # Language model integration
│   │   ├── local_llm.py        # llama.cpp / vLLM wrapper
│   │   ├── prompt_engine.py    # Prompt templates & context assembly
│   │   └── function_call.py    # Tool use / function calling
│   └── api/                    # Internal API
│       ├── grpc_server.py      # gRPC for inter-service communication
│       └── websocket.py        # Real-time event streaming
├── models/
│   ├── anomaly/                # Pre-trained anomaly detection models
│   ├── forecast/               # Time-series forecasting models
│   └── embedding/              # Sentence embedding models
├── config/
│   ├── sentinel.yaml           # Main configuration
│   ├── rules/                  # Detection & response rules
│   └── profiles/               # Server role profiles
└── tests/
```

## Core Capabilities

### 1. Observability (The Senses)

Collects data from every layer:

```python
# Example: What sentinel-core sees every second
{
    "timestamp": "2024-07-10T14:32:01Z",
    "kernel": {
        "syscalls_per_sec": 15420,
        "context_switches": 8921,
        "page_faults": 45,
        "irq_count": 1203,
        "softirq_count": 567,
        "oom_kills": 0,
        "sched_latency_us": 12.5
    },
    "cpu": {
        "usage_percent": [23, 45, 12, 67, 89, 34, 12, 45],  # per-core
        "frequency_mhz": 4200,
        "temperature_c": 62,
        "power_watts": 45.2,
        "instructions_per_cycle": 2.1
    },
    "memory": {
        "total_mb": 32768,
        "used_mb": 18432,
        "available_mb": 14336,
        "swap_used_mb": 512,
        "page_cache_mb": 8192,
        "slab_mb": 1024,
        "oom_score": 42
    },
    "storage": {
        "disks": [
            {
                "device": "nvme0n1",
                "read_iops": 45000,
                "write_iops": 12000,
                "read_latency_ms": 0.05,
                "write_latency_ms": 0.08,
                "temperature_c": 45,
                "wear_level_percent": 12
            }
        ],
        "filesystems": [
            {
                "mount": "/",
                "type": "zfs",
                "used_gb": 234,
                "free_gb": 456,
                "compression_ratio": 1.8,
                "dedup_ratio": 1.2
            }
        ]
    },
    "network": {
        "interfaces": [
            {
                "name": "eth0",
                "rx_mbps": 450.2,
                "tx_mbps": 123.4,
                "rx_packets": 154000,
                "tx_packets": 89000,
                "rx_errors": 0,
                "tx_drops": 2,
                "tcp_retransmits": 12
            }
        ],
        "connections": {
            "established": 1542,
            "time_wait": 340,
            "syn_recv": 12,
            "close_wait": 3  # Potential leak indicator
        }
    },
    "containers": {
        "running": 45,
        "cpu_throttled": 2,
        "oom_killed": 0,
        "restarts": 1
    },
    "services": {
        "postgresql": {
            "status": "healthy",
            "connections": 45,
            "slow_queries": 3,
            "lock_waits": 0,
            "replication_lag_ms": 12
        },
        "nginx": {
            "status": "healthy",
            "requests_per_sec": 4500,
            "error_rate": 0.001,
            "p99_latency_ms": 45
        }
    }
}
```

### 2. Anomaly Detection (The Instinct)

Learns normal patterns, flags deviations:

```python
# How it works
1. Baseline learning (first 7 days):
   - Collect metrics every 10 seconds
   - Build statistical distributions per metric
   - Learn correlations (CPU↑ → temp↑, traffic↑ → latency↑)

2. Real-time scoring:
   - Z-score for each metric
   - Multivariate anomaly (isolation forest)
   - Sequence anomaly (LSTM autoencoder)

3. Severity classification:
   - INFO: Minor deviation, worth noting
   - WARNING: Unusual pattern, investigate
   - CRITICAL: Likely failure imminent, act now
```

Example detections:
- "Database query latency jumped from 5ms to 200ms baseline"
- "Memory usage growing at 2GB/hour, will OOM in 6 hours"
- "SSH login from new IP at 3am (unusual time)"
- "Container restarting every 30 seconds (crash loop)"
- "Disk I/O latency spiking during scheduled backup (expected)"

### 3. Forecasting (The Foresight)

Predicts future state:

```python
# Predictive alerts (sent before problems happen)
[Sentinel] Forecast: Disk /var/log will reach 90% in 4.2 hours
         at current growth rate (12MB/hour). 
         Recommended action: Rotate logs or expand volume.

[Sentinel] Forecast: Database connection pool will exhaust 
         in 15 minutes at current request rate (450/sec).
         Recommended action: Increase max_connections or add read replica.

[Sentinel] Forecast: CPU thermal throttling likely in 30 minutes
         based on load pattern and ambient temperature trend.
         Recommended action: Schedule workload to cooler period or improve cooling.
```

### 4. Self-Healing (The Reflex)

Automatic responses to common issues:

| Problem | Detection | Automatic Action | Notification |
|---------|-----------|-----------------|--------------|
| Service crash | Process exit code != 0 | Restart container, escalate if >3 restarts | Slack: "Restarted nginx (crash #1)" |
| Disk full | >90% usage | Clean temp files, rotate logs | Slack: "Freed 5GB from /tmp" |
| Memory leak | Steady growth over 6h | Restart service, capture heap dump | Slack: "Restarted app-service, heap dump saved" |
| DDoS attack | >10k conn/sec from single IP | Block IP at firewall, enable rate limit | Alert: "Blocked IP 1.2.3.4 (DDoS)" |
| DB slow query | >5s execution | Kill query, suggest index | Slack: "Killed slow query #12345" |
| SSL cert expiry | <30 days remaining | Auto-renew via Let's Encrypt | Slack: "Renewed cert for example.com" |
| Zombie processes | >100 zombies | Reap or notify parent process | Info: "Cleaned 45 zombie processes" |

### 5. Natural Language Interface (The Voice)

```bash
# Interactive mode
$ sentinel
Sentinel v2.0.0 | Server: homelab-01 | Uptime: 45 days

sentinel> What's the status?
[Analyzing 847 metrics across 12 subsystems...]
✓ All systems healthy
⚠ 1 advisory: Docker image postgres:15 has security update available
ℹ Load average: 0.45 (idle), 23°C ambient

sentinel> Why was the website slow at 2pm?
[Querying logs and metrics for 2024-07-10 14:00...]
At 14:03, a backup job (cron.daily) started a full ZFS send 
to the offsite server, saturating the network link (1Gbps).
This caused Nginx upstream timeouts (p99 latency: 4.2s).
The backup completed at 14:47. Website performance returned to normal.
Recommendation: Schedule backups during low-traffic hours (02:00-06:00).

sentinel> Deploy Nextcloud with 100GB storage and auto-backup
[Executing deployment plan...]
✓ Created ZFS dataset: tank/nextcloud (100GB quota)
✓ Deployed Nextcloud container (nextcloud:28-apache)
✓ Configured PostgreSQL database
✓ Set up Redis for caching
✓ Configured automated backup to S3 (daily at 02:00)
✓ Generated admin credentials (saved to Vault)
Access: https://nextcloud.your-domain.com
Admin: admin / [auto-generated, check Vault]

sentinel> Show me a security audit
[Running CIS benchmark scan...]
[Analyzing network traffic for anomalies...]
[Checking for known CVEs in installed packages...]

Security Score: 87/100 (Good)

Findings:
⚠ Medium: SSH password authentication still enabled
   Fix: sentinel "Disable SSH passwords, enforce keys only"
   
⚠ Medium: 3 packages with CVE-2024-XXXX (high severity)
   Fix: sentinel "Update packages with CVE-2024-XXXX"
   
ℹ Info: Firewall blocking 12 IPs from failed SSH attempts
   (auto-blocked by CrowdSec integration)

sentinel> Fix all security issues
[Executing fixes...]
✓ Disabled SSH password auth
✓ Updated 3 vulnerable packages
✓ No action needed for firewall (already handled)
Security Score: 96/100 (Excellent)
```

## Configuration

```yaml
# /etc/sentinel/sentinel.yaml
server:
  name: "homelab-01"
  role: "home-server"  # home-server | cloud | edge | database | web
  location: "closet"
  timezone: "Asia/Shanghai"

ai:
  model:
    type: "local"  # local | api | hybrid
    path: "/var/lib/sentinel/models/llama-3.1-8b-sentinel.Q4_K_M.gguf"
    context_length: 32768
    gpu_layers: -1  # all on GPU
  
  personality:
    name: "Sentinel"
    style: "concise"  # concise | detailed | friendly | formal
    proactive: true   # Suggest actions without being asked
    
  memory:
    vector_db: "chroma"  # chroma | pgvector
    history_retention: "90d"
    
observability:
  collection_interval: "10s"
  retention: "30d"
  
  ebpf:
    enabled: true
    programs:
      - "tcp_connect"
      - "tcp_close"
      - "sched_switch"
      - "page_fault"
      - "block_io"
      - "vfs_read"
      - "vfs_write"
      
  metrics:
    - "cpu"
    - "memory"
    - "disk"
    - "network"
    - "thermal"
    - "power"
    
alerting:
  channels:
    - type: "slack"
      webhook: "${SLACK_WEBHOOK_URL}"
      severity: ["warning", "critical"]
    - type: "email"
      smtp: "smtp.gmail.com"
      to: "admin@example.com"
      severity: ["critical"]
    - type: "pushover"
      token: "${PUSHOVER_TOKEN}"
      severity: ["critical"]
      
  rules:
    - name: "high_cpu"
      condition: "cpu.usage > 80% for 5m"
      severity: "warning"
      auto_action: "notify"
      
    - name: "disk_full"
      condition: "disk.usage > 90%"
      severity: "critical"
      auto_action: "clean_temp"
      
    - name: "oom_risk"
      condition: "memory.available < 5%"
      severity: "critical"
      auto_action: "kill_largest_process"
      
    - name: "security_anomaly"
      condition: "ssh.failed_logins > 10 from single_ip in 1m"
      severity: "critical"
      auto_action: "block_ip"

auto_healing:
  enabled: true
  max_restarts_per_hour: 5
  escalation_delay: "10m"
  
  actions:
    service_crash:
      - "restart_container"
      - "if_restart_fails: notify_admin"
      
    memory_leak:
      - "capture_heap_dump"
      - "restart_service"
      - "notify_admin"
      
    disk_full:
      - "rotate_logs"
      - "clean_tmp"
      - "if_still_full: notify_admin"

workloads:
  pre_install:
    - "docker"
    - "k3s"
    - "postgresql"
    - "redis"
    - "nginx"
    - "prometheus"
    - "grafana"
    
  home_server_addons:
    - "jellyfin"
    - "nextcloud"
    - "pihole"
    - "home-assistant"
    - "wireguard"
    - "minio"
```

## Installation

```bash
# 1. Install Sentinel Core
sudo mkdir -p /opt/sentinel
cd /opt/sentinel
sudo python3 -m venv venv
source venv/bin/activate
pip install sentinel-core

# 2. Install kernel module (optional but recommended)
cd /opt/sentinel/kernel-module
make
sudo insmod kirat-ai.ko

# 3. Configure
sudo mkdir -p /etc/sentinel
sudo cp config/sentinel.yaml /etc/sentinel/
# Edit with your settings

# 4. Start
sudo systemctl enable sentinel
sudo systemctl start sentinel

# 5. Verify
sentinel status
sentinel "Hello, are you there?"
```

## API Reference

### REST API
```
GET  /api/v1/status              → System overview
GET  /api/v1/metrics             → All metrics (JSON)
GET  /api/v1/metrics/{category}  → CPU, memory, disk, network
GET  /api/v1/alerts              → Active alerts
POST /api/v1/query               → Natural language query
POST /api/v1/action              → Execute action
GET  /api/v1/logs                → Structured logs
GET  /api/v1/events              → Real-time events (SSE)
```

### WebSocket (Real-time)
```javascript
const ws = new WebSocket('wss://server:8443/ws');
ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    // data.type: 'metric' | 'alert' | 'event' | 'response'
    // data.payload: actual data
};

// Send natural language command
ws.send(JSON.stringify({
    type: 'command',
    text: 'Why is CPU usage high?'
}));
```

## Performance

| Metric | Target |
|--------|--------|
| Metric collection | < 5ms per sample |
| Anomaly detection | < 100ms latency |
| AI response | < 2 seconds |
| Memory footprint | < 512MB |
| CPU overhead | < 2% of one core |
| Event throughput | 10,000 events/sec |

## License

GPL-3.0
