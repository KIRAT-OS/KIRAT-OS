# KIRAT OS

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](https://www.gnu.org/licenses/agpl-3.0)

> **Don't just run AI on your server. Let your server RUN AI for you.**

KIRAT OS is the world's first AI-native server operating system. It embeds autonomous AI agents, post-quantum cryptography, and GPU-optimized inference directly into the OS — so your infrastructure thinks, defends, and heals itself.

## Quick Start

```bash
wget https://github.com/kirat-os/kirat-os/releases/latest/download/kirat-os.iso
sudo dd if=kirat-os.iso of=/dev/sdX bs=4M status=progress

### 5.3 Create CHANGELOG.md
```powershell
@'
# Changelog

## [2.0.0-beta] - 2026-08-18

### Added
- Initial public release
- 6 autonomous AI agents
- Post-quantum cryptography (Kyber TLS, sntrup761 SSH)
- AI-native server architecture with Ollama integration
- Real-time monitoring dashboard
- Bootable ISO builder with GRUB2 EFI/BIOS dual boot
- LUKS2 disk encryption with Argon2id
