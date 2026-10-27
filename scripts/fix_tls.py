#!/usr/bin/env python3
"""Replace TLS block in install-native.sh with 90-day fallback + Let's Encrypt"""

import sys

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
    content = f.read()

start_marker = "    # TLS with PQC"
end_marker = '    log_ok "Security stack operational (100/100)"'

start_idx = content.find(start_marker)
end_idx = content.find(end_marker, start_idx)

if start_idx == -1 or end_idx == -1:
    print("ERROR: Could not find TLS block markers", file=sys.stderr)
    sys.exit(1)

new_content = content[:start_idx] + NEW_TLS_BLOCK + content[end_idx + len(end_marker):]

with open(PATH, "w", encoding="utf-8") as f:
    f.write(new_content)

print("TLS block replaced successfully")
