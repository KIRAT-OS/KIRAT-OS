#!/bin/bash
###############################################################################
# KIRAT OS — Scalability Setup Script
###############################################################################
# Initializes Docker Swarm, deploys the scaling stack, and configures
# node labels for proper service placement.
###############################################################################

set -euo pipefail

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'; BOLD='\033[1m'

log_info()  { echo -e "${CYAN}[SCALE]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}   $1"; }

die() { log_error "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# CHECK PREREQUISITES
# ─────────────────────────────────────────────────────────────────────────────
log_info "Checking prerequisites..."

command -v docker >/dev/null 2>&1 || die "Docker not installed. Run: apt-get install docker.io"
command -v docker-compose >/dev/null 2>&1 || die "Docker Compose not installed."

if ! docker info >/dev/null 2>&1; then
    die "Docker daemon not running. Start with: systemctl start docker"
fi

log_ok "Docker and Docker Compose available"

# ─────────────────────────────────────────────────────────────────────────────
# INITIALIZE DOCKER SWARM (if not already)
# ─────────────────────────────────────────────────────────────────────────────
if ! docker info --format '{{.Swarm.LocalNodeState}}' | grep -q "active"; then
    log_info "Initializing Docker Swarm..."
    docker swarm init --advertise-addr $(hostname -I | awk '{print $1}') || \
        log_warn "Swarm init may have failed — check if already in swarm"
    log_ok "Docker Swarm initialized"
else
    log_ok "Docker Swarm already active"
fi

# ─────────────────────────────────────────────────────────────────────────────
# CREATE SECRETS
# ─────────────────────────────────────────────────────────────────────────────
log_info "Creating Docker secrets..."

if ! docker secret ls | grep -q "db_password"; then
    echo "$(openssl rand -hex 32)" | docker secret create db_password - 2>/dev/null || \
        log_warn "db_password secret may already exist"
fi

if ! docker secret ls | grep -q "redis_password"; then
    echo "$(openssl rand -hex 32)" | docker secret create redis_password - 2>/dev/null || \
        log_warn "redis_password secret may already exist"
fi

log_ok "Docker secrets created"

# ─────────────────────────────────────────────────────────────────────────────
# LABEL NODES FOR SERVICE PLACEMENT
# ─────────────────────────────────────────────────────────────────────────────
log_info "Labeling nodes for service placement..."

NODE_ID=$(docker info -f '{{.Swarm.NodeID}}')

# Label current node as manager + primary services
docker node update --label-add role=manager "$NODE_ID" 2>/dev/null || true
docker node update --label-add redis=master "$NODE_ID" 2>/dev/null || true
docker node update --label-add postgres=primary "$NODE_ID" 2>/dev/null || true
docker node update --label-add backup=true "$NODE_ID" 2>/dev/null || true

log_ok "Node labeled: manager, redis=master, postgres=primary, backup=true"

cat << 'EOF'

╔══════════════════════════════════════════════════════════════════════╗
║         NODE LABELING GUIDE                                          ║
╚══════════════════════════════════════════════════════════════════════╝

For a multi-node cluster, label each node:

  # Manager node (runs Traefik, primary DB)
  docker node update --label-add role=manager <NODE_ID>
  docker node update --label-add redis=master <NODE_ID>
  docker node update --label-add postgres=primary <NODE_ID>

  # Worker node 1 (runs app containers, Redis replica)
  docker node update --label-add role=worker <NODE_ID>
  docker node update --label-add redis=replica1 <NODE_ID>

  # Worker node 2 (runs app containers, PostgreSQL replica)
  docker node update --label-add role=worker <NODE_ID>
  docker node update --label-add postgres=replica <NODE_ID>

  # GPU node (runs Ollama AI)
  docker node update --label-add gpu=true <NODE_ID>

To get node IDs: docker node ls
EOF

# ─────────────────────────────────────────────────────────────────────────────
# CREATE OVERLAY NETWORKS
# ─────────────────────────────────────────────────────────────────────────────
log_info "Creating overlay networks..."

docker network create --driver overlay --attachable kirat-public 2>/dev/null || log_warn "kirat-public may exist"
docker network create --driver overlay --internal kirat-backend 2>/dev/null || log_warn "kirat-backend may exist"
docker network create --driver overlay --internal kirat-db 2>/dev/null || log_warn "kirat-db may exist"

log_ok "Overlay networks ready"

# ─────────────────────────────────────────────────────────────────────────────
# DEPLOY STACK
# ─────────────────────────────────────────────────────────────────────────────
log_info "Deploying KIRAT OS scaling stack..."

STACK_FILE="docker-compose.scaling.yml"
if [ ! -f "$STACK_FILE" ]; then
    die "Stack file not found: $STACK_FILE. Run from kirat-os-server directory."
fi

docker stack deploy -c "$STACK_FILE" kirat-os

log_ok "Stack deployed: kirat-os"

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────
log_info "Verifying deployment..."

echo ""
echo "Services:"
docker service ls --filter name=kirat-os

echo ""
echo "Networks:"
docker network ls --filter name=kirat

echo ""
echo "Nodes:"
docker node ls

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  KIRAT OS Scaling Stack Deployed${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"
echo ""
echo "  Stack:       kirat-os"
echo "  Services:    Traefik LB, App (x3), Redis (1M+2R), Postgres (1P+2R),"
echo "               Ollama AI, Backup Agent, Prometheus, Grafana"
echo ""
echo "  Commands:"
echo "    docker service ls                    — List all services"
echo "    docker service scale kirat-os_kirat-app=10  — Scale app containers"
echo "    docker service logs kirat-os_traefik — View load balancer logs"
echo "    docker stack ps kirat-os             — Check task placement"
echo ""
echo "  Dashboards:"
echo "    Traefik:   http://$(hostname -I | awk '{print $1}'):8080"
echo "    Grafana:   https://grafana.kirat-os.local (after DNS setup)"
echo ""
echo "  Scaling:"
echo "    Add worker:  docker swarm join --token <TOKEN> <MANAGER-IP>:2377"
echo "    Scale app:   docker service scale kirat-os_kirat-app=5"
echo ""
