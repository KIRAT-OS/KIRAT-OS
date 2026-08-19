# Zero-Trust Architecture Implementation
# KIRAT OS Server Security Layer 3
# "Never trust, always verify, continuously authenticate"

## Core Principles

1. **No Implicit Trust**: Network location means nothing. Every request is authenticated.
2. **Least Privilege**: Services get minimum permissions needed, for minimum time.
3. **Continuous Verification**: Re-authenticate based on behavior, time, context.
4. **Assume Breach**: Design as if attacker is already inside.
5. **Micro-Segmentation**: Every service is isolated. Compromise of one ≠ compromise of all.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           ZERO-TRUST MESH                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  [User] ──mTLS──▶ [Identity Proxy] ──mTLS──▶ [Service Mesh]                │
│     │                (SPIFFE/SPIRE)            (Istio/Linkerd/Cilium)      │
│     │                                                                        │
│     └──▶ MFA (hardware key)                                                  │
│     └──▶ Device attestation (TPM)                                           │
│     └──▶ Behavioral biometrics (keystroke, mouse)                           │
│                                                                              │
│  [Service A] ──mTLS──▶ [Policy Engine] ──mTLS──▶ [Service B]               │
│     │                   (OPA/SpiceDB)                                        │
│     │                   "Can A call B's /api/v1/data?"                       │
│     │                   "Only if A has 'data:read' AND time is 9-5"          │
│     │                                                                        │
│  [IoT Device] ──mTLS──▶ [Device Gateway] ──mTLS──▶ [MQTT Broker]           │
│     │                   (X.509 cert + PQC)                                   │
│     │                   "Device-7B3A can publish to sensors/temp"            │
│                                                                              │
│  [AI Model] ──mTLS──▶ [Model Gateway] ──mTLS──▶ [Inference Engine]         │
│     │                   "Request authenticated, rate limit: 100/min"         │
│     │                                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  WireGuard Mesh Network (PQC-protected)                                     │
│  Every node has its own subnet, no flat network                             │
│  East-west traffic encrypted and authenticated                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Implementation

### 1. Identity: SPIFFE/SPIRE

```yaml
# /etc/spire/server.conf
server {
    bind_address = "0.0.0.0"
    bind_port = "8081"
    trust_domain = "kirat-os.local"
    
    # Post-quantum CA
    ca_key_type = "pq-ml-dsa-65"
    ca_ttl = "24h"
    
    # Node attestation
    plugins {
        NodeAttestor "tpm" {
            plugin_data {
                ak_path = "/sys/class/tpm/tpm0/ppi"
            }
        }
        
        NodeAttestor "join_token" {
            plugin_data {}
        }
    }
}
```

```bash
# Register a workload
spire-server entry create \
    -parentID spiffe://kirat-os.local/host/node-01 \
    -spiffeID spiffe://kirat-os.local/workload/postgresql \
    -selector docker:label:app:postgresql \
    -selector docker:label:env:production \
    -ttl 3600

# Workload gets SVID (SPIFFE Verifiable Identity Document)
# Contains PQC-signed X.509 certificate
# Valid for 1 hour, auto-rotated
```

### 2. Service Mesh: Cilium + mTLS

```yaml
# CiliumClusterwideNetworkPolicy
cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: zero-trust-default
description: "Default deny all, allow explicitly"
spec:
  endpointSelector: {}
  ingressDeny:
    - {}
  egressDeny:
    - {}
---
# Allow specific communications
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: postgresql-access
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: postgresql
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: api-server
      toPorts:
        - ports:
            - port: "5432"
              protocol: TCP
          rules:
            http:
              - method: "POST"
                path: "/api/v1/query"
                headers:
                  - name: "X-Required-Role"
                    value: "db-reader"
  egress:
    - toEndpoints:
        - matchLabels:
            app: etcd
      toPorts:
        - ports:
            - port: "2379"
              protocol: TCP
```

### 3. Policy Engine: Open Policy Agent (OPA)

