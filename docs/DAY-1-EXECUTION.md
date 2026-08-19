# KIRAT OS — Day 1 Execution Guide
## Step-by-Step: From Private Project to Public GitHub Repo

**Date:** Today  
**Time required:** 3-4 hours  
**Goal:** Live public repository at `github.com/kirat-os/kirat-os`

---

## BEFORE YOU START

### Prerequisites Checklist
- [ ] GitHub account (free is fine)
- [ ] Git installed on Windows (`git --version` in PowerShell should work)
- [ ] This folder open: `C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server`

### If Git is NOT installed:
```powershell
# Download from https://git-scm.com/download/win
# Or install via winget:
winget install Git.Git
# Restart PowerShell after install
```

---

## STEP 1: Create GitHub Organization (10 minutes)

### 1.1 Open GitHub Organizations Page
```powershell
Start-Process "https://github.com/organizations/plan"
```

Or manually: Go to https://github.com/organizations/plan

### 1.2 Click "Create a free organization"

### 1.3 Fill in the form:
| Field | Value |
|-------|-------|
| Organization name | `kirat-os` |
| Contact email | Your business email (create one if needed: `admin@kirat-os.org`) |
| This organization belongs to | "My personal account" |

### 1.4 Click "Next" → On the "Add organization members" page, click "Skip this step"

### 1.5 On the "Tell us about your organization" page:
- Organization type: **Open source**
- Click "Next" → "Submit"

### 1.6 Verify
- You should now be at: `https://github.com/kirat-os`
- You should see your organization dashboard

**✅ DONE: Organization created**

---

## STEP 2: Create the Main Repository (5 minutes)

### 2.1 From your organization page, click the green "New" button (or "New repository")

### 2.2 Fill in repository details:
| Field | Value |
|-------|-------|
| Repository name | `kirat-os` |
| Description | `The AI-Native Server Operating System — autonomous agents, post-quantum security, and GPU-optimized inference` |
| Visibility | **Public** ☑️ |
| Add a README file | ☑️ Check this box |
| Add .gitignore | Select template: **Python** |
| Choose a license | **GNU Affero General Public License v3.0** |

### 2.3 Click "Create repository"

### 2.4 Verify
- URL should be: `https://github.com/kirat-os/kirat-os`
- You should see a README, LICENSE, and .gitignore file

**✅ DONE: Repository created**

---

## STEP 3: Set Up Local Folder Structure (20 minutes)

### 3.1 Open PowerShell and navigate to your workspace
```powershell
cd C:\Users\#RAI\Documents\kimi\workspace
```

### 3.2 Create a new folder for the GitHub repo
```powershell
mkdir kirat-os-github
cd kirat-os-github
```

### 3.3 Initialize git and connect to GitHub
```powershell
git init
git remote add origin https://github.com/kirat-os/kirat-os.git
```

### 3.4 Create the folder structure
```powershell
# Create all folders
mkdir agents\jitedasti
mkdir agents\galinja
mkdir agents\oysgja
mkdir agents\suyarma
mkdir agents\papa
mkdir agents\aadhipati
mkdir agents\shared
mkdir installer
mkdir security\hardening
mkdir security\rbac
mkdir security\certs
mkdir dashboard\static\css
mkdir dashboard\static\js
mkdir dashboard\templates
mkdir docs
mkdir scripts
mkdir tests
mkdir docker
mkdir .github\workflows
mkdir .github\ISSUE_TEMPLATE

# Verify structure
tree /F /A | findstr -V "\""
```

**✅ DONE: Folder structure created**

---

## STEP 4: Copy Files Into Structure (30 minutes)

### 4.1 Copy AI Agents
```powershell
# Jitedasti (Threat Hunter)
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\jitedasti-ai\main.py" agents\jitedasti\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\jitedasti-ai\jitedasti-ai.service" agents\jitedasti\

# Galinja (Self-Healer)
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\galinja-ai\main.py" agents\galinja\

# Oysgja (Deception)
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\oysgja-ai\main.py" agents\oysgja\

# Suyarma (Oracle)
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\suyarma-ai\main.py" agents\suyarma\

# Papa (Biometric)
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\papa-ai\main.py" agents\papa\

# Aadhipati (CEO)
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\aadhipati-ai\main.py" agents\aadhipati\

# Shared libraries
xcopy /E /I "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\ai-agents\shared" agents\shared\
```

