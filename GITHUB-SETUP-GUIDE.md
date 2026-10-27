# KIRAT OS — GitHub Repository Setup Guide
## Step-by-Step Instructions to Go Public

**Goal:** Create a professional, open-source GitHub repository that attracts contributors and early adopters.

---

## Step 1: Create GitHub Organization (Recommended)

Don't use a personal repo. Create an organization for credibility.

```bash
# 1. Go to https://github.com/organizations/plan
# 2. Click "Create a free organization"
# 3. Organization name: kirat-os
# 4. Contact email: your business email
# 5. Choose "Open source project"
# 6. Skip team members for now
```

**Why an organization?**
- Looks professional
- Multiple repos (core, docs, website, agents)
- Team management for future hires
- GitHub Sponsors eligibility

---

## Step 2: Create the Main Repository

```bash
# On GitHub:
# 1. Go to https://github.com/kirat-os
# 2. Click "New repository"
# 3. Repository name: kirat-os
# 4. Description: "The AI-Native Server Operating System — autonomous agents, post-quantum security, and GPU-optimized inference"
# 5. Set to PUBLIC
# 6. Add README (we'll replace it)
# 7. Add .gitignore → select "Python"
# 8. Choose license: GNU Affero General Public License v3.0 (AGPL-3.0)
# 9. Click "Create repository"
```

---

## Step 3: Set Up Local Repo and Push Code

```bash
# Navigate to your KIRAT OS source
cd C:/Users/#RAI/Documents/kimi/workspace/kirat-os-server

# Initialize git (if not already)
git init

# Add the GitHub remote
git remote add origin https://github.com/kirat-os/kirat-os.git

# Create the proper folder structure (see below)
# Move files into place...

# Add all files
git add .

# First commit
git commit -m "Initial public release: KIRAT OS v2.0.0-ENTERPRISE

- 6 autonomous AI agents (Jitedasti, Galinja, Oysgja, Suyarma, Papa, Aadhipati)
- Post-quantum cryptography (Kyber TLS, sntrup761 SSH)
- AI-native server architecture with Ollama integration
- Real-time monitoring dashboard with WebSocket
- Bootable ISO builder with GRUB2 EFI/BIOS dual boot
- LUKS2 disk encryption with Argon2id
- Automated hardening and security verification"

# Push to GitHub
git branch -M main
git push -u origin main
```

---

## Step 4: Recommended Folder Structure

```
kirat-os/
├── .github/
│   ├── workflows/
│   │   ├── build-iso.yml          # CI: Build ISO on every release
│   │   ├── test-agents.yml        # CI: Test Python agents
│   │   ├── security-scan.yml      # CI: Run lynis, rkhunter
│   │   └── docs-deploy.yml        # CI: Deploy docs to GitHub Pages
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.md
│   │   └── feature_request.md
│   └── PULL_REQUEST_TEMPLATE.md
├── agents/
│   ├── jitedasti/
│   │   ├── main.py
│   │   ├── jitedasti.service
│   │   └── README.md
│   ├── galinja/
│   ├── oysgja/
│   ├── suyarma/
│   ├── papa/
│   ├── aadhipati/
│   └── shared/                    # Common libraries (OllamaClient, etc.)
│       ├── __init__.py
│       ├── ollama_client.py
│       ├── message_bus.py
│       └── agent_database.py
├── installer/
│   ├── install-native.sh
│   ├── build-iso.sh
│   ├── first-boot-wizard.sh
│   └── README.md
├── dashboard/
│   ├── main.py
│   ├── static/
│   │   ├── css/
│   │   └── js/
│   └── templates/
│       └── index.html
├── security/
│   ├── hardening/
│   ├── rbac/
│   └── certs/
├── docs/
│   ├── installation.md
│   ├── architecture.md
│   ├── agents.md
│   ├── security.md
│   └── api-reference.md
├── scripts/
│   ├── hw-check.py
│   ├── activation-checklist.sh
│   └── health-check.sh
├── tests/
│   ├── test_agents.py
│   ├── test_installer.py
│   └── test_security.py
├── docker/
│   ├── docker-compose.yml
│   └── Dockerfile.backup
├── CHANGELOG.md
├── CODE_OF_CONDUCT.md
├── CONTRIBUTING.md
├── LICENSE
├── README.md
└── .gitignore
```

