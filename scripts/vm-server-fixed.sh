#!/bin/bash
###############################################################################
# KIRAT OS Server - VM Test & Cloud Deploy Scripts
# Test your server OS safely in VMs before deploying to real hardware
###############################################################################

set -euo pipefail

VM_NAME="${VM_NAME:-kirat-server-test}"
VM_DIR="${VM_DIR:-$HOME/kirat-os-server-vm}"
VM_DISK="$VM_DIR/$VM_NAME.qcow2"
VM_DISK_SIZE="${VM_DISK_SIZE:-50G}"
VM_RAM="${VM_RAM:-8192}"
VM_CPU="${VM_CPU:-4}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${BLUE}[VM]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[VM]${NC} $1"; }
error() { echo -e "${RED}[VM]${NC} $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# VM MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────

create_vm() {
    info "Creating VM disk: $VM_DISK (${VM_DISK_SIZE})"
    mkdir -p "$VM_DIR"
    
    if [ -f "$VM_DISK" ]; then
        warn "Disk exists. Use 'delete-vm' to recreate."
        return 0
    fi
    
    qemu-img create -f qcow2 "$VM_DISK" "$VM_DISK_SIZE"
    ok "VM disk created"
}

delete_vm() {
    if [ -f "$VM_DISK" ]; then
        rm -f "$VM_DISK"
        ok "VM deleted"
    else
        warn "No VM disk found"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# TEST SERVER OS INSTALLATION
# ─────────────────────────────────────────────────────────────────────────────

test_install() {
    local iso="${1:-}"
    
    if [ -z "$iso" ] || [ ! -f "$iso" ]; then
        error "Usage: $0 test-install <kirat-os-server.iso>"
        exit 1
    fi
    
    create_vm
    
    info "Booting installer ISO in VM..."
    info "The installer will guide you through disk partitioning"
    info "Press Ctrl+A then X to exit QEMU"
    
    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine type=q35,accel=kvm:tcg \
        -cpu max \
        -smp "$VM_CPU" \
        -m "$VM_RAM" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -cdrom "$iso" \
        -boot d \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::3000-:3000,hostfwd=tcp::9090-:9090 \
        -device virtio-net-pci,netdev=net0 \
        -display gtk \
        -vga virtio \
        -serial stdio \
        -no-reboot \
        -d guest_errors \
        -D "$VM_DIR/qemu-install.log"
}

# ─────────────────────────────────────────────────────────────────────────────
# BOOT INSTALLED SERVER
# ─────────────────────────────────────────────────────────────────────────────

boot_server() {
    if [ ! -f "$VM_DISK" ]; then
        error "No VM disk. Create one: $0 create-vm"
        exit 1
    fi
    
    info "Booting KIRAT OS Server..."
    info "SSH:    ssh -p 2222 sentinel@localhost"
    info "HTTP:   http://localhost:8080 (Sentinel dashboard)"
    info "Grafana: http://localhost:3000"
    info "Prometheus: http://localhost:9090"
    info ""
    info "Press Ctrl+A then X to exit"
    
    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine type=q35,accel=kvm:tcg \
        -cpu max \
        -smp "$VM_CPU" \
        -m "$VM_RAM" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::3000-:3000,hostfwd=tcp::9090-:9090 \
        -device virtio-net-pci,netdev=net0 \
        -display gtk \
        -vga virtio \
        -serial stdio \
        -no-reboot \
        -d guest_errors \
        -D "$VM_DIR/qemu-boot.log"
}

# ─────────────────────────────────────────────────────────────────────────────
# HEADLESS SERVER (no GUI, SSH only)
# ─────────────────────────────────────────────────────────────────────────────

boot_headless() {
    if [ ! -f "$VM_DISK" ]; then
        error "No VM disk. Create one: $0 create-vm"
        exit 1
    fi
    
    info "Booting headless server..."
    info "SSH:    ssh -p 2222 sentinel@localhost"
    info ""
    info "To stop: kill the qemu process or use monitor"
    
    qemu-system-x86_64 \
        -name "$VM_NAME" \
        -machine type=q35,accel=kvm:tcg \
        -cpu max \
        -smp "$VM_CPU" \
        -m "$VM_RAM" \
        -drive file="$VM_DISK",format=qcow2,if=virtio \
        -netdev user,id=net0,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:8080,hostfwd=tcp::3000-:3000,hostfwd=tcp::9090-:9090 \
        -device virtio-net-pci,netdev=net0 \
        -nographic \
        -serial mon:stdio \
        -no-reboot \
        -daemonize \
        -pidfile "$VM_DIR/qemu.pid" \
        -D "$VM_DIR/qemu-headless.log"
    
    # FIX 2: Wait for QEMU to write the PID file before reading it.
    local waited=0
    while [ ! -f "$VM_DIR/qemu.pid" ] && [ "$waited" -lt 30 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if [ -f "$VM_DIR/qemu.pid" ]; then
        ok "Server running in background (PID: $(cat "$VM_DIR/qemu.pid"))"
    else
        warn "Server started but PID file not found yet"
    fi
    info "Connect: ssh -p 2222 sentinel@localhost"
}

stop_headless() {
    if [ -f "$VM_DIR/qemu.pid" ]; then
        local pid=$(cat "$VM_DIR/qemu.pid")
        info "Stopping VM (PID: $pid)"
        kill "$pid" 2>/dev/null || true
        rm -f "$VM_DIR/qemu.pid"
        ok "VM stopped"
    else
        warn "No running VM found"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SSH INTO VM
# ─────────────────────────────────────────────────────────────────────────────

ssh_vm() {
    info "Connecting to VM via SSH..."
    ssh -p 2222 \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 \
        sentinel@localhost
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUD DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────

deploy_hetzner() {
    local token="${HETZNER_API_TOKEN:-}"
    local type="${1:-cx31}"
    
    if [ -z "$token" ]; then
        error "Set HETZNER_API_TOKEN environment variable"
        exit 1
    fi
    
    info "Deploying to Hetzner Cloud (type: $type)"
    
    # FIX 1: Use jq to properly encode user_data into JSON instead of
    # inlining base64 output directly, which breaks when YAML contains quotes.
    local user_data_b64
    user_data_b64=$(base64 -w 0 < cloud-init/kirat-server.yaml)
    
    local payload
    payload=$(jq -n \
        --arg name "$VM_NAME" \
        --arg server_type "$type" \
        --arg user_data "$user_data_b64" \
        '{
            name: $name,
            server_type: $server_type,
            image: "debian-12",
            location: "fsn1",
            ssh_keys: [],
            user_data: $user_data
        }')
    
    local response=$(curl -s -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        https://api.hetzner.cloud/v1/servers)
    
    echo "$response" | jq -r '.server.id // .error.message'
}

deploy_aws() {
    local region="${AWS_REGION:-us-east-1}"
    local type="${1:-t3.medium}"
    
    info "Deploying to AWS EC2 (type: $type, region: $region)"
    
    aws ec2 run-instances \
        --image-id ami-0c7217cdde317cfec \
        --instance-type "$type" \
        --key-name "${AWS_KEY_NAME:-kirat-os}" \
        --security-group-ids "${AWS_SG_ID:-}" \
        --subnet-id "${AWS_SUBNET_ID:-}" \
        --user-data "file://cloud-init/kirat-server.yaml" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$VM_NAME}]" \
        --region "$region"
}

deploy_digitalocean() {
    local token="${DO_API_TOKEN:-}"
    local size="${1:-s-2vcpu-4gb}"
    
    if [ -z "$token" ]; then
        error "Set DO_API_TOKEN environment variable"
        exit 1
    fi
    
    info "Deploying to DigitalOcean (size: $size)"
    
    # FIX 1 (DigitalOcean): Also use jq for safe JSON encoding here.
    local user_data_b64
    user_data_b64=$(base64 -w 0 < cloud-init/kirat-server.yaml)
    
    local payload
    payload=$(jq -n \
        --arg name "$VM_NAME" \
        --arg size "$size" \
        --arg user_data "$user_data_b64" \
        '{
            name: $name,
            region: "nyc3",
            size: $size,
            image: "debian-12-x64",
            ssh_keys: [],
            user_data: $user_data,
            tags: ["kirat-os"]
        }')
    
    curl -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $token" \
        -d "$payload" \
        https://api.digitalocean.com/v2/droplets
}

# ─────────────────────────────────────────────────────────────────────────────
# CLOUD-INIT TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────

generate_cloud_init() {
    mkdir -p cloud-init
    
    cat > cloud-init/kirat-server.yaml << 'EOF'
#cloud-config
hostname: kirat-server
fqdn: kirat-server.local
manage_etc_hosts: true

users:
  - name: sentinel
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - # Add your SSH public key here
    groups: users, admin, docker

packages:
  - curl
  - wget
  - git
  - vim
  - htop
  - docker.io
  - containerd
  - python3
  - python3-pip
  - python3-venv
  - qemu-guest-agent

runcmd:
  # Enable QEMU guest agent for better VM integration
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
  
  # Install Sentinel AI
  - mkdir -p /opt/sentinel
  - cd /opt/sentinel
  - python3 -m venv venv
  - source venv/bin/activate
  - pip install fastapi uvicorn prometheus-client psutil pyyaml
  
  # Download and install Sentinel
  - git clone https://github.com/kirat-os/sentinel-core.git /opt/sentinel/src
  
  # FIX 3: Create the systemd service inline instead of copying from
  # /opt/sentinel/src/config/sentinel.service, which may not exist.
  - |
    cat > /etc/systemd/system/sentinel.service << 'SERVICECF'
    [Unit]
    Description=Sentinel AI Core
    After=network-online.target docker.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=sentinel
    Group=sentinel
    WorkingDirectory=/opt/sentinel
    Environment=PYTHONPATH=/opt/sentinel
    Environment=SENTINEL_CONFIG=/etc/sentinel/sentinel.yaml
    ExecStart=/opt/sentinel/venv/bin/python3 /opt/sentinel/src/main.py
    Restart=always
    RestartSec=5
    StandardOutput=journal
    StandardError=journal
    SyslogIdentifier=sentinel

    [Install]
    WantedBy=multi-user.target
    SERVICECF
  - systemctl daemon-reload
  - systemctl enable sentinel
  - systemctl start sentinel
  
  # Post-install message
  - echo "KIRAT OS Server installed. Access Sentinel at http://$(hostname -I | awk '{print $1}'):8080"

final_message: "KIRAT OS Server setup complete!"
EOF
    
    ok "Cloud-init template generated: cloud-init/kirat-server.yaml"
    info "Edit the file to add your SSH key before deploying"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

show_help() {
    cat << 'HELP'
KIRAT OS Server - VM Test & Cloud Deploy

VM TESTING:
  create-vm              Create a VM disk image
  delete-vm              Delete VM disk
  test-install <iso>     Test installation from ISO
  boot                   Boot installed server (with GUI)
  boot-headless          Boot server in background (SSH only)
  stop-headless          Stop background VM
  ssh                    SSH into running VM

CLOUD DEPLOYMENT:
  cloud-init             Generate cloud-init template
  deploy-hetzner [type]  Deploy to Hetzner Cloud (cx11, cx21, cx31...)
  deploy-aws [type]      Deploy to AWS EC2 (t3.micro, t3.medium...)
  deploy-do [size]       Deploy to DigitalOcean (s-1vcpu-1gb...)

EXAMPLES:
  # Create VM and test installation
  ./vm-server.sh create-vm
  ./vm-server.sh test-install kirat-os-server.iso

  # Boot and test
  ./vm-server.sh boot
  ./vm-server.sh ssh

  # Deploy to cloud (set API token first)
  export HETZNER_API_TOKEN="your-token"
  ./vm-server.sh deploy-hetzner cx31

HELP
}

main() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        create-vm) create_vm ;;
        delete-vm) delete_vm ;;
        test-install) test_install "$@" ;;
        boot) boot_server ;;
        boot-headless) boot_headless ;;
        stop-headless) stop_headless ;;
        ssh) ssh_vm ;;
        cloud-init) generate_cloud_init ;;
        deploy-hetzner) deploy_hetzner "$@" ;;
        deploy-aws) deploy_aws "$@" ;;
        deploy-do) deploy_digitalocean "$@" ;;
        help|--help|-h) show_help ;;
        *) error "Unknown command: $cmd"; show_help; exit 1 ;;
    esac
}

main "$@"