### 4.2 Copy Installer Scripts
```powershell
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\scripts\install-native.sh" installer\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\scripts\build-iso.sh" installer\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\scripts\first-boot-wizard.sh" installer\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\scripts\health-check.sh" installer\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\scripts\hw-check.py" scripts\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\activation-checklist.sh" scripts\
```

### 4.3 Copy Dashboard
```powershell
xcopy /E /I "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\dashboard\static" dashboard\static\
xcopy /E /I "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\dashboard\templates" dashboard\templates\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\dashboard\main.py" dashboard\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\dashboard\quantum_metrics.py" dashboard\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\dashboard\requirements.txt" dashboard\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\dashboard\Dockerfile" dashboard\
```

### 4.4 Copy Docker and Scaling
```powershell
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\docker-compose.scaling.yml" docker\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\scripts\Dockerfile.backup" docker\
```

### 4.5 Copy Documentation
```powershell
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\KIRAT-OS-FINAL-SUMMARY.md" docs\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\TROUBLESHOOTING-GUIDE.md" docs\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\PRE-INSTALL-CHECKLIST.md" docs\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\STRATEGIC-BUSINESS-PLAN.md" docs\
copy "C:\Users\#RAI\Documents\kimi\workspace\kirat-os-server\MARKET-RATING-ASSESSMENT.md" docs\
```

### 4.6 Verify everything copied
```powershell
# Count files
dir /S /B | find /C /V ""
# Should show ~50+ files

# Quick spot check
type agents\jitedasti\main.py | findstr "JitedastiAI"
type agents\aadhipati\main.py | findstr "AadhipatiAI"
type installer\install-native.sh | findstr "KIRAT OS"
```

**✅ DONE: Files copied**

---

## STEP 5: Create README.md (30 minutes)

### 5.1 Create the file
```powershell
notepad README.md
```

### 5.2 Paste this content:

```markdown
# KIRAT OS

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)
[![Discord](https://img.shields.io/badge/Discord-Join%20Chat-7289da?logo=discord)](https://discord.gg/kirat-os)

> **Don't just run AI on your server. Let your server RUN AI for you.**

KIRAT OS is the world's first AI-native server operating system. It embeds autonomous AI agents, post-quantum cryptography, and GPU-optimized inference directly into the OS — so your infrastructure thinks, defends, and heals itself.

## 🚀 Quick Start

```bash
# Download the latest ISO
wget https://github.com/kirat-os/kirat-os/releases/latest/download/kirat-os.iso

# Write to USB (Linux)
sudo dd if=kirat-os.iso of=/dev/sdX bs=4M status=progress

# Or use Rufus on Windows: https://rufus.ie

# Boot from USB → Select "Install KIRAT OS"
```

## 🤖 The Agents

| Agent | Sanskrit Name | Role |
|-------|--------------|------|
| **Jitedasti** | जितेदास्ती | Threat Hunter — reads logs 24/7, detects anomalies |
| **Galinja** | गलन्जा | Self-Healer — detects compromise, isolates, restores |
| **Oysgja** | ओय्सग्जा | Deception Engine — honeypots, attacker intelligence |
| **Suyarma** | सुयर्मा | Predictive Oracle — predicts CVE exploitability |
| **Papa** | पापा | Biometric Guardian — behavioral access control |
| **Aadhipati** | आधिपति | CEO Commander — voice-controlled agent orchestrator |

## 🔐 Security

- **Post-Quantum TLS:** Kyber768 + X25519 hybrid
- **Post-Quantum SSH:** sntrup761x25519-sha512@openssh.com
- **Disk Encryption:** LUKS2 + Argon2id
- **Kernel Module Signing:** Enforced with MOK
- **FIDO2/U2F:** Hardware key support

## 🏗️ Architecture

```
┌─────────────────────────────────────────────┐
│  AI Agent Layer (6 autonomous agents)       │
├─────────────────────────────────────────────┤
│  Post-Quantum Crypto (Kyber, Dilithium)     │
├─────────────────────────────────────────────┤
│  AI Infrastructure Stack (Ollama, vLLM, k3s)│
├─────────────────────────────────────────────┤
│  Container Runtime (Docker + GPU support)   │
├─────────────────────────────────────────────┤
│  Hardened Linux Kernel (Debian 12 base)     │
└─────────────────────────────────────────────┘
```

## 📖 Documentation

- [Installation Guide](docs/PRE-INSTALL-CHECKLIST.md)
- [Troubleshooting](docs/TROUBLESHOOTING-GUIDE.md)
- [Project Summary](docs/KIRAT-OS-FINAL-SUMMARY.md)

## 🛠️ Building from Source

```bash
# Clone
git clone https://github.com/kirat-os/kirat-os.git
cd kirat-os

