# KIRAT OS — Scalability & High Availability Architecture
**Version:** 2.0-ENTERPRISE-SCALE  
**Scope:** Horizontal scaling, load balancing, caching, database sharding, backup replication

---

## Architecture Overview

```
                    ┌─────────────────┐
                    │   CloudFlare    │
                    │   or DNS LB     │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
       ┌──────▼──────┐ ┌─────▼─────┐ ┌─────▼─────┐
       │  KIRAT-LB-1 │ │ KIRAT-LB-2│ │ KIRAT-LB-3│   ← Traefik Load Balancers (Active-Active)
       │  (Primary)  │ │(Secondary)│ │ (Backup)  │
       └──────┬──────┘ └─────┬─────┘ └─────┬─────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
       ┌──────▼──────┐ ┌─────▼─────┐ ┌─────▼─────┐
       │  App Node 1 │ │ App Node 2│ │ App Node 3│   ← Docker Swarm / K8s Workers
       │  (Docker)   │ │ (Docker)  │ │ (Docker)  │
       └──────┬──────┘ └─────┬─────┘ └─────┬─────┘
              │              │              │
              └──────────────┼──────────────┘
                             │
       ┌─────────────────────┼─────────────────────┐
       │                     │                     │
  ┌────▼─────┐         ┌─────▼─────┐         ┌────▼─────┐
  │  Redis   │◄───────►│  Redis    │◄───────►│  Redis   │   ← Redis Cluster (Cache + Session)
  │  Master  │         │  Replica  │         │  Replica │
  └────┬─────┘         └───────────┘         └──────────┘
       │
  ┌────▼────────────────────────────────────────────┐
  │           PostgreSQL Primary                     │
  │     ┌─────────┐    ┌─────────┐    ┌─────────┐   │
  │     │ Shard 1 │    │ Shard 2 │    │ Shard 3 │   │   ← Citus Sharding
  │     │ (Users) │    │(Orders) │    │(Analytics)│  │
  │     └────┬────┘    └────┬────┘    └────┬────┘   │
  │          └──────────────┼───────────────┘        │
  │                   ┌─────▼─────┐                  │
  │                   │ Read Rep. │                  │
  │                   │  Pool     │                  │
  │                   └───────────┘                  │
  └──────────────────────────────────────────────────┘
       │
  ┌────▼────────────────────────────────────────────┐
  │         Backup Server (Offsite)                  │
  │    • Streaming WAL archive (real-time)           │
  │    • Daily pg_dump + rsync to S3                 │
  │    • AIDE integrity on backup volumes            │
  └──────────────────────────────────────────────────┘
```

---

## Components

### 1. Load Balancer — Traefik (Layer 7)
- **Why Traefik:** Native Docker integration, automatic Let's Encrypt, PQC TLS
- **Health checks:** `/health` endpoint on all app nodes
- **Sticky sessions:** For Aadhipati-AI websocket connections
- **Rate limiting:** 1000 req/min per IP, burst 500

### 2. Cache — Redis Cluster (6 nodes, 3 master + 3 replica)
- **Session storage:** JWT tokens, user sessions
- **AI agent state:** Cached threat intelligence, CVE lists
- **Query cache:** Frequently accessed dashboard data
- **Pub/Sub:** Real-time agent communication

### 3. Database — PostgreSQL + Citus (Sharding)
- **Shard 1:** Users, RBAC, audit logs
- **Shard 2:** Business data, transactions
- **Shard 3:** Analytics, AI training data
- **Read replicas:** 2 replicas per shard for query scaling

### 4. Backup Server
- **Streaming replication:** WAL archiving to backup node
- **Point-in-time recovery:** 30-day retention
- **Offsite:** Encrypted rsync to S3/MinIO
- **Disaster recovery:** `backup-dr.sh --action restore`

### 5. App Nodes (Docker Swarm)
- **Horizontal scaling:** `docker service scale kirat-app=5`
- **Rolling updates:** Zero-downtime deployments
- **Resource limits:** CPU 2 cores, RAM 4GB per container

---

## Scaling Commands

```bash
# Scale app containers
sudo docker service scale kirat-app=10

# Add Redis node
sudo docker-compose -f docker-compose.scaling.yml up -d redis-node-7

# Add PostgreSQL read replica
sudo docker-compose -f docker-compose.scaling.yml up -d postgres-replica-3

# Check cluster health
sudo docker node ls
sudo redis-cli -c cluster info
sudo psql -c "SELECT * FROM pg_stat_replication;"
```

---

## Hardware Requirements Per Node

| Node Type | Min RAM | Min CPU | Disk | Network |
|-----------|---------|---------|------|---------|
| Load Balancer | 2 GB | 2 cores | 20 GB SSD | 1 Gbps |
| App Node | 8 GB | 4 cores | 50 GB SSD | 1 Gbps |
| Redis Node | 4 GB | 2 cores | 20 GB SSD | 1 Gbps |
| PostgreSQL Primary | 16 GB | 8 cores | 200 GB NVMe | 10 Gbps |
| PostgreSQL Replica | 8 GB | 4 cores | 200 GB NVMe | 10 Gbps |
| Backup Server | 8 GB | 4 cores | 1 TB HDD | 1 Gbps |

---

**KIRAT OS — Scale Your Empire**