```rego
# /etc/opa/policies/kirat-authz.rego
package kirat.authz

import future.keywords.if
import future.keywords.in

# Default: deny
default allow := false

# Allow: Sentinel AI can read system metrics
allow if {
    input.identity == "spiffe://kirat-os.local/workload/sentinel"
    input.action == "read"
    input.resource.type == "metric"
}

# Allow: API server can query database (business hours only)
allow if {
    input.identity == "spiffe://kirat-os.local/workload/api-server"
    input.action == "query"
    input.resource.type == "database"
    time.now_ns >= time.parse_rfc3339_ns("2024-01-01T09:00:00Z")
    time.now_ns <= time.parse_rfc3339_ns("2024-01-01T17:00:00Z")
    input.request.rate <= 1000  # max 1000 queries/minute
}

# Allow: User with admin role can perform any action
allow if {
    input.identity in data.roles.admin
    input.mfa_verified == true
    input.device.trust_score >= 0.8
}

# Deny: Any request from known-bad IP
allow := false if {
    input.source.ip in data.threat_intel.bad_ips
}

# Deny: AI model requests without adversarial check
allow := false if {
    input.resource.type == "ai-inference"
    input.adversarial_score > 0.7
}
```

### 4. WireGuard Mesh with PQC

```bash
#!/bin/bash
# /usr/local/bin/wg-mesh-setup.sh

# Each node generates PQC keypair
NODE_ID=$(cat /etc/machine-id)
PQC_PRIV=$(sentinel pqc generate-key --type ml-kem-768 --name "wg-$NODE_ID")
PQC_PUB=$(sentinel pqc export-public --name "wg-$NODE_ID")

# WireGuard interface
ip link add dev wg0 type wireguard
ip address add dev wg0 10.200.200.$NODE_INDEX/24

# Configure with PQC pre-shared key
wg set wg0 \
    private-key /etc/wireguard/private.key \
    pqc-preshared-key <(echo "$PQC_PUB") \
    listen-port 51820

# Add peers (other nodes in mesh)
for peer in $(sentinel mesh list-peers); do
    wg set wg0 peer "$peer.pubkey" \
        pqc-preshared-key <(sentinel pqc encapsulate --pubkey "$peer.pqc_pub") \
        allowed-ips 10.200.200.0/24 \
        endpoint "$peer.endpoint:51820" \
        persistent-keepalive 25
done

ip link set up dev wg0
```

### 5. Continuous Authentication

```python
# sentinel-core/src/auth/continuous_auth.py

class ContinuousAuthenticator:
    """Re-authenticates based on behavior, not just initial login."""
    
    def __init__(self):
        self.baseline = {}  # Learned normal behavior
        self.risk_score = 0.0
        
    def authenticate_request(self, identity, request):
        """Score each request for anomaly."""
        
        # Factor 1: Time-based
        hour = datetime.now().hour
        if hour < 6 or hour > 22:
            self.risk_score += 0.2  # Unusual hours
            
        # Factor 2: Location-based
        if request.source_ip not in self.baseline[identity].known_ips:
            self.risk_score += 0.3  # New location
            
        # Factor 3: Behavioral biometrics
        keystroke_pattern = request.headers.get('X-Keystroke-Dynamics')
        if keystroke_pattern:
            similarity = self.compare_keystroke(identity, keystroke_pattern)
            if similarity < 0.7:
                self.risk_score += 0.4  # Typing doesn't match user
                
        # Factor 4: Request pattern
        if request.rate > self.baseline[identity].avg_rate * 3:
            self.risk_score += 0.2  # Unusually fast
            
        # Factor 5: AI anomaly detection
        anomaly_score = self.sentinel_ml.predict_anomaly(identity, request)
        self.risk_score += anomaly_score * 0.5
        
        # Decision
        if self.risk_score > 0.8:
            return AuthResult.DENY, "High risk behavior detected"
        elif self.risk_score > 0.5:
            return AuthResult.CHALLENGE, "Additional verification required"
        else:
            return AuthResult.ALLOW, None
            
    def challenge_user(self, identity):
        """Step-up authentication."""
        # Send push notification to hardware key
        # Request biometric verification
        # Ask security question
        pass
```