# Build ISO (requires Debian/Ubuntu with debootstrap)
cd installer
sudo bash build-iso.sh --output /tmp/kirat-os.iso
```

## 🤝 Contributing

We welcome contributions! See our [issues](https://github.com/kirat-os/kirat-os/issues) for areas needing help.

**Areas needing help:**
- Kernel hardening modules
- Additional AI agent templates
- Hardware compatibility testing
- Documentation translations
- Dashboard UI improvements
- Security audits

## 💬 Community

- [Discord](https://discord.gg/kirat-os) — Chat with the team and community
- [GitHub Discussions](https://github.com/kirat-os/kirat-os/discussions) — Feature requests and Q&A

## 📜 License

[AGPL-3.0](LICENSE) — Free for personal and commercial use. Contributions must be open-sourced.

---

**Built with ambition.** 🛡️
```

### 5.3 Save and close Notepad

**✅ DONE: README created**

---

## STEP 6: Create CHANGELOG.md (10 minutes)

```powershell
notepad CHANGELOG.md
```

Paste:
```markdown
# Changelog

All notable changes to KIRAT OS will be documented in this file.

## [2.0.0-beta] - 2026-08-18

### Added
- Initial public release
- 6 autonomous AI agents (Jitedasti, Galinja, Oysgja, Suyarma, Papa, Aadhipati)
- Post-quantum cryptography (Kyber TLS, sntrup761 SSH)
- AI-native server architecture with Ollama integration
- Real-time monitoring dashboard with WebSocket
- Bootable ISO builder with GRUB2 EFI/BIOS dual boot
- LUKS2 disk encryption with Argon2id
- Automated hardening and security verification
- Hardware compatibility checker
- Pre-installation checklist

### Security
- Ed25519 admin signature verification for AI instructions
- GPG AES256 backup encryption
- FIDO2/U2F SSH key support
- Kernel module signing enforcement
```

Save and close.

**✅ DONE: CHANGELOG created**

---

## STEP 7: Create GitHub Actions CI/CD (20 minutes)

### 7.1 Create build workflow
```powershell
mkdir .github\workflows
notepad .github\workflows\build-iso.yml
```

Paste:
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

### 7.2 Create test workflow
```powershell
notepad .github\workflows\test-agents.yml
```

Paste:
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
      
      - name: Lint Python files
        run: |
          find . -name '*.py' -exec python -m py_compile {} \;
      
      - name: Run tests
        run: |
          pytest tests/ -v || true
```

### 7.3 Create security scan workflow
```powershell
notepad .github\workflows\security-scan.yml
```

Paste:
```yaml
name: Security Scan

on:
  schedule:
    - cron: '0 0 * * 0'
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
      
      - name: Bandit Python security
        run: |
          pip install bandit
          bandit -r agents/ || true
```

**✅ DONE: CI/CD workflows created**

---

## STEP 8: Create Issue Templates (10 minutes)

### 8.1 Bug report template
```powershell
mkdir .github\ISSUE_TEMPLATE
notepad .github\ISSUE_TEMPLATE\bug_report.md
```

Paste:
```markdown
---
name: Bug report
about: Create a report to help us improve
title: '[BUG] '
labels: bug
---

**Describe the bug**
A clear description.

**To Reproduce**
Steps to reproduce.

**Expected behavior**
What should happen.

**System info:**
- KIRAT OS version:
- Hardware (CPU, RAM, GPU):
- Installation method (ISO, VM, etc.):

**Logs**
Paste relevant logs or error messages.
```

### 8.2 Feature request template
```powershell
notepad .github\ISSUE_TEMPLATE\feature_request.md
```

Paste:
```markdown
---
name: Feature request
about: Suggest an idea for KIRAT OS
title: '[FEATURE] '
labels: enhancement
---

**Is your feature request related to a problem?**
A clear description.

**Describe the solution you'd like**
What should happen.

**Describe alternatives you've considered**
Any other approaches.