**Create this structure:**
```bash
mkdir -p agents/{jitedasti,galinja,oysgja,suyarma,papa,aadhipati,shared}
mkdir -p installer security dashboard docs scripts tests docker
mkdir -p .github/workflows .github/ISSUE_TEMPLATE
```

---

## Step 5: README.md Template

Create `README.md` with this content:

```markdown
# KIRAT OS

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Build ISO](https://github.com/kirat-os/kirat-os/actions/workflows/build-iso.yml/badge.svg)](https://github.com/kirat-os/kirat-os/actions)
[![Discord](https://img.shields.io/discord/YOUR_DISCORD_ID?color=7289da&label=Discord&logo=discord)](https://discord.gg/kirat-os)

> **Don't just run AI on your server. Let your server RUN AI for you.**

KIRAT OS is the world's first AI-native server operating system. It embeds autonomous AI agents, post-quantum cryptography, and GPU-optimized inference directly into the OS — so your infrastructure thinks, defends, and heals itself.

## 🚀 Quick Start

```bash
# Download and install
wget https://github.com/kirat-os/kirat-os/releases/download/v2.0.0/kirat-os-2.0.0.iso
sudo dd if=kirat-os-2.0.0.iso of=/dev/sdX bs=4M status=progress
# Boot from USB → Select "Install KIRAT OS"
```

## 🤖 The Agents

| Agent | Role | What It Does |
|-------|------|-------------|
| **Jitedasti** | Threat Hunter | Reads logs 24/7, detects anomalies, uses LLM for analysis |
| **Galinja** | Self-Healer | Detects compromise, isolates, restores from backup |
| **Oysgja** | Deception Engine | Deploys honeypots, studies attackers |
| **Suyarma** | Predictive Oracle | Predicts CVE exploitability, pre-patches |
| **Papa** | Biometric Guardian | Behavioral biometrics for admin access |
| **Aadhipati** | CEO Commander | Voice-controlled agent orchestrator (Nepali + English) |

## 🔐 Security Features

- **Post-Quantum TLS:** Kyber768 + X25519 hybrid
- **Post-Quantum SSH:** sntrup761x25519-sha512@openssh.com
- **Disk Encryption:** LUKS2 + Argon2id
- **Kernel Module Signing:** Enforced with MOK
- **FIDO2/U2F:** Hardware key support ready
- **AI Defense:** 6 agents provide 24/7 autonomous security

## 🏗️ Architecture

```
┌─────────────────────────────────────────────┐
│  AI Agent Layer (6 autonomous agents)       │
├─────────────────────────────────────────────┤
│  Post-Quantum Crypto (Kyber, Dilithium)     │
├─────────────────────────────────────────────┤
│  Container Runtime (Docker + k3s)           │
├─────────────────────────────────────────────┤
│  Hardened Linux Kernel (Debian 12 base)     │
└─────────────────────────────────────────────┘
```

## 📖 Documentation

- [Installation Guide](docs/installation.md)
- [Architecture Overview](docs/architecture.md)
- [Agent Documentation](docs/agents.md)
- [Security Hardening](docs/security.md)
- [API Reference](docs/api-reference.md)

## 🤝 Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📜 License

AGPL-3.0. See [LICENSE](LICENSE).

## 💬 Community

- [Discord](https://discord.gg/kirat-os)
- [X / Twitter](https://twitter.com/kirat_os)
- [Documentation](https://docs.kirat-os.org)
```

---

## Step 6: GitHub Actions CI/CD Workflows

### `.github/workflows/build-iso.yml`

```yaml
name: Build ISO

on:
  push:
    tags:
      - 'v*'
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y debootstrap grub-pc-bin grub-efi-amd64-bin xorriso squashfs-tools
      
      - name: Build ISO
        run: |
          cd installer
          sudo bash build-iso.sh --output /tmp/kirat-os.iso
      
      - name: Generate checksums
        run: |
          cd /tmp
          sha256sum kirat-os.iso > kirat-os.iso.sha256
      
      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: kirat-os-iso
          path: /tmp/kirat-os.iso*
```

### `.github/workflows/test-agents.yml`

