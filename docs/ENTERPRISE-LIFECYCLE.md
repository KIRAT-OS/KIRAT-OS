# KIRAT OS Enterprise Lifecycle Policy
**Version:** 2.0-ENTERPRISE  
**Effective:** 2026-08-17  
**Applies to:** KIRAT OS Business, KIRAT OS Enterprise, KIRAT OS Government

---

## 1. Support Tiers

| Tier | Duration | Scope | Cost |
|------|----------|-------|------|
| **Standard** | 5 years | Security patches, bug fixes | Free (community) |
| **Extended** | 10 years | + kernel LTS backports, hardware enablement | Paid subscription |
| **Premium** | 10+ years | + 24/7 SLA, dedicated engineer, custom builds | Enterprise contract |

## 2. Release Cadence

- **Major:** Every 2 years (e.g., 2.0, 3.0)
- **Minor:** Quarterly (e.g., 2.1, 2.2)
- **Security:** As-needed (CVE response within 24-72h)
- **AI Model Updates:** Monthly (threat intelligence refresh)

## 3. End-of-Life (EOL) Guarantees

| Version | Release | Standard EOL | Extended EOL |
|---------|---------|-------------|--------------|
| KIRAT OS 1.0 | 2025-01 | 2030-01 | 2035-01 |
| KIRAT OS 2.0 | 2026-08 | 2031-08 | 2036-08 |
| KIRAT OS 3.0 | 2028-08 | 2033-08 | 2038-08 |

## 4. Upgrade Path

```
KIRAT OS 1.x → 2.x: scripts/upgrade-kirat-os.sh (7-stage automated)
KIRAT OS 2.x → 3.x: In-place upgrade with rollback snapshot
Major → Major: Bootable ISO + data migration wizard
```

## 5. Backwards Compatibility

- **Config files:** Guaranteed compatible within major version
- **AI agent API:** Versioned (v1, v2) with 2-year deprecation window
- **Database schema:** Migrations included in every minor release
- **SSH keys:** Ed25519 format stable across all versions

## 6. Commercial Support Channels

| Channel | Response Time | Availability |
|---------|--------------|--------------|
| Community Forum | Best effort | 24/7 |
| GitHub Issues | 72h | Business days |
| Email Support | 24h | Extended tier |
| Phone/Video | 4h | Premium tier |
| On-site Engineer | 24h | Premium + location |

## 7. Certification Roadmap

| Certification | Target Date | Status |
|---------------|-------------|--------|
| FIPS 140-3 | 2027-Q2 | In planning |
| Common Criteria EAL4+ | 2027-Q4 | In planning |
| ISO 27001 | 2026-Q4 | Self-assessment |
| FedRAMP Moderate | 2028-Q2 | On roadmap |

---
**Teacher's Empire Operating System — Built to Last**