### 6. Device Attestation (TPM)

```bash
# TPM-based device attestation
# Ensures only trusted hardware can join the network

# 1. TPM generates AK (Attestation Key)
tpm2_createprimary -C ek -c ek.ctx
tpm2_create -C ek.ctx -u ak.pub -r ak.priv -a "fixedtpm|fixedparent|sensitivedataorigin|userwithauth|restricted|sign"
tpm2_load -C ek.ctx -u ak.pub -r ak.priv -c ak.ctx

# 2. Get TPM quote (signed PCR measurements)
tpm2_quote -c ak.ctx -l sha256:0,1,2,3,4,5,6,7 -m quote.msg -s quote.sig

# 3. Send to attestation server
sentinel attest --quote quote.msg --signature quote.sig --ak ak.pub

# 4. Server verifies:
#    - Quote signature valid (AK signed by TPM)
#    - PCR values match expected (boot chain intact)
#    - No PCR extend after quote (replay protection)
#    - TPM is genuine (EK certificate from manufacturer)
```

## Network Segmentation

```
┌─────────────────────────────────────────────────────────────────┐
│                         DMZ (Untrusted)                         │
│  [Internet] ──▶ [Reverse Proxy] ──▶ [WAF]                      │
│                   (Nginx/Caddy)      (ModSecurity)              │
├─────────────────────────────────────────────────────────────────┤
│                      Application Tier                            │
│  [API Gateway] ──▶ [App Services] ──▶ [Message Queue]          │
│   (Kong/Traefik)    (Microservices)    (NATS/RabbitMQ)         │
├─────────────────────────────────────────────────────────────────┤
│                       Data Tier                                  │
│  [Database] ──▶ [Cache] ──▶ [Object Storage]                   │
│   (PostgreSQL)    (Redis)    (MinIO/Ceph)                      │
├─────────────────────────────────────────────────────────────────┤
│                      Management Tier                             │
│  [Sentinel AI] ──▶ [Monitoring] ──▶ [Backup]                   │
│   (Core brain)     (Prometheus)      (Restic/Borg)             │
├─────────────────────────────────────────────────────────────────┤
│                      Control Plane                               │
│  [K3s API] ──▶ [etcd] ──▶ [Container Registry]                 │
│   (Kubernetes)    (State)    (Harbor)                          │
└─────────────────────────────────────────────────────────────────┘

Rules:
- DMZ can ONLY talk to Application Tier on ports 80/443
- Application Tier can ONLY talk to Data Tier on specific DB ports
- Management Tier can read metrics from all tiers, but cannot modify
- Control Plane is isolated, accessible only via VPN + hardware key
- NO direct Internet access from Data, Management, or Control tiers
```

## Implementation Checklist

- [ ] Deploy SPIRE server for workload identity
- [ ] Configure Cilium with default-deny policies
- [ ] Deploy OPA as sidecar on every service
- [ ] Set up WireGuard mesh between all nodes
- [ ] Enable TPM attestation for all hardware
- [ ] Configure continuous authentication
- [ ] Implement micro-segmentation (per-service firewall rules)
- [ ] Deploy honeypot services (see deception layer)
- [ ] Set up certificate auto-rotation (24-hour TTL)
- [ ] Monitor for policy violations with Sentinel AI

## Verification

```bash
# Test: Can unauthorized service access database?
curl -H "X-SPIFFE-ID: spiffe://kirat-os.local/workload/random-app" \
     http://postgresql:5432/api/v1/query
# Expected: 403 Forbidden (OPA denies)

# Test: Is traffic encrypted?
tcpdump -i wg0 -X | grep "plaintext"
# Expected: No plaintext found

# Test: Can compromised container escape?
docker run --rm -it --security-opt seccomp=unconfined alpine sh
# Expected: seccomp blocks dangerous syscalls

# Test: Sentinel detects anomalous access
sentinel auth test --identity attacker --action admin --resource production-db
# Expected: Risk score > 0.8, access denied, alert generated
```
