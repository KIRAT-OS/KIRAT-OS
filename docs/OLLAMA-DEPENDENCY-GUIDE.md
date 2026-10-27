# KIRAT OS - Ollama Dependency Guide

## Do You Need Ollama on Every Device?

**Short Answer: NO** — You have several deployment options depending on your needs.

---

## Deployment Architecture Options

### Option 1: Centralized AI Server (Recommended for Multi-Device)

```
┌─────────────────────────────────────────────────────────────┐
│                    YOUR NETWORK                              │
│                                                              │
│  ┌─────────────┐      ┌──────────────────────────────┐     │
│  │  Device 1   │◄────►│                              │     │
│  │ (Phone)     │      │   KIRAT OS AI Server          │     │
│  └─────────────┘      │   ┌─────────────────────┐    │     │
│  ┌─────────────┐      │   │  Ollama (gemma4)    │    │     │
│  │  Device 2   │◄────►│   │  Sentinel AI v2.0   │    │     │
│  │ (Tablet)    │      │   │  Quantum Engine     │    │     │
│  └─────────────┘      │   └─────────────────────┘    │     │
│  ┌─────────────┐      │                              │     │
│  │  Device 3   │◄────►│   IP: 192.168.1.100        │     │
│  │ (Laptop)    │      │   Port: 11434 (Ollama)       │     │
│  └─────────────┘      │   Port: 3000 (Sentinel)      │     │
│  ┌─────────────┐      │   Port: 8080 (Dashboard)     │     │
│  │  Device 4   │◄────►│                              │     │
│  │ (Desktop)   │      └──────────────────────────────┘     │
│  └─────────────┘                                            │
│                                                              │
│  All devices connect to ONE centralized AI server           │
│  No Ollama needed on phones/tablets                           │
└─────────────────────────────────────────────────────────────┘
```

**How it works:**
- Install KIRAT OS + Ollama on ONE powerful server/PC
- All other devices connect via network
- Phones use web dashboard or SSH to access AI
- Only the server needs GPU/RAM for AI

**Pros:**
- ✅ One Ollama installation serves all devices
- ✅ Phones/tablets don't need powerful hardware
- ✅ Centralized management and updates
- ✅ Shared AI models across all devices

**Cons:**
- ⚠️ Requires network connection to server
- ⚠️ Server must be online 24/7 for always-available AI

---