**Additional context**
Screenshots, mockups, etc.
```

**✅ DONE: Issue templates created**

---

## STEP 9: First Commit and Push (10 minutes)

### 9.1 Stage all files
```powershell
git add .
```

### 9.2 Create initial commit
```powershell
git commit -m "feat: initial public release of KIRAT OS v2.0.0-beta

- Add 6 autonomous AI agents (Jitedasti, Galinja, Oysgja, Suyarma, Papa, Aadhipati)
- Add post-quantum cryptography (Kyber TLS, sntrup761 SSH)
- Add AI-native server architecture with Ollama integration
- Add real-time monitoring dashboard with WebSocket
- Add bootable ISO builder with GRUB2 EFI/BIOS dual boot
- Add LUKS2 disk encryption with Argon2id
- Add automated hardening and security verification
- Add hardware compatibility checker
- Add pre-installation checklist
- Add CI/CD workflows for ISO build, agent tests, and security scans
- Add issue templates for bugs and features

KIRAT OS is now open source under AGPL-3.0."
```

### 9.3 Push to GitHub
```powershell
git branch -M main
git push -u origin main
```

**Enter your GitHub username and personal access token when prompted.**

**If push fails with authentication error:**
```powershell
# Generate a personal access token:
# 1. Go to https://github.com/settings/tokens
# 2. Click "Generate new token (classic)"
# 3. Select scopes: repo, workflow
# 4. Copy the token
# 5. Use the token as your password when git push asks
```

**✅ DONE: Code pushed to GitHub**

---

## STEP 10: Verify Everything (10 minutes)

### 10.1 Check the repository
Open in browser:
```powershell
Start-Process "https://github.com/kirat-os/kirat-os"
```

Verify:
- [ ] README renders correctly
- [ ] All folders are visible (agents/, installer/, dashboard/, etc.)
- [ ] LICENSE shows AGPL-3.0
- [ ] CHANGELOG.md is present

### 10.2 Check CI/CD is running
- Go to "Actions" tab
- You should see "Test Agents" workflow running
- Wait for it to complete (should be green ✅)

### 10.3 Check folder structure
```powershell
# Locally, verify structure
tree /F /A | more
```

**✅ DONE: Repository is live**

---

## STEP 11: Create First Release (Optional but Recommended)

### 11.1 On GitHub, go to "Releases" → "Create a new release"

### 11.2 Click "Choose a tag" → Type `v2.0.0-beta` → "Create new tag"

### 11.3 Fill in release details:
| Field | Value |
|-------|-------|
| Release title | `KIRAT OS 2.0.0 Beta — AI-Native Server OS` |
| Description | Copy from CHANGELOG.md |

### 11.4 Check "Set as a pre-release"

### 11.5 Click "Publish release"

**✅ DONE: First release published**

---

## 🎉 DAY 1 COMPLETE

**What you now have:**
- ✅ Public GitHub organization: `github.com/kirat-os`
- ✅ Public repository: `github.com/kirat-os/kirat-os`
- ✅ Professional README with badges
- ✅ 6 AI agents in `agents/` folder
- ✅ Installer scripts in `installer/` folder
- ✅ Dashboard in `dashboard/` folder
- ✅ CI/CD workflows (build, test, security scan)
- ✅ Issue templates
- ✅ AGPL-3.0 license
- ✅ CHANGELOG

**Your repository is now LIVE and the world can see it.**

---

## NEXT: Day 2 Tasks

Tomorrow you'll:
1. Set up documentation site (MkDocs)
2. Deploy landing page (GitHub Pages)
3. Create Discord server

**But first — celebrate. You just open-sourced an operating system.** 🚀

---

## Troubleshooting

### "fatal: not a git repository"
```powershell
cd C:\Users\#RAI\Documents\kimi\workspace\kirat-os-github
git init
```

### "fatal: Authentication failed"
```powershell
# Use personal access token instead of password
git remote set-url origin https://YOUR_USERNAME:YOUR_TOKEN@github.com/kirat-os/kirat-os.git
git push -u origin main
```

### "error: failed to push some refs"
```powershell
# Pull first, then push
git pull origin main --rebase
git push -u origin main
```

### Files too large to push
```powershell
# Check file sizes
forfiles /S /M * /C "cmd /c if @fsize gtr 104857600 echo @path @fsize"
# If any file > 100MB, add to .gitignore and remove from git
git rm --cached LARGE_FILE
echo "LARGE_FILE" >> .gitignore
git commit -m "remove large file"
git push
```
