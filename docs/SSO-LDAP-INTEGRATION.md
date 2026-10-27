# KIRAT OS — SSO / LDAP / Active Directory Integration Guide
**Version:** 2.0-ENTERPRISE  
**Target Audience:** Enterprise IT Administrators

---

## Overview

KIRAT OS supports enterprise authentication through:
- **OpenLDAP** (RFC 4510 compliant)
- **Active Directory** (Windows Server 2016+)
- **SAML 2.0** (via Keycloak / Authentik)
- **OIDC** (Google Workspace, Azure AD, Okta)

---

## 1. LDAP Integration

### Install Client Tools
```bash
sudo apt-get install -y libnss-ldapd libpam-ldapd nslcd
```

### Configure `/etc/nslcd.conf`
```
uri ldap://ldap.company.com
base dc=company,dc=com
binddn cn=kirat-service,dc=company,dc=com
bindpw SECRET
filter passwd (objectClass=posixAccount)
filter group  (objectClass=posixGroup)
```

### Enable LDAP Auth
```bash
sudo pam-auth-update --enable mkhomedir
sudo systemctl restart nslcd
```

### Map LDAP Groups to KIRAT OS Roles
| LDAP Group | KIRAT OS Role | Permissions |
|------------|--------------|-------------|
| `cn=kirat-admins,ou=groups,dc=company,dc=com` | Tier 1 (kirat-admin) | Full sudo |
| `cn=kirat-security,ou=groups,dc=company,dc=com` | security-officer | Security tools only |
| `cn=kirat-ops,ou=groups,dc=company,dc=com` | ops-engineer | Infrastructure read-only |
| `cn=kirat-dev,ou=groups,dc=company,dc=com` | dev-engineer | Docker/Git only |

---

## 2. Active Directory (AD) Integration

### Using Realmd
```bash
sudo apt-get install -y realmd oddjob oddjob-mkhomedir sssd-ad
sudo realm join -U admin@COMPANY.COM company.com
```

### SSSD Config `/etc/sssd/sssd.conf`
```ini
[domain/company.com]
id_provider = ad
auth_provider = ad
chpass_provider = ad
access_provider = ad
ad_gpo_access_control = enforcing
```

### Restrict Login to AD Groups Only
```bash
sudo realm permit -g kirat-admins@company.com
sudo realm permit -g kirat-security@company.com
```

---

## 3. SAML / OIDC (Keycloak)

### Install Keycloak Adapter
```bash
sudo apt-get install -y libapache2-mod-auth-openidc
```

### Nginx Reverse Proxy Config
```nginx
location /dashboard/ {
    auth_request /auth;
    auth_request_set $auth_user $upstream_http_x_user;
    proxy_pass http://localhost:8080;
    proxy_set_header X-User $auth_user;
}

location = /auth {
    internal;
    proxy_pass http://keycloak.company.com/realms/kirat/protocol/openid-connect/userinfo;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header Authorization $http_authorization;
}
```

---

## 4. Aadhipati-AI Integration

Aadhipati-AI can query enterprise directories:
```bash
# Voice command: "Show all admin users"
# Aadhipati translates → LDAP search → formatted response

kirat-admin aadhipati query "(&(objectClass=posixAccount)(memberOf=cn=kirat-admins,ou=groups,dc=company,dc=com))"
```

---

## 5. Security Considerations

- **TLS Required:** All LDAP/AD connections MUST use TLS (ldaps:// or STARTTLS)
- **Certificate Pinning:** Pin enterprise CA cert in `/etc/ssl/certs/`
- **No Password Storage:** KIRAT OS NEVER stores enterprise passwords locally
- **Audit Logging:** All SSO events logged to `/var/log/kirat-os/sso-audit.log`
- **Fallback:** Local `kirat-admin` account remains available for emergency access

---

**KIRAT OS — Your Empire, Your Identity Provider**
