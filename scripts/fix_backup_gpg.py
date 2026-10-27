#!/usr/bin/env python3
"""Add GPG encryption to backup-agent in docker-compose.scaling.yml"""

PATH = "kirat-os-server/docker-compose.scaling.yml"

with open(PATH, "r", encoding="utf-8") as f:
    content = f.read()

old_backup = '''  backup-agent:
    image: kirat-os/backup:latest
    build:
      context: ./scripts
      dockerfile: Dockerfile.backup
    environment:
      - BACKUP_DIR=/backups
      - RETENTION_DAYS=30
      - REMOTE_TARGET=${REMOTE_TARGET:-}
      - DB_HOST=postgres-primary
      - REDIS_HOST=redis-master
    volumes:
      - backup-storage:/backups
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - kirat-db
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.backup == true
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    command: >
      sh -c "
        while true; do
          echo '[BACKUP] Running daily backup...';
          pg_dumpall -h postgres-primary -U kirat_admin > /backups/postgres-$$(date +%Y%m%d).sql;
          redis-cli -h redis-master SAVE;
          cp /data/redis/dump.rdb /backups/redis-$$(date +%Y%m%d).rdb;
          tar czf /backups/kirat-config-$$(date +%Y%m%d).tar.gz /opt/kirat-os /etc/nginx /etc/ssh;
          find /backups -mtime +30 -delete;
          echo '[BACKUP] Done. Sleeping 24h...';
          sleep 86400;
        done
      "'''

new_backup = '''  backup-agent:
    image: kirat-os/backup:latest
    build:
      context: ./scripts
      dockerfile: Dockerfile.backup
    environment:
      - BACKUP_DIR=/backups
      - RETENTION_DAYS=30
      - REMOTE_TARGET=${REMOTE_TARGET:-}
      - DB_HOST=postgres-primary
      - REDIS_HOST=redis-master
      - GPG_PASSPHRASE_FILE=/run/secrets/backup_passphrase
    volumes:
      - backup-storage:/backups
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/kirat-os/security/backup-passphrase:/run/secrets/backup_passphrase:ro
    networks:
      - kirat-db
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.labels.backup == true
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
    command: >
      bash -c "
        set -euo pipefail;
        GPG_OPTS=\"--batch --yes --passphrase-file /run/secrets/backup_passphrase --cipher-algo AES256 --symmetric\";
        while true; do
          echo '[BACKUP] Running daily encrypted backup...';
          DATE=$$(date +%Y%m%d);
          pg_dumpall -h postgres-primary -U kirat_admin > /backups/postgres-$${DATE}.sql;
          gpg $$GPG_OPTS -o /backups/postgres-$${DATE}.sql.gpg /backups/postgres-$${DATE}.sql;
          rm -f /backups/postgres-$${DATE}.sql;
          redis-cli -h redis-master SAVE;
          cp /data/redis/dump.rdb /backups/redis-$${DATE}.rdb;
          gpg $$GPG_OPTS -o /backups/redis-$${DATE}.rdb.gpg /backups/redis-$${DATE}.rdb;
          rm -f /backups/redis-$${DATE}.rdb;
          tar czf /backups/kirat-config-$${DATE}.tar.gz /opt/kirat-os /etc/nginx /etc/ssh;
          gpg $$GPG_OPTS -o /backups/kirat-config-$${DATE}.tar.gz.gpg /backups/kirat-config-$${DATE}.tar.gz;
          rm -f /backups/kirat-config-$${DATE}.tar.gz;
          find /backups -mtime +30 -delete;
          echo '[BACKUP] Encrypted backups complete. Sleeping 24h...';
          sleep 86400;
        done
      "'''

if old_backup in content:
    content = content.replace(old_backup, new_backup, 1)
    print("Updated backup-agent with GPG encryption in docker-compose.scaling.yml")
else:
    print("WARNING: Could not find backup-agent block")

with open(PATH, "w", encoding="utf-8") as f:
    f.write(content)