### Option 2: Standalone Per-Device

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Device 1   │    │  Device 2   │    │  Device 3   │
│  KIRAT OS    │    │  KIRAT OS    │    │  KIRAT OS    │
│  + Ollama   │    │  + Ollama   │    │  + Ollama   │
│  (gemma4)   │    │  (gemma4)   │    │  (gemma4)   │
│             │    │             │    │             │
│ Independent │    │ Independent │    │ Independent │
│ No network  │    │ No network  │    │ No network  │
│ required    │    │ required    │    │ required    │
└─────────────┘    └─────────────┘    └─────────────┘
```

**How it works:**
- Each device runs its own complete KIRAT OS + Ollama
- No network dependency between devices
- Each device manages its own AI models

**Pros:**
- ✅ Works offline completely
- ✅ No single point of failure
- ✅ Each device has full AI autonomy

**Cons:**
- ⚠️ Each device needs 8GB+ RAM for AI
- ⚠️ Models downloaded on each device (storage)
- ⚠️ More setup time per device

---

### Option 3: Hybrid (Edge + Cloud)

```
┌─────────────────────────────────────────────────────────────┐
│                    YOUR NETWORK                              │
│                                                              │
│  ┌─────────────┐      ┌──────────────────────────────┐     │
│  │  Home Server│◄────►│   Cloud VPS (Optional)       │     │
│  │  (KIRAT OS)  │      │   ┌─────────────────────┐    │     │
│  │  + Ollama   │      │   │  Ollama (qwen3.6)   │    │     │
│  │  (gemma4)   │      │   │  Backup AI          │    │     │
│  └─────────────┘      │   └─────────────────────┘    │     │
│         ▲              │        (AWS/DO/Linode)       │     │
│         │              └──────────────────────────────┘     │
│    ┌────┴────┐                                              │
│    │         │                                              │
│ ┌──┴──┐   ┌─┴──┐                                           │
│ │Phone│   │Tab │    Devices use local server first,         │
│ │     │   │    │    fallback to cloud if away from home      │
│ └─────┘   └────┘                                            │
└─────────────────────────────────────────────────────────────┘
```

**How it works:**
- Primary: Home server with Ollama
- Secondary: Cloud VPS with Ollama (for remote access)
- Devices auto-switch based on network location

---

## Which Option Should You Choose?

| Scenario | Recommended Option | Why |
|----------|-------------------|-----|
| Multiple devices at home/office | **Option 1: Centralized** | One server, all devices share |
| Single laptop/server | **Option 2: Standalone** | Simple, no network config |
| Travel + home use | **Option 3: Hybrid** | Local at home, cloud when away |
| Phones/tablets only | **Option 1: Centralized** | They can't run Ollama well |
| No internet (air-gapped) | **Option 2: Standalone** | Each device fully independent |

---

## Device-Specific Requirements

### Can Run Ollama (Standalone capable)
| Device | RAM Needed | Can Run? |
|--------|-----------|----------|
| Desktop PC (i7, 32GB) | 8GB+ | ✅ Yes |
| Laptop (i7, 16GB) | 8GB+ | ✅ Yes |
| Mini PC (N100, 8GB) | 8GB+ | ⚠️ Slow but works |
| Raspberry Pi 5 (8GB) | 8GB+ | ⚠️ Very slow |
| Old laptop (4GB) | 8GB+ | ❌ No |

### Cannot Run Ollama (Must use Centralized)
| Device | Why? |
|--------|------|
| Android Phone | ARM architecture, limited RAM |
| iPhone/iPad | iOS restrictions, no Ollama app |
| Chromebook | Limited Linux support |
| Smart TV | No Ollama support |
| IoT devices | Too little RAM/CPU |

---

## How to Configure Centralized AI Server

### On Your AI Server (the one with Ollama):

```bash
# 1. Allow remote connections to Ollama
sudo systemctl edit ollama

# Add this:
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"

# 2. Restart Ollama
sudo systemctl restart ollama

# 3. Open firewall
sudo ufw allow 11434/tcp
sudo ufw allow 3000/tcp   # Sentinel API
sudo ufw allow 8080/tcp   # Dashboard
```

### On Client Devices (no Ollama needed):

```bash
# Just point to the AI server
export OLLAMA_HOST=http://192.168.1.100:11434
export SENTINEL_API=http://192.168.1.100:3000

# Access dashboard from any browser
# http://192.168.1.100:8080
```

---

## Quick Reference: Do I Need Ollama Here?

| Location | Need Ollama? | Notes |
|----------|-------------|-------|
| Main server/PC | ✅ **YES** | This is your AI brain |
| Your phone | ❌ **NO** | Use web dashboard |
| Your tablet | ❌ **NO** | Use web dashboard |
| Friend's laptop | ❌ **NO** | Connect to your server |
| Work computer | ❌ **NO** | Connect to your server |
| Cloud VPS | ✅ **YES** | If using hybrid mode |
| Backup server | ✅ **YES** | Redundancy |

---

## Summary

**For your setup (Windows 10 laptop + Ollama already installed):**

Your laptop is the **AI Server**. All other devices connect to it:
- **Phone**: Open browser → `http://your-laptop-ip:8080`
- **Tablet**: Open browser → `http://your-laptop-ip:8080`
- **Other PCs**: SSH or browser to your laptop

**No Ollama needed on phones/tablets.** They just need a web browser.

**To find your laptop's IP:**
```cmd
# On Windows
ipconfig
# Look for "IPv4 Address" under your Wi-Fi adapter
```

**Then on your phone:**
```
http://192.168.1.xxx:8080  ← Your laptop's IP
```

---

## Security Note

When exposing Ollama to your network:
- Use firewall rules (only allow local network)
- Enable HTTPS via `fix-pending.sh` (Kyber768+X25519)
- Use SSH tunnel for remote access: `ssh -L 8080:localhost:8080 sentinel@your-server`
- Never expose port 11434 to the public internet without authentication