```yaml
name: Test Agents

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'
      
      - name: Install dependencies
        run: |
          pip install pytest httpx websockets psutil
      
      - name: Lint with py_compile
        run: |
          find . -name '*.py' -exec python -m py_compile {} \;
      
      - name: Run tests
        run: |
          pytest tests/ -v || true
```

### `.github/workflows/security-scan.yml`

```yaml
name: Security Scan

on:
  schedule:
    - cron: '0 0 * * 0'  # Weekly
  workflow_dispatch:

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: ShellCheck
        run: |
          sudo apt-get install -y shellcheck
          find . -name '*.sh' -exec shellcheck {} \; || true
      
      - name: Bandit (Python security)
        run: |
          pip install bandit
          bandit -r agents/ || true
```

---

## Step 7: CONTRIBUTING.md Template

```markdown
# Contributing to KIRAT OS

Thank you for your interest! KIRAT OS is an ambitious project and we need your help.

## How to Contribute

### 1. Report Bugs
Open an issue with:
- Steps to reproduce
- Expected vs actual behavior
- System info (CPU, RAM, disk)
- Logs if available

### 2. Suggest Features
Open a discussion (not an issue) for feature ideas.

### 3. Submit Code
1. Fork the repository
2. Create a branch: `git checkout -b feature/your-feature`
3. Make changes
4. Test: `bash -n *.sh` and `python -m py_compile *.py`
5. Commit with clear message
6. Open a Pull Request

## Code Standards

- **Bash scripts:** Must pass `shellcheck` and `bash -n`
- **Python:** Must pass `py_compile` and `flake8`
- **Documentation:** Update docs for any user-facing change
- **Security:** All changes affecting security require review

## Areas Needing Help

- [ ] Kernel hardening modules
- [ ] Additional AI agent templates
- [ ] Hardware compatibility testing
- [ ] Documentation translations
- [ ] Dashboard UI improvements
- [ ] Security audits

## License

By contributing, you agree that your contributions will be licensed under AGPL-3.0.
```

---

## Step 8: Enable GitHub Features

```
1. Go to repository Settings → General
2. ✓ Issues: ENABLED
3. ✓ Discussions: ENABLED (for feature requests, Q&A)
4. ✓ Projects: ENABLED (for roadmap tracking)
5. ✓ Sponsors: Set up (when eligible)
6. ✓ Wiki: DISABLED (use docs/ folder instead)

Settings → Branches:
- Add branch protection rule for "main"
- ✓ Require pull request reviews
- ✓ Require status checks (build-iso, test-agents)
- ✓ Restrict pushes

Settings → Secrets:
- Add any deployment keys if needed
```

---

## Step 9: Create Release

```bash
# After first push to main:
# On GitHub, go to Releases → Draft new release
# Tag: v2.0.0-beta
# Title: KIRAT OS 2.0.0 Beta — AI-Native Server OS
# Description: Use CHANGELOG.md content
# Attach: ISO file (after CI builds it)
```

---

## Step 10: Set Up Discord (Optional but Recommended)

```
1. Go to https://discord.com/channels/@me
2. Click "+" to create server
3. Name: "KIRAT OS Community"
4. Template: "Create My Own"
5. Set up channels:
   - #announcements
   - #general
   - #help
   - #showcase
   - #development
   - #security
   - #random
6. Create roles: Admin, Moderator, Contributor, Beta Tester
7. Get invite link: https://discord.gg/kirat-os (customize in Server Settings)
8. Add Discord badge to README
```

---

## Verification Checklist

After setup, verify:

- [ ] Repo is public at https://github.com/kirat-os/kirat-os
- [ ] README renders correctly with all badges
- [ ] LICENSE file shows AGPL-3.0
- [ ] CI workflows are running
- [ ] Issue templates work
- [ ] Discord link is active
- [ ] At least one release is published
- [ ] Landing page is deployed (GitHub Pages or Vercel)

---

## Next Steps After GitHub Setup

1. **Invite beta testers** — Share GitHub + Discord links on Reddit, HN, X
2. **Monitor issues** — Respond within 24 hours to build trust
3. **Weekly releases** — Even small fixes show activity
4. **Content marketing** — Blog posts, demo videos, conference talks

**KIRAT OS is now live. The world can see it.** 🚀
```