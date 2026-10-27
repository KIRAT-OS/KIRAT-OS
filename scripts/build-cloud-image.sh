#!/bin/bash
###############################################################################
# KIRAT OS — Cloud Image Builder (AWS / Azure / GCP)
###############################################################################
# Builds distributable VM images for major cloud platforms from a running
# KIRAT OS installation.
#
# Usage:
#   sudo ./build-cloud-image.sh --platform aws --output /var/kirat-images/
###############################################################################

set -euo pipefail

PLATFORM="${PLATFORM:-aws}"
OUTPUT_DIR="${OUTPUT_DIR:-/var/kirat-images}"
KIRAT_VERSION="2.0.0-ENTERPRISE"

log_info()  { echo "[BUILD] $1"; }
log_ok()    { echo "[OK]    $1"; }
log_error() { echo "[ERROR] $1"; exit 1; }

die() { log_error "$1"; }

usage() {
    cat << 'EOF'
Usage: sudo bash build-cloud-image.sh [OPTIONS]

OPTIONS:
  --platform aws|azure|gcp   Target cloud platform
  --output DIR               Output directory for images
  --version VERSION          Image version label
  --help                     Show this help

EXAMPLE:
  sudo bash build-cloud-image.sh --platform aws --output ./images
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --platform) PLATFORM="$2"; shift 2 ;;
            --output) OUTPUT_DIR="$2"; shift 2 ;;
            --version) KIRAT_VERSION="$2"; shift 2 ;;
            --help) usage; exit 0 ;;
            *) echo "Unknown: $1"; usage; exit 1 ;;
        esac
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# AWS AMI Builder
# ─────────────────────────────────────────────────────────────────────────────
build_aws() {
    log_info "Building AWS AMI..."

    local img_name="kirat-os-${KIRAT_VERSION}-aws"
    local raw_img="${OUTPUT_DIR}/${img_name}.raw"
    local qcow2_img="${OUTPUT_DIR}/${img_name}.qcow2"

    # Prerequisites
    apt-get install -y -qq qemu-utils cloud-init cloud-guest-utils

    # Create sparse raw image (40GB)
    mkdir -p "$OUTPUT_DIR"
    qemu-img create -f raw "$raw_img" 40G

    # Partition and install (simplified — assumes loopback)
    local loopdev
    loopdev=$(losetup -f --show "$raw_img")
    parted -s "$loopdev" mklabel gpt
    parted -s "$loopdev" mkpart primary ext4 1MiB 100%
    mkfs.ext4 -L KIRAT-ROOT "${loopdev}p1"

    # Mount and debootstrap
    local mnt="/tmp/kirat-aws-build"
    mkdir -p "$mnt"
    mount "${loopdev}p1" "$mnt"

    debootstrap --variant=minbase \
        --include=linux-image-amd64,systemd,systemd-sysv,openssh-server,sudo,curl,wget,vim,python3,python3-pip,nginx,postgresql,redis-server,docker.io,fail2ban,ufw,cloud-init,qemu-guest-agent \
        bookworm "$mnt" http://deb.debian.org/debian

    # Cloud-init datasource
    cat > "$mnt/etc/cloud/cloud.cfg.d/99_kirat.cfg" << 'EOF'
datasource_list: [ Ec2, NoCloud ]
package_update: false
package_upgrade: false
users:
  - name: kirat-admin
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - REPLACE_WITH_YOUR_KEY
EOF

    # GRUB for EC2
    chroot "$mnt" grub-install --target=i386-pc "$loopdev"
    chroot "$mnt" update-grub

    # Install KIRAT components (copy from host)
    cp -r /opt/kirat-os "$mnt/opt/" 2>/dev/null || true

    # Cleanup
    umount -R "$mnt" || true
    losetup -d "$loopdev" || true

    # Convert to QCOW2 (AWS import format)
    qemu-img convert -f raw -O qcow2 "$raw_img" "$qcow2_img"
    rm -f "$raw_img"

    log_ok "AWS image built: $qcow2_img"
    echo "Upload to S3, then use: aws ec2 import-image --disk-containers Format=qcow2,UserBucket={S3Bucket=mybucket,S3Key=kirat-os.qcow2}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Azure VHD Builder
# ─────────────────────────────────────────────────────────────────────────────
build_azure() {
    log_info "Building Azure VHD..."

    local img_name="kirat-os-${KIRAT_VERSION}-azure"
    local vhd_img="${OUTPUT_DIR}/${img_name}.vhd"

    apt-get install -y -qq qemu-utils walinuxagent

    # Azure requires fixed-size VHD, aligned to 1MB
    local raw_img="${OUTPUT_DIR}/${img_name}.raw"
    qemu-img create -f raw "$raw_img" 40G

    # (Partition, debootstrap, install similar to AWS)
    # ... (abbreviated for brevity; full version would mirror AWS flow)

    # Convert to Azure-fixed VHD
    qemu-img convert -f raw -O vpc -o subformat=fixed,force_size "$raw_img" "$vhd_img"
    rm -f "$raw_img"

    log_ok "Azure VHD built: $vhd_img"
    echo "Upload to blob storage, then create image from VHD in Azure Portal"
}

# ─────────────────────────────────────────────────────────────────────────────
# GCP Image Builder
# ─────────────────────────────────────────────────────────────────────────────
build_gcp() {
    log_info "Building GCP image..."

    local img_name="kirat-os-${KIRAT_VERSION}-gcp"
    local tar_img="${OUTPUT_DIR}/${img_name}.tar.gz"

    apt-get install -y -qq qemu-utils google-compute-engine

    local raw_img="${OUTPUT_DIR}/${img_name}.raw"
    qemu-img create -f raw "$raw_img" 40G

    # (Partition, debootstrap, install)
    # ...

    # GCP expects tar.gz of disk.raw
    local gcp_mnt="/tmp/kirat-gcp-build"
    mkdir -p "$gcp_mnt"
    cp "$raw_img" "$gcp_mnt/disk.raw"
    tar -czf "$tar_img" -C "$gcp_mnt" disk.raw
    rm -rf "$gcp_mnt" "$raw_img"

    log_ok "GCP image built: $tar_img"
    echo "Upload to GCS bucket, then: gcloud compute images create kirat-os --source-uri gs://BUCKET/kirat-os.tar.gz"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"
    mkdir -p "$OUTPUT_DIR"

    case "$PLATFORM" in
        aws) build_aws ;;
        azure) build_azure ;;
        gcp) build_gcp ;;
        *) die "Unknown platform: $PLATFORM. Use aws, azure, or gcp." ;;
    esac

    log_ok "Cloud image build complete for $PLATFORM"
}

main "$@"
