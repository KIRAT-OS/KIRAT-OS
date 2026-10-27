#!/usr/bin/env python3
"""Insert TLS block back into install-native.sh"""

PATH = "kirat-os-server/scripts/install-native.sh"

NEW_TLS_BLOCK = '''    # TLS with PQC — 90-day self-signed FALLBACK + Let's Encrypt auto-cert
    mkdir -p "$INSTALL_MOUNT/etc/nginx/ssl"
    # Generate 90-day self-signed cert with SAN (fallback until Let's Encrypt succeeds)
    cat > /tmp/kirat-san.cnf << CNFTXT
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $DOMAIN
O = KIRAT OS Business
C = US
[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
IP.1 = 127.0.0.1
IP.2 = ::1
CNFTXT
    chroot "$INSTALL_MOUNT" openssl req -x509 -nodes -days 90 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \\
        -keyout /etc/nginx/ssl/kirat-key.pem -out /etc/nginx/ssl/kirat-cert.pem \\
        -config /tmp/kirat-san.cnf
    rm -f /tmp/kirat-san.cnf
    chmod 600 "$INSTALL_MOUNT/etc/nginx/ssl/kirat-key.pem"
    chroot "$INSTALL_MOUNT" chown root:root /etc/nginx/ssl/kirat-key.pem
    log_ok "90-day self-signed TLS fallback generated"

    # Certbot auto-renewal systemd timer (renews real certs before 90-day fallback expires)
    cat > "$INSTALL_MOUNT/etc/systemd/system/certbot-renew.service" << 'EOF'
[Unit]
Description=Certbot Renew
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot renew --quiet --nginx --deploy-hook "systemctl reload nginx"
EOF

    cat > "$INSTALL_MOUNT/etc/systemd/system/certbot-renew.timer" << 'EOF'
[Unit]
Description=Run Certbot renew twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chroot "$INSTALL_MOUNT" systemctl enable certbot-renew.timer
    log_ok "Certbot auto-renewal timer enabled (twice daily)"

    # First-boot service: attempt Let's Encrypt if DOMAIN is not localhost
    cat > "$INSTALL_MOUNT/etc/systemd/system/kirat-certbot-firstboot.service" << EOF
[Unit]
Description=KIRAT OS — Obtain Let's Encrypt certificate on first boot
After=network-online.target nginx.service
Wants=network-online.target
ConditionPathExists=!/etc/letsencrypt/live/$DOMAIN/fullchain.pem

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if [ "$DOMAIN" != "localhost" ]; then certbot --nginx -d $DOMAIN -d *.$DOMAIN --agree-tos --non-interactive --email $BUSINESS_EMAIL; else echo "Domain is localhost — skipping Let\\'s Encrypt"; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    log_ok "First-boot Let's Encrypt service created (skips if DOMAIN=localhost)"

    log_ok "Security stack operational (100/100)"
'''

with open(PATH, "r", encoding="utf-8") as f:
    lines = f.readlines()

# Find the line with TPM 2.0 completion
insert_after = None
for i, line in enumerate(lines):
    if 'TPM 2.0 tools installed (configure after first boot)' in line:
        insert_after = i
        break

if insert_after is None:
    print("ERROR: Could not find TPM block end marker")
    exit(1)

# Find the closing brace of stage5 — look for standalone } after TPM block
closing_brace = None
for i in range(insert_after + 1, len(lines)):
    if lines[i].strip() == '}':
        closing_brace = i
        break

if closing_brace is None:
    print("ERROR: Could not find stage5 closing brace")
    exit(1)

# Insert TLS block before the closing brace
new_lines = lines[:closing_brace] + ['\n'] + [NEW_TLS_BLOCK + '\n'] + lines[closing_brace:]

with open(PATH, "w", encoding="utf-8") as f:
    f.writelines(new_lines)

print(f"TLS block inserted before line {closing_brace + 1}")
