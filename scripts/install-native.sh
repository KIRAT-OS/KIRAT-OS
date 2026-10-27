#!/bin/bash
###############################################################################
# KIRAT OS - NATIVE OS INSTALLER FOR PRODUCTION BUSINESS DEPLOYMENT
###############################################################################
# Wipes the entire target disk and installs KIRAT OS as the PRIMARY operating
# system with full BIOS/UEFI security hardening.
#
# TARGET: Fresh computers, bare metal servers, dedicated business machines
# RESULT: Hardened base installation; service health requires post-boot testing
#
# WARNING: THIS DESTROYS ALL DATA ON THE TARGET DISK. BACKUP FIRST.
#
# Usage: sudo ./install-native.sh --disk /dev/nvme0n1 --hostname business-01
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

TARGET_DISK="${TARGET_DISK:-/dev/sda}"
HOSTNAME="${HOSTNAME:-kirat-os-business}"
USERNAME="${USERNAME:-kirat-admin}"
TIMEZONE="${TIMEZONE:-UTC}"
BUSINESS_EMAIL="${BUSINESS_EMAIL:-admin@localhost}"
DOMAIN="${DOMAIN:-localhost}"
BUILD_DIR="/tmp/kirat-os-native-build"
INSTALL_MOUNT="/mnt/kirat-os-root"
KIRAT_VERSION="2.0.8-PRE-RELEASE"
OLLAMA_VERSION="0.40.11"
ENABLE_QUANTUM="${ENABLE_QUANTUM:-false}"

# Resume support — stage markers live inside the target root so an
# interrupted install (power loss, crash) can continue where it stopped.
RESUME_MODE=false
STAGE_MARKER="$INSTALL_MOUNT/var/lib/kirat-os/install-stage"

# Post-Quantum Cryptography
PQC_TLS="kyber768:x25519"
PQC_SSH="sntrup761x25519-sha512@openssh.com"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'
BOLD='\033[1m'

log_info()  { echo -e "${BLUE}[BUILD]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[FAIL]${NC}   $1"; }
log_crit()  { echo -e "${MAGENTA}[CRIT]${NC}  $1"; }
log_stage() { echo ""; echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}${BOLD}  ▶ $1${NC}"; echo -e "${CYAN}${BOLD}══════════════════════════════════════════════════════════════════════${NC}"; echo ""; }

die() { log_error "$1"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 0: PRE-FLIGHT — Validate installation prerequisites
# ─────────────────────────────────────────────────────────────────────────────

preflight() {
    log_stage "STAGE 0: PRE-FLIGHT VERIFICATION"

    [ "$EUID" -eq 0 ] || die "Must run as root. Use: sudo bash $0"
    [ "$USERNAME" = "kirat-admin" ] || die "This installer supports only USERNAME=kirat-admin"
    [ "$(uname -m)" = "x86_64" ] || die "KIRAT OS requires x86_64"
    [ -b "$TARGET_DISK" ] || die "Target disk not found: $TARGET_DISK"

    # Reject foreign mounts, while allowing idempotent resume of our own mounts.
    local dev source parent mounted
    while read -r dev; do
        while read -r mounted; do
            case "$mounted" in
                "$INSTALL_MOUNT"|"$INSTALL_MOUNT"/*) ;;
                *) die "Target or its partition is mounted outside the installer: $dev at $mounted" ;;
            esac
        done < <(findmnt -rn -S "$dev" -o TARGET || true)
    done < <(lsblk -lnpo NAME "$TARGET_DISK")
    source=$(findmnt -n -o SOURCE / || true)
    if [ -n "$source" ]; then
        source=$(readlink -f "$source")
        while read -r parent; do
            [ "$parent" != "$TARGET_DISK" ] || die "Target backs the running OS; boot independent live media"
        done < <(lsblk -snpo NAME "$source")
    fi

    DISK_SIZE=$(lsblk -bnd -o SIZE "$TARGET_DISK" | head -1)
    DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
    [ "$DISK_SIZE_GB" -ge 50 ] || die "Disk too small. Need 50GB minimum. Have ${DISK_SIZE_GB}GB."
    log_ok "Target disk: $TARGET_DISK (${DISK_SIZE_GB}GB); mount and running-OS checks passed"

    if [ ! -d /run/live/medium ] && [ ! -f /proc/sys/fs/binfmt_misc/WSLInterop ]; then
        log_warn "Not in a recognized live environment"
        read -p "Type DESTROY to acknowledge the additional risk: " confirm
        [ "$confirm" = "DESTROY" ] || die "Aborted for safety"
    fi

    # Check network (HTTP-based — ICMP ping is unreliable on many
    # consumer/WSL networks where only web traffic is permitted)
    if curl -sI --max-time 10 "${DEB_MIRROR:-http://deb.debian.org/debian}/dists/bookworm/Release" >/dev/null 2>&1 \
       || curl -sI --max-time 10 https://deb.debian.org >/dev/null 2>&1; then
        log_ok "Internet connectivity confirmed"
    else
        die "No internet. Required to download packages and models."
    fi

    # Check RAM. MemTotal is what the kernel sees AFTER firmware and
    # integrated-GPU reservations, so an "8GB" machine typically reports
    # 7.4-7.9GiB here. Hard-fail below 7GiB, merely warn below 8.
    RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    RAM_GB=$((RAM_KB / 1024 / 1024))
    if [ "$RAM_GB" -lt 7 ]; then
        die "Insufficient RAM: ${RAM_GB}GB visible. Need 8GB installed (7GiB minimum after firmware reservations)."
    fi
    if [ "$RAM_GB" -lt 8 ]; then
        log_warn "RAM: ${RAM_GB}GB visible after firmware reservation (8GB installed recommended)"
    fi
    log_ok "RAM: ${RAM_GB}GB"

    # Check UEFI vs BIOS
    if [ -d /sys/firmware/efi ]; then
        BOOT_MODE="UEFI"
        log_ok "Boot mode: UEFI (Secure Boot capable)"
    else
        BOOT_MODE="BIOS"
        log_warn "Boot mode: Legacy BIOS (Secure Boot not available)"
    fi

    # Check TPM 2.0
    if [ -d /sys/class/tpm/tpm0 ] && [ -f /sys/class/tpm/tpm0/tpm_version_major ]; then
        TPM_VERSION=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "0")
        if [ "$TPM_VERSION" = "2" ]; then
            log_ok "TPM 2.0 detected"
            HAS_TPM2=1
        else
            log_warn "TPM detected but not version 2.0"
            HAS_TPM2=0
        fi
    else
        log_warn "No TPM detected"
        HAS_TPM2=0
    fi

    [ "$ENABLE_QUANTUM" = false ] || [ "$ENABLE_QUANTUM" = true ] || die "ENABLE_QUANTUM must be true or false"
    [ "$ENABLE_QUANTUM" = false ] || die "Native Quantum service integration is not supported in this pre-release; use ENABLE_QUANTUM=false (the default)"
    log_ok "Pre-flight passed; runtime health requires post-boot measurement"
}

# ─────────────────────────────────────────────────────────────────────────────
# RESUME SUPPORT — survive power loss / crashes mid-install
# ─────────────────────────────────────────────────────────────────────────────
# The installer records each completed stage in
# $INSTALL_MOUNT/var/lib/kirat-os/install-stage. If the machine dies
# mid-install, booting the ISO again and choosing Install detects the
# existing LUKS volumes and offers to RESUME instead of wiping.

derive_partitions() {
    # Same layout stage1 creates. Called after parted (fresh) or on an
    # existing disk (resume), so partitions always exist at call time.
    if [ "$BOOT_MODE" = "UEFI" ]; then
        EFI_PART="${TARGET_DISK}p1"; [ -b "$EFI_PART" ] || EFI_PART="${TARGET_DISK}1"
        BOOT_PART="${TARGET_DISK}p2"; [ -b "$BOOT_PART" ] || BOOT_PART="${TARGET_DISK}2"
        ROOT_PART="${TARGET_DISK}p3"; [ -b "$ROOT_PART" ] || ROOT_PART="${TARGET_DISK}3"
        DATA_PART="${TARGET_DISK}p4"; [ -b "$DATA_PART" ] || DATA_PART="${TARGET_DISK}4"
    else
        EFI_PART=""
        BOOT_PART="${TARGET_DISK}1"
        ROOT_PART="${TARGET_DISK}2"
        DATA_PART="${TARGET_DISK}3"
    fi
}

detect_existing_install() {
    derive_partitions
    [ -b "${ROOT_PART:-/dev/null}" ] || return 1
    [ "$(blkid -o value -s TYPE "$ROOT_PART" 2>/dev/null)" = "crypto_LUKS" ]
}

resume_mount_target() {
    log_stage "RESUME: UNLOCKING EXISTING KIRAT OS INSTALLATION"
    [ -b "${DATA_PART:-/dev/null}" ] || die "resume: data partition missing; choose a fresh install"
    if [ ! -e /dev/mapper/kirat-root ]; then
        while true; do
            read -s -p "Enter LUKS passphrase for the existing installation: " LUKS_PASS
            echo ""
            printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" kirat-root --key-file - 2>/dev/null && break
            log_warn "Unlock failed; try again"
        done
    fi
    if [ ! -e /dev/mapper/kirat-data ]; then
        [ -n "${LUKS_PASS:-}" ] || die "resume: data is locked but root was already open; close both mappers and retry"
        printf '%s' "$LUKS_PASS" | cryptsetup open "$DATA_PART" kirat-data --key-file - 2>/dev/null \
            || die "resume: cannot unlock data; choose a fresh install if its passphrase differs"
    fi
    [ -b /dev/mapper/kirat-root ] && [ -b /dev/mapper/kirat-data ] || die "resume: required encrypted volumes unavailable"

    mkdir -p "$INSTALL_MOUNT" "$INSTALL_MOUNT/boot" "$INSTALL_MOUNT/data"
    mountpoint -q "$INSTALL_MOUNT" || mount /dev/mapper/kirat-root "$INSTALL_MOUNT" \
        || die "resume: cannot mount root; choose a fresh install if stage 1 did not finish"
    mountpoint -q "$INSTALL_MOUNT/boot" || mount "$BOOT_PART" "$INSTALL_MOUNT/boot" \
        || die "resume: cannot mount /boot; choose a fresh install"
    mountpoint -q "$INSTALL_MOUNT/data" || mount /dev/mapper/kirat-data "$INSTALL_MOUNT/data" \
        || die "resume: cannot mount /data; choose a fresh install"
    if [ -n "${EFI_PART:-}" ] && [ -b "$EFI_PART" ]; then
        mkdir -p "$INSTALL_MOUNT/boot/efi"
        mountpoint -q "$INSTALL_MOUNT/boot/efi" || mount "$EFI_PART" "$INSTALL_MOUNT/boot/efi" \
            || die "resume: cannot mount EFI partition"
    fi
    mountpoint -q "$INSTALL_MOUNT" && mountpoint -q "$INSTALL_MOUNT/boot" && mountpoint -q "$INSTALL_MOUNT/data" \
        || die "resume: root, boot, and data validation failed"
    [ -d "$INSTALL_MOUNT/etc" ] || die "resume: target root is not a base system; choose a fresh install"

    mkdir -p "$INSTALL_MOUNT/dev" "$INSTALL_MOUNT/proc" "$INSTALL_MOUNT/sys" "$INSTALL_MOUNT/run"
    mountpoint -q "$INSTALL_MOUNT/dev"  || mount --bind /dev  "$INSTALL_MOUNT/dev"
    mountpoint -q "$INSTALL_MOUNT/proc" || mount --bind /proc "$INSTALL_MOUNT/proc"
    mountpoint -q "$INSTALL_MOUNT/sys"  || mount --bind /sys  "$INSTALL_MOUNT/sys"
    mountpoint -q "$INSTALL_MOUNT/run"  || mount --bind /run  "$INSTALL_MOUNT/run"
    cp -L /etc/resolv.conf "$INSTALL_MOUNT/etc/resolv.conf" 2>/dev/null || true
    chroot "$INSTALL_MOUNT" /bin/bash -c 'export DEBIAN_FRONTEND=noninteractive; dpkg --configure -a; apt-get install -f -y -qq' \
        || die "resume: package state repair failed"
    rm -f "$INSTALL_MOUNT/var/lib/aide/aide.db.new" "$INSTALL_MOUNT/var/lib/aide/aide.db" 2>/dev/null || true

    # Only validated root+boot+data mounts prove that stage 1 completed.
    mkdir -p "$(dirname "$STAGE_MARKER")"
    grep -qx stage1 "$STAGE_MARKER" 2>/dev/null || echo stage1 >> "$STAGE_MARKER"
    RESUME_MODE=true
    COMPLETED=$(wc -l < "$STAGE_MARKER")
    log_ok "Resume mode active — $COMPLETED validated stage marker(s)"
}

stage_done() {
    [ -f "$STAGE_MARKER" ] && grep -qx "$1" "$STAGE_MARKER"
}

run_stage() {
    local name="$1"; shift
    if [ "$name" != stage10 ] && [ "$RESUME_MODE" = true ] && stage_done "$name"; then
        log_info "Skipping $name — already completed (resume mode)"
        return 0
    fi
    "$@"
    mkdir -p "$(dirname "$STAGE_MARKER")"
    grep -qx "$name" "$STAGE_MARKER" 2>/dev/null || echo "$name" >> "$STAGE_MARKER"
    sync "$STAGE_MARKER"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 1: DESTROY AND PARTITION
# ─────────────────────────────────────────────────────────────────────────────

stage1_partition() {
    log_stage "STAGE 1: DISK DESTRUCTION AND PARTITIONING"

    log_crit "ABOUT TO DESTROY ALL DATA ON $TARGET_DISK"
    log_crit "This action is IRREVERSIBLE."
    echo ""
    read -p "Type the full disk path ($TARGET_DISK) to confirm destruction: " confirm
    if [ "$confirm" != "$TARGET_DISK" ]; then
        die "Disk path mismatch. Aborted."
    fi

    # Unmount anything on target
    umount -R "$INSTALL_MOUNT" 2>/dev/null || true
    swapoff -a 2>/dev/null || true

    # Wipe disk signatures
    log_info "Wiping disk signatures..."
    wipefs -a "$TARGET_DISK" 2>/dev/null || dd if=/dev/zero of="$TARGET_DISK" bs=1M count=10 status=none

    # Create partition table
    if [ "$BOOT_MODE" = "UEFI" ]; then
        log_info "Creating GPT partition table..."
        parted -s "$TARGET_DISK" mklabel gpt

        # EFI System Partition (1GB for future-proofing)
        parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 1025MiB
        parted -s "$TARGET_DISK" set 1 esp on
        EFI_PART="${TARGET_DISK}p1"
        [ -b "$EFI_PART" ] || EFI_PART="${TARGET_DISK}1"

        # Boot partition (2GB ext4)
        parted -s "$TARGET_DISK" mkpart primary ext4 1025MiB 3073MiB
        BOOT_PART="${TARGET_DISK}p2"
        [ -b "$BOOT_PART" ] || BOOT_PART="${TARGET_DISK}2"

        # Root partition (40GB encrypted)
        parted -s "$TARGET_DISK" mkpart primary 3073MiB 43GiB
        ROOT_PART="${TARGET_DISK}p3"
        [ -b "$ROOT_PART" ] || ROOT_PART="${TARGET_DISK}3"

        # Data partition (remainder)
        parted -s "$TARGET_DISK" mkpart primary 43GiB 100%
        DATA_PART="${TARGET_DISK}p4"
        [ -b "$DATA_PART" ] || DATA_PART="${TARGET_DISK}4"
    else
        log_info "Creating MBR partition table (legacy BIOS)..."
        parted -s "$TARGET_DISK" mklabel msdos

        # Boot partition
        parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 3GiB
        parted -s "$TARGET_DISK" set 1 boot on
        BOOT_PART="${TARGET_DISK}1"

        # Root partition
        parted -s "$TARGET_DISK" mkpart primary 3GiB 43GiB
        ROOT_PART="${TARGET_DISK}2"

        # Data partition
        parted -s "$TARGET_DISK" mkpart primary 43GiB 100%
        DATA_PART="${TARGET_DISK}3"
    fi

    # Format partitions
    log_info "Formatting partitions..."
    [ -n "${EFI_PART:-}" ] && mkfs.fat -F32 -n KIRAT-EFI "$EFI_PART"
    mkfs.ext4 -F -L KIRAT-BOOT "$BOOT_PART"

    # LUKS2 encryption for root with Argon2id
    log_info "Setting up LUKS2 encryption for root partition..."
    log_crit "You MUST remember this passphrase. There is NO recovery."

    # Prompt for passphrase (twice for confirmation)
    while true; do
        read -s -p "Enter strong LUKS passphrase for root encryption: " LUKS_PASS
        echo ""
        read -s -p "Confirm LUKS passphrase: " LUKS_PASS2
        echo ""
        if [ "$LUKS_PASS" = "$LUKS_PASS2" ] && [ "${#LUKS_PASS}" -ge 12 ]; then
            break
        fi
        log_warn "Passphrases do not match or are shorter than 12 characters. Try again."
    done

    # Store passphrase securely in initramfs for keyfile unlock (optional file-based)
    # For maximum security, we use passphrase-only (no keyfile stored on disk)
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 \
        --hash sha3-512 --pbkdf argon2id \
        --pbkdf-memory 1048576 --pbkdf-parallel 4 \
        --sector-size 4096 \
        "$ROOT_PART" --key-file -

    # Open encrypted root with SAME passphrase
    printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" kirat-root --key-file -

    mkfs.ext4 -F -L KIRAT-ROOT /dev/mapper/kirat-root

    # Encrypt /data partition with same passphrase
    log_info "Setting up LUKS2 encryption for data partition..."
    printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 \
        --cipher aes-xts-plain64 --key-size 512 \
        --hash sha3-512 --pbkdf argon2id \
        --pbkdf-memory 1048576 --pbkdf-parallel 4 \
        "$DATA_PART" --key-file -
    printf '%s' "$LUKS_PASS" | cryptsetup open "$DATA_PART" kirat-data --key-file -
    mkfs.ext4 -F -L KIRAT-DATA /dev/mapper/kirat-data

    log_ok "Partitioning and encryption complete"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 2: BASE SYSTEM INSTALL
# ─────────────────────────────────────────────────────────────────────────────

stage2_base_install() {
    log_stage "STAGE 2: BASE SYSTEM INSTALLATION"

    # Idempotent mount guards; every required mount is fatal if unavailable.
    mkdir -p "$INSTALL_MOUNT" "$INSTALL_MOUNT/boot" "$INSTALL_MOUNT/data"
    mountpoint -q "$INSTALL_MOUNT" || mount /dev/mapper/kirat-root "$INSTALL_MOUNT"
    mountpoint -q "$INSTALL_MOUNT/boot" || mount "$BOOT_PART" "$INSTALL_MOUNT/boot"
    mountpoint -q "$INSTALL_MOUNT/data" || mount /dev/mapper/kirat-data "$INSTALL_MOUNT/data"
    if [ -n "${EFI_PART:-}" ]; then
        mkdir -p "$INSTALL_MOUNT/boot/efi"
        mountpoint -q "$INSTALL_MOUNT/boot/efi" || mount "$EFI_PART" "$INSTALL_MOUNT/boot/efi"
    fi
    mountpoint -q "$INSTALL_MOUNT" && mountpoint -q "$INSTALL_MOUNT/boot" && mountpoint -q "$INSTALL_MOUNT/data" \
        || die "stage2: required root, boot, or data mount is missing"

    # Debootstrap
    log_info "Installing Debian base system (this takes 10-20 minutes)..."
    # python3-cffi-backend is listed explicitly: when debootstrap runs from a
    # foreign-suite host, the dependency resolver can miss this virtual-package
    # provider that python3-cryptography requires.
    debootstrap --variant=minbase \
        --include=linux-image-amd64,systemd,systemd-sysv,\
grub-pc,grub-efi-amd64,grub-efi-amd64-bin,grub-efi-amd64-signed,shim-signed,\
openssh-server,libfido2-1,sudo,curl,wget,vim,nano,\
htop,iotop,ncdu,tree,rsync,git,\
net-tools,iproute2,iptables,nftables,\
dnsutils,ca-certificates,openssl,\
parted,e2fsprogs,cryptsetup,cryptsetup-initramfs,\
python3,python3-pip,python3-venv,python3-dev,python3-cryptography,python3-cffi-backend,python3-systemd,\
build-essential,dkms,linux-headers-amd64,\
nginx,certbot,python3-certbot-nginx,\
postgresql,postgresql-contrib,\
redis-server,\
docker.io,containerd,\
fail2ban,ufw,zstd,\
console-setup,keyboard-configuration,\
cryptsetup,cryptsetup-bin,\
tpm2-tools,tpm2-abrmd,\
sbsigntool,efitools,\
ca-certificates,gnupg,lsb-release,gnupg \
        bookworm "$INSTALL_MOUNT" "${DEB_MIRROR:-http://deb.debian.org/debian}" \
        || die "debootstrap failed; required base packages were not installed"

    # SELF-HEAL: bind pseudo-filesystems and repair package configuration
    # from inside the target. Handles cffi/cryptography ordering failures.
    # Only run when the base rootfs actually materialized (debootstrap may
    # abort before creating /dev, /proc etc. on hard download failures).
    if [ ! -d "$INSTALL_MOUNT/bin" ]; then
        die "debootstrap failed to create a base rootfs — cannot self-heal. Re-run installer."
    fi
    mkdir -p "$INSTALL_MOUNT/dev" "$INSTALL_MOUNT/proc" "$INSTALL_MOUNT/sys" "$INSTALL_MOUNT/run"
    mountpoint -q "$INSTALL_MOUNT/dev" || mount --bind /dev "$INSTALL_MOUNT/dev"
    mountpoint -q "$INSTALL_MOUNT/proc" || mount --bind /proc "$INSTALL_MOUNT/proc"
    mountpoint -q "$INSTALL_MOUNT/sys" || mount --bind /sys "$INSTALL_MOUNT/sys"
    mountpoint -q "$INSTALL_MOUNT/run" || mount --bind /run "$INSTALL_MOUNT/run"
    cp -L /etc/resolv.conf "$INSTALL_MOUNT/etc/resolv.conf" 2>/dev/null || true
    chroot "$INSTALL_MOUNT" /bin/bash -c '
        set -e
        dpkg --configure -a
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-cffi-backend python3-cryptography
        dpkg --configure -a
    ' || die "Required package configuration failed"

    # Post-quantum note: oqs-provider / liboqs do NOT exist in Debian 12
    # (bookworm) repos — see earlier comment in this stage.

    # Mount pseudo-filesystems (already bound in self-heal above; idempotent)
    mountpoint -q "$INSTALL_MOUNT/dev"  || mount --bind /dev  "$INSTALL_MOUNT/dev"
    mountpoint -q "$INSTALL_MOUNT/proc" || mount --bind /proc "$INSTALL_MOUNT/proc"
    mountpoint -q "$INSTALL_MOUNT/sys"  || mount --bind /sys  "$INSTALL_MOUNT/sys"
    mountpoint -q "$INSTALL_MOUNT/run"  || mount --bind /run  "$INSTALL_MOUNT/run"

    log_ok "Base system installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 3: SYSTEM CONFIGURATION
# ─────────────────────────────────────────────────────────────────────────────

stage3_system_config() {
    log_stage "STAGE 3: SYSTEM CONFIGURATION"

    # Hostname
    echo "$HOSTNAME" > "$INSTALL_MOUNT/etc/hostname"
    cat > "$INSTALL_MOUNT/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   $HOSTNAME $DOMAIN
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Timezone
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$INSTALL_MOUNT/etc/localtime"

    # Locale
    echo "en_US.UTF-8 UTF-8" > "$INSTALL_MOUNT/etc/locale.gen"
    chroot "$INSTALL_MOUNT" locale-gen
    echo "LANG=en_US.UTF-8" > "$INSTALL_MOUNT/etc/default/locale"

    # Fstab
    cat > "$INSTALL_MOUNT/etc/fstab" << EOF
# KIRAT OS - Encrypted root
/dev/mapper/kirat-root  /              ext4    defaults,noatime,errors=remount-ro  0  1
UUID=$(blkid -s UUID -o value "$BOOT_PART")  /boot          ext4    defaults                            0  2
EOF

    if [ -n "${EFI_PART:-}" ]; then
        echo "UUID=$(blkid -s UUID -o value "$EFI_PART")  /boot/efi      vfat    umask=0077                          0  1" >> "$INSTALL_MOUNT/etc/fstab"
    fi

    echo "/dev/mapper/kirat-data  /data          ext4    defaults,noatime                    0  2" >> "$INSTALL_MOUNT/etc/fstab"

    # crypttab for LUKS (none = prompt for passphrase at boot)
    echo "kirat-root UUID=$(blkid -s UUID -o value "$ROOT_PART") none luks,discard" > "$INSTALL_MOUNT/etc/crypttab"
    echo "kirat-data UUID=$(blkid -s UUID -o value "$DATA_PART") none luks,discard" >> "$INSTALL_MOUNT/etc/crypttab"
    log_warn "Encryption passphrase required for root and data at every boot. Consider TPM 2.0 auto-unlock post-install."

    # Network (systemd-networkd for server)
    cat > "$INSTALL_MOUNT/etc/systemd/network/20-wired.network" << 'EOF'
[Match]
Name=en*
Name=eth*

[Network]
DHCP=yes
IPv6PrivacyExtensions=yes

[DHCPv4]
RouteMetric=100

[IPv6AcceptRA]
RouteMetric=100
EOF

    chroot "$INSTALL_MOUNT" systemctl enable systemd-networkd || log_warn "enable systemd-networkd failed (non-fatal)"
    # systemd-resolved may not exist in the target (unit missing in minbase
    # installs) — "systemctl enable" then errors hard. Guard it: enable only
    # if the unit exists, otherwise fall back to a static /etc/resolv.conf.
    if chroot "$INSTALL_MOUNT" systemctl cat systemd-resolved.service &>/dev/null; then
        chroot "$INSTALL_MOUNT" systemctl enable systemd-resolved || log_warn "enable systemd-resolved failed (non-fatal)"
    else
        log_warn "systemd-resolved unit not present — writing static /etc/resolv.conf fallback"
        rm -f "$INSTALL_MOUNT/etc/resolv.conf"
        cat > "$INSTALL_MOUNT/etc/resolv.conf" << 'EOF'
# KIRAT OS static DNS fallback (systemd-resolved unavailable in target)
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    fi
    # Root password (locked — emergency console only)
    chroot "$INSTALL_MOUNT" usermod -p "$(openssl passwd -6 "kirat-emergency-$(openssl rand -hex 8)")" root || log_warn "password set failed for root (non-fatal)"
    chroot "$INSTALL_MOUNT" passwd -l root
    chroot "$INSTALL_MOUNT" usermod -s /usr/sbin/nologin root

    # RBAC tiered user model applied in stage3b_rbac_setup

    # SSH hardening with PQC
    cat > "$INSTALL_MOUNT/etc/ssh/sshd_config.d/kirat-production.conf" << EOF
# KIRAT OS Production SSH Hardening
Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
KexAlgorithms $PQC_SSH,curve25519-sha256,ecdh-sha2-nistp521
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
HostKeyAlgorithms ssh-ed25519,rsa-sha2-512,rsa-sha2-256
PubkeyAcceptedKeyTypes ssh-ed25519,sk-ssh-ed25519@openssh.com,rsa-sha2-512,rsa-sha2-256
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
DisableForwarding yes
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
Banner /etc/ssh/kirat-banner
EOF

    cat > "$INSTALL_MOUNT/etc/ssh/kirat-banner" << 'EOF'
******************************************************************************
*                            KIRAT OS SERVER                                  *
*       Hardened pre-release; security depends on configuration and testing   *
*                                                                            *
*  Unauthorized access is prohibited. All activity is monitored and logged.  *
******************************************************************************
EOF

    chroot "$INSTALL_MOUNT" systemctl enable ssh || log_warn "enable ssh failed (non-fatal)"
    log_ok "System configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 3B: RBAC TIERED USER MODEL — 1 ROOT + 1 ADMIN + DEVSECOPS + AI AGENTS
# ─────────────────────────────────────────────────────────────────────────────

stage3b_rbac_setup() {
    log_stage "STAGE 3B: RBAC TIERED USER MODEL"

    # Ensure supplementary groups exist — minbase debootstrap omits some
    # (e.g. netdev, audio, video) that useradd -G requires to exist.
    for grp in sudo docker adm systemd-journal audio video netdev; do
        chroot "$INSTALL_MOUNT" groupadd -f "$grp" 2>/dev/null || true
    done

    # ── TIER 0: ROOT — already locked in stage3 ──
    log_ok "Tier 0 (root): Locked, emergency console only"

    # ── TIER 1: KIRAT-ADMIN — Full sudo, human administrator ──
    log_info "Creating Tier 1: kirat-admin..."
    chroot "$INSTALL_MOUNT" useradd -m -s /bin/bash -G sudo,docker,adm,systemd-journal,audio,video,netdev "kirat-admin" 2>/dev/null || true
    # Auto-generate the kirat-admin password and record it IMMEDIATELY on the
    # target system. Previously it was only shown at final completion — an
    # interrupted install stranded the admin (had to break in via init=/bin/bash).
    ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    chroot "$INSTALL_MOUNT" usermod -p "$(openssl passwd -6 "$ADMIN_PASSWORD")" kirat-admin || log_warn "password set failed for kirat-admin (non-fatal)"
    chroot "$INSTALL_MOUNT" passwd -e kirat-admin || log_warn "passwd expiry for kirat-admin failed (non-fatal)"
    cat > "$INSTALL_MOUNT/root/kirat-admin-credentials.txt" << EOF
KIRAT OS — kirat-admin initial credentials
==========================================
Username: kirat-admin
Password: $ADMIN_PASSWORD

This password was auto-generated during installation.
It is expired (passwd -e) and MUST be changed on first login.
Delete this file after the first successful login.
EOF
    chmod 600 "$INSTALL_MOUNT/root/kirat-admin-credentials.txt"
    log_ok "kirat-admin credentials saved to /root/kirat-admin-credentials.txt (mode 600)"

    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-admin" << 'EOF'
# KIRAT OS Tier 1 Administrator; canonical RBAC CLI runs through this sudo access.
kirat-admin ALL=(ALL:ALL) ALL
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-admin"
    log_ok "Tier 1 (kirat-admin): full sudo with canonical RBAC delegation"

    # Canonical RBAC code and keys are installed from security/rbac in stage 8.

    # ── TIER 2: DEVSECOPS TEAM — Command-whitelisted roles ──
    log_info "Creating Tier 2: DevSecOps team..."

    # security-officer: security tools only (NO wildcards)
    chroot "$INSTALL_MOUNT" useradd -m -s /bin/bash -G adm,systemd-journal "security-officer" 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -p "$(openssl passwd -6 "kirat-temp-sec-$(openssl rand -hex 4)")" security-officer || log_warn "password set failed for security-officer (non-fatal)"
    chroot $INSTALL_MOUNT chage -d 0 security-officer
    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-security-officer" << 'EOF'
# Security Officer — read-only and selective control
security-officer ALL=(root) NOPASSWD: /usr/bin/fail2ban-client status, /usr/bin/fail2ban-client get sshd bantime, /usr/sbin/ufw status verbose, /usr/bin/systemctl status apparmor, /usr/bin/systemctl status fail2ban, /usr/bin/systemctl status ssh, /bin/cat /var/log/auth.log, /usr/bin/apparmor_status, /usr/bin/aa-status
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-security-officer"

    # Docker membership and Docker sudo are root-equivalent and are not granted.
    chroot "$INSTALL_MOUNT" useradd -m -s /bin/bash -G adm,systemd-journal "ops-engineer" 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -p "$(openssl passwd -6 "$(openssl rand -hex 24)")" ops-engineer
    chroot "$INSTALL_MOUNT" chage -d 0 ops-engineer
    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-ops-engineer" << 'EOF'
ops-engineer ALL=(root) NOPASSWD: /bin/systemctl status nginx, /bin/systemctl status ssh, /bin/systemctl status docker, /bin/systemctl status postgresql, /usr/sbin/nginx -t, /usr/bin/netstat -tulpn, /usr/sbin/ss -tulpn, /bin/df -h
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-ops-engineer"

    chroot "$INSTALL_MOUNT" useradd -m -s /bin/bash "dev-engineer" 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -p "$(openssl passwd -6 "$(openssl rand -hex 24)")" dev-engineer
    chroot "$INSTALL_MOUNT" chage -d 0 dev-engineer
    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-dev-engineer" << 'EOF'
dev-engineer ALL=(root) NOPASSWD: /usr/bin/git status, /usr/bin/git log, /usr/bin/git diff, /bin/systemctl status nginx, /bin/systemctl status postgresql
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-dev-engineer"
    chroot "$INSTALL_MOUNT" gpasswd -d ops-engineer docker 2>/dev/null || true
    chroot "$INSTALL_MOUNT" gpasswd -d dev-engineer docker 2>/dev/null || true

    # incident-responder: read-only + selective restart (explicit only)
    chroot "$INSTALL_MOUNT" useradd -m -s /bin/bash -G adm,systemd-journal "incident-responder" 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -p "$(openssl passwd -6 "kirat-temp-ir-$(openssl rand -hex 4)")" incident-responder || log_warn "password set failed for incident-responder (non-fatal)"
    chroot $INSTALL_MOUNT chage -d 0 incident-responder
    cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-incident-responder" << 'EOF'
# Incident Responder — logs and selective safe restarts
incident-responder ALL=(root) NOPASSWD: /bin/journalctl -xe, /bin/journalctl -u nginx, /bin/journalctl -u ssh, /bin/journalctl -u fail2ban, /bin/systemctl status nginx, /bin/systemctl status ssh, /bin/systemctl status postgresql, /bin/systemctl restart nginx, /bin/systemctl restart ssh, /bin/systemctl reload nginx, /usr/bin/tail -n 100 /var/log/nginx/error.log, /usr/bin/tail -n 100 /var/log/auth.log, /bin/cat /var/log/nginx/error.log, /bin/cat /var/log/auth.log
EOF
    chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-incident-responder"

    # PrivilegedExecutor callers get only noninteractive canonical-executor sudo.
    rm -f "$INSTALL_MOUNT/etc/sudoers.d/kirat-healer-ai"
    for agent in galinja-ai aadhipati-ai papa-ai suyarma-ai; do
        cat > "$INSTALL_MOUNT/etc/sudoers.d/kirat-$agent" << EOF
# Invoke only as: sudo -n /opt/kirat-os/security/rbac/executor-run.sh <signed-request>
$agent ALL=(root) NOPASSWD: /opt/kirat-os/security/rbac/executor-run.sh
EOF
        chmod 440 "$INSTALL_MOUNT/etc/sudoers.d/kirat-$agent"
    done

    log_ok "Tier 2 (DevSecOps): security-officer, ops-engineer, dev-engineer, incident-responder"

    # ── TIER 3: AI AGENT SERVICE ACCOUNTS — No login, systemd services only ──
    log_info "Creating Tier 3: AI Agent service accounts..."

# Ollama and Dashboard service users (no login)
chroot $INSTALL_MOUNT useradd -r -s /usr/sbin/nologin -M ollama 2>/dev/null || true
chroot $INSTALL_MOUNT useradd -r -s /usr/sbin/nologin -M kirat-dashboard 2>/dev/null || true
# Ollama needs a writable home (service user created with -M = no home)
mkdir -p "$INSTALL_MOUNT/home/ollama"
chroot "$INSTALL_MOUNT" chown ollama:ollama /home/ollama 2>/dev/null || true
    for agent in sentinel-ai quantum-ai executor-ai auditor-ai orchestrator-ai; do
        chroot "$INSTALL_MOUNT" useradd -r -s /usr/sbin/nologin -M "$agent" 2>/dev/null || true
    done

    # Advanced Defense AI Agents (5 autonomous systems + 1 CEO)
    for agent in jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai; do
        chroot "$INSTALL_MOUNT" useradd -r -s /usr/sbin/nologin -M "$agent" 2>/dev/null || true
    done

    # AI Agent groups
    chroot "$INSTALL_MOUNT" groupadd -f ai-agents
    chroot "$INSTALL_MOUNT" usermod -aG ai-agents sentinel-ai 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -aG ai-agents quantum-ai 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -aG ai-agents executor-ai 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -aG ai-agents auditor-ai 2>/dev/null || true
    chroot "$INSTALL_MOUNT" usermod -aG ai-agents orchestrator-ai 2>/dev/null || true

    # Root-owned canonical RBAC state; agents reach the executor only via sudo.
    install -d -m 0700 -o root -g root \
        "$INSTALL_MOUNT/opt/kirat-os/security/rbac/instructions" \
        "$INSTALL_MOUNT/opt/kirat-os/security/rbac/logs" \
        "$INSTALL_MOUNT/opt/kirat-os/security/rbac/executed-ids"
    chroot "$INSTALL_MOUNT" chown -R root:root /opt/kirat-os/security/rbac
    chroot "$INSTALL_MOUNT" chmod 700 /opt/kirat-os/security/rbac \
        /opt/kirat-os/security/rbac/instructions /opt/kirat-os/security/rbac/logs \
        /opt/kirat-os/security/rbac/executed-ids

    # Small administrator CLI: exactly seven canonical fields, canonical signing,
    # then immediate execution through the canonical exact-allowlist executor.
    cat > "$INSTALL_MOUNT/usr/local/bin/kirat-admin" << 'EOF'
#!/bin/bash
set -euo pipefail
umask 077
RBAC=/opt/kirat-os/security/rbac
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo as kirat-admin" >&2; exit 1; }
case "${1:-} ${2:-}" in
    "instruction create")
        shift 2
        COMMAND="$*"
        [ -n "$COMMAND" ] || { echo "Usage: kirat-admin instruction create <command>" >&2; exit 1; }
        ID="inst-$(openssl rand -hex 16)"
        FILE="$RBAC/instructions/$ID.json"
        python3 - "$FILE" "$ID" "$COMMAND" <<'PY'
from datetime import datetime, timedelta, timezone
import json, os, sys
path, instruction_id, command = sys.argv[1:]
now = datetime.now(timezone.utc).replace(microsecond=0)
stamp = lambda value: value.strftime("%Y-%m-%dT%H:%M:%SZ")
instruction = {
    "instruction_id": instruction_id,
    "issuer": "kirat-admin",
    "target": "kirat-ai-executor",
    "command": command,
    "issued_at": stamp(now),
    "expiry": stamp(now + timedelta(minutes=5)),
    "nonce": os.urandom(16).hex(),
}
with open(path, "x", encoding="utf-8") as stream:
    json.dump(instruction, stream, ensure_ascii=False, allow_nan=False)
    stream.write("\n")
os.chmod(path, 0o600)
PY
        python3 "$RBAC/ed25519-sign.py" sign "$FILE"
        exec "$RBAC/executor-run.sh" "$FILE"
        ;;
    "instruction list")
        ls -la "$RBAC/instructions"
        ;;
    *)
        echo "Usage: kirat-admin instruction create <command> | instruction list" >&2
        exit 1
        ;;
esac
EOF
    chmod 755 "$INSTALL_MOUNT/usr/local/bin/kirat-admin"
    chroot "$INSTALL_MOUNT" chown root:root /usr/local/bin/kirat-admin

    log_ok "Tier 3 (AI Agents): sentinel-ai, quantum-ai, executor-ai, auditor-ai, orchestrator-ai"
    log_ok "RBAC setup complete — 1 root + 1 admin + 4 DevSecOps + 5 AI Agents + Ed25519"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 4: KERNEL HARDENING
# ─────────────────────────────────────────────────────────────────────────────

stage4_kernel_harden() {
    log_stage "STAGE 4: KERNEL HARDENING"

    # Kernel parameters
    cat > "$INSTALL_MOUNT/etc/sysctl.d/99-kirat-production.conf" << 'EOF'
# KIRAT OS Production Kernel Parameters

# Memory
vm.swappiness=10
vm.dirty_ratio=15
vm.dirty_background_ratio=5
vm.vfs_cache_pressure=50
vm.overcommit_memory=1
vm.overcommit_ratio=50

# Network performance
net.core.rmem_max=134217728
net.core.wmem_max=134217728
net.ipv4.tcp_rmem=4096 87380 134217728
net.ipv4.tcp_wmem=4096 65536 134217728
net.core.netdev_max_backlog=500000
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_fastopen=3

# Connection tracking
net.netfilter.nf_conntrack_max=2000000

# Security
kernel.randomize_va_space=2
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
kernel.yama.ptrace_scope=1
kernel.unprivileged_bpf_disabled=1
kernel.io_uring_disabled=0

# Disable IPv6 if not needed (reduces attack surface)
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.default.disable_ipv6=0
EOF

    # GRUB hardening
    cat > "$INSTALL_MOUNT/etc/default/grub.d/kirat-harden.cfg" << EOF
# KIRAT OS GRUB Hardening
GRUB_CMDLINE_LINUX_DEFAULT="quiet"
GRUB_CMDLINE_LINUX="slab_nomerge init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1 kasan.stacktrace=1 vsyscall=none debugfs=off oops=panic module.sig_enforce=1 lockdown=confidentiality mce=0 pti=on spectre_v2=on spec_store_bypass_disable=seccomp l1tf=full,force mds=full,nosmt tsx=off kvm.nx_huge_pages=force"
GRUB_DISABLE_RECOVERY="true"
GRUB_TIMEOUT=3
EOF

    if [ "$BOOT_MODE" = "UEFI" ]; then
        log_info "Deploying the distribution-signed shim/GRUB Secure Boot chain..."
        chroot "$INSTALL_MOUNT" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=KIRATOS --removable --uefi-secure-boot \
            || die "Signed UEFI bootloader installation failed"
        [ -s "$INSTALL_MOUNT/boot/efi/EFI/KIRATOS/shimx64.efi" ] \
            || die "Signed shim was not deployed; Secure Boot cannot be claimed"
        log_warn "Secure Boot firmware state and boot success must be verified after reboot; MOK enrollment is not complete"
    else
        chroot "$INSTALL_MOUNT" grub-install --target=i386-pc "$TARGET_DISK" || die "BIOS GRUB installation failed"
    fi

    chroot "$INSTALL_MOUNT" update-grub

    # Update initramfs for LUKS
    chroot "$INSTALL_MOUNT" update-initramfs -u -k all

    log_ok "Kernel hardened and bootloader installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 5: SECURITY STACK
# ─────────────────────────────────────────────────────────────────────────────

stage5_security_stack() {
    log_stage "STAGE 5: SECURITY STACK"

    # Public ingress is limited to SSH, HTTP and HTTPS; backends use loopback.
    chroot "$INSTALL_MOUNT" bash -c '
set -e
ufw default deny incoming
ufw default allow outgoing
ufw --force reset
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
'
    chroot "$INSTALL_MOUNT" systemctl enable ufw || log_warn "enable ufw failed (non-fatal)"
    log_ok "Firewall configured"

    # Fail2ban
    cat > "$INSTALL_MOUNT/etc/fail2ban/jail.local" << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
backend = systemd
maxretry = 3

[nginx-http-auth]
enabled = true
filter = nginx-http-auth
port = http,https
logpath = /var/log/nginx/error.log
EOF
    chroot "$INSTALL_MOUNT" systemctl enable fail2ban || log_warn "enable fail2ban failed (non-fatal)"
    log_ok "Fail2ban configured"

    # AppArmor profiles
    chroot "$INSTALL_MOUNT" apt-get install -y -qq apparmor apparmor-profiles apparmor-utils
    chroot "$INSTALL_MOUNT" systemctl enable apparmor || log_warn "enable apparmor failed (non-fatal)"
    log_ok "AppArmor enabled"

    # Secure Boot + MOK
    if [ "$BOOT_MODE" = "UEFI" ]; then
        log_info "Setting up Secure Boot MOK..."
        mkdir -p "$INSTALL_MOUNT/opt/kirat-os/security/mok"
        openssl req -new -x509 -newkey rsa:4096 \
            -keyout "$INSTALL_MOUNT/opt/kirat-os/security/mok/MOK.priv" \
            -outform DER -out "$INSTALL_MOUNT/opt/kirat-os/security/mok/MOK.der" \
            -days 3650 -nodes -subj "/CN=KIRAT OS Business MOK/"
        chmod 600 "$INSTALL_MOUNT/opt/kirat-os/security/mok/MOK.priv"
        chroot "$INSTALL_MOUNT" chown root:root /opt/kirat-os/security/mok/MOK.priv
        log_ok "MOK keys generated"
        log_warn "AIR-GAPPED SIGNING RECOMMENDED: For nation-state resistance, sign kernel modules on an air-gapped machine."
        log_warn "Transfer MOK.priv to air-gapped signer, keep only MOK.der on this server."
        cat > "$INSTALL_MOUNT/opt/kirat-os/security/mok/README.airgap" << 'EOF'
# KIRAT OS — Air-Gapped MOK Signing Procedure
#
# For maximum security against supply-chain and nation-state attacks:
#
# 1. Generate MOK keys on an air-gapped machine (never connected to network)
# 2. Transfer ONLY MOK.der (public) to this server
# 3. Keep MOK.priv (private) on the air-gapped signer
# 4. When compiling out-of-tree kernel modules:
#    a. Build on this server
#    b. Transfer unsigned .ko to air-gapped signer
#    c. Sign with: sbsign --key MOK.priv --cert MOK.der module.ko
#    d. Transfer signed .ko back to this server
# 5. Enroll MOK.der with: mokutil --import /opt/kirat-os/security/mok/MOK.der
#
# This prevents an attacker who compromises this server from forging
# kernel module signatures.
EOF
        chmod 644 "$INSTALL_MOUNT/opt/kirat-os/security/mok/README.airgap"
    fi

    # TPM 2.0 auto-unlock for LUKS (if available)
    if [ "$HAS_TPM2" = "1" ]; then
        log_info "Configuring TPM 2.0 LUKS auto-unlock..."
        chroot "$INSTALL_MOUNT" apt-get install -y -qq clevis clevis-luks clevis-tpm2 clevis-dracut
        # This would be configured post-boot with the actual TPM
        log_ok "TPM 2.0 tools installed (configure after first boot)"
    fi


    # TLS with PQC — 90-day self-signed FALLBACK + Let's Encrypt auto-cert
    mkdir -p "$INSTALL_MOUNT/etc/nginx/ssl"
    # Generate 90-day self-signed cert with SAN (fallback until Let's Encrypt succeeds)
    cat > "$INSTALL_MOUNT/tmp/kirat-san.cnf" << CNFTXT
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
    chroot "$INSTALL_MOUNT" openssl req -x509 -nodes -days 90 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout /etc/nginx/ssl/kirat-key.pem -out /etc/nginx/ssl/kirat-cert.pem \
        -config /tmp/kirat-san.cnf
    rm -f "$INSTALL_MOUNT/tmp/kirat-san.cnf"
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
    chroot "$INSTALL_MOUNT" systemctl enable certbot-renew.timer || log_warn "enable certbot-renew.timer failed (non-fatal)"
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
ExecStart=/bin/bash -c 'if [ "$DOMAIN" != "localhost" ]; then certbot --nginx -d $DOMAIN -d *.$DOMAIN --agree-tos --non-interactive --email $BUSINESS_EMAIL; else echo "Domain is localhost — skipping Let\'s Encrypt"; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    log_ok "First-boot Let's Encrypt service created (skips if DOMAIN=localhost)"

    log_ok "Security configuration written; runtime enforcement requires post-boot tests"

}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 5B: INTRUSION DETECTION + AUTO-PATCH + AUDIT TOOLS
# ─────────────────────────────────────────────────────────────────────────────

stage5b_ids_and_audit() {
    log_stage "STAGE 5B: IDS, AUTO-PATCHING, AND AUDIT TOOLS"

    # AIDE — filesystem integrity monitor
    log_info "Installing AIDE (Advanced Intrusion Detection Environment)..."
    chroot "$INSTALL_MOUNT" apt-get install -y -qq aide aide-common
    chroot "$INSTALL_MOUNT" aideinit 2>/dev/null || true
    # Daily AIDE check via cron
    cat > "$INSTALL_MOUNT/etc/cron.daily/aide-check" << 'EOF'
#!/bin/bash
# KIRAT OS — Daily AIDE integrity check
/usr/bin/aide --check > /var/log/aide/check-$(date +%Y%m%d).log 2>&1 || {
    echo "KIRAT OS ALERT: AIDE detected filesystem changes" | wall
    logger -p auth.warning "AIDE filesystem integrity check FAILED"
}
EOF
    chmod 755 "$INSTALL_MOUNT/etc/cron.daily/aide-check"
    log_ok "AIDE installed and configured for daily checks"

    # Unattended-upgrades — automatic CVE patching
    log_info "Configuring automatic security updates..."
    chroot "$INSTALL_MOUNT" apt-get install -y -qq unattended-upgrades apt-listchanges
    cat > "$INSTALL_MOUNT/etc/apt/apt.conf.d/50unattended-upgrades" << 'EOF'
// KIRAT OS — Automatic Security Patching
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
Unattended-Upgrade::OnlyOnACPower "false";
// Email notifications (configure after install)
// Unattended-Upgrade::Mail "admin@localhost";
// Unattended-Upgrade::MailReport "on-change";
EOF
    cat > "$INSTALL_MOUNT/etc/apt/apt.conf.d/20auto-upgrades" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    log_ok "Automatic security patching enabled (daily)"

    # Lynis — security auditing tool
    log_info "Installing Lynis security auditor..."
    chroot "$INSTALL_MOUNT" apt-get install -y -qq lynis
    mkdir -p "$INSTALL_MOUNT/var/log/lynis"
    cat > "$INSTALL_MOUNT/etc/cron.weekly/lynis-audit" << 'EOF'
#!/bin/bash
# KIRAT OS — Weekly security audit
/usr/sbin/lynis audit system --quick --no-colors > /var/log/lynis/weekly-$(date +%Y%m%d).log 2>&1
EOF
    chmod 755 "$INSTALL_MOUNT/etc/cron.weekly/lynis-audit"
    log_ok "Lynis installed and configured for weekly audits"

    # rkhunter — rootkit hunter
    log_info "Installing rkhunter..."
    chroot "$INSTALL_MOUNT" apt-get install -y -qq rkhunter
    chroot "$INSTALL_MOUNT" rkhunter --propupd 2>/dev/null || true
    cat > "$INSTALL_MOUNT/etc/cron.daily/rkhunter-check" << 'EOF'
#!/bin/bash
# KIRAT OS — Daily rootkit scan
/usr/bin/rkhunter --check --sk --nocolors > /var/log/rkhunter/daily-$(date +%Y%m%d).log 2>&1 || true
EOF
    chmod 755 "$INSTALL_MOUNT/etc/cron.daily/rkhunter-check"
    log_ok "rkhunter installed and configured for daily rootkit scans"

    # Auditd — kernel-level audit framework
    log_info "Installing auditd..."
    chroot "$INSTALL_MOUNT" apt-get install -y -qq auditd audispd-plugins
    cat > "$INSTALL_MOUNT/etc/audit/rules.d/kirat-os.rules" << 'EOF'
# KIRAT OS — Kernel Audit Rules
# Monitor sudoers changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_changes
# Monitor passwd/shadow
-w /etc/passwd -p wa -k identity_changes
-w /etc/shadow -p wa -k identity_changes
-w /etc/group -p wa -k identity_changes
# Monitor SSH config
-w /etc/ssh/sshd_config -p wa -k ssh_config_changes
# Monitor AI agent instructions
-w /opt/kirat-os/security/rbac/instructions/ -p wa -k ai_instructions
# Monitor executor audit log
-w /opt/kirat-os/security/rbac/logs/ -p wa -k audit_logs
# Monitor MOK keys
-w /opt/kirat-os/security/mok/ -p wa -k mok_keys
EOF
    chroot "$INSTALL_MOUNT" systemctl enable auditd || log_warn "enable auditd failed (non-fatal)"
    log_ok "auditd installed with KIRAT OS custom rules"

    # Log aggregation directory
    mkdir -p "$INSTALL_MOUNT/var/log/kirat-os"
    log_ok "IDS, update, and audit configuration installed; runtime checks remain pending"
}

# ─────────────────────────────────────────────────────────────────────────────

stage6_business_stack() {
    log_stage "STAGE 6: BUSINESS SERVER STACK"

    # Random database credential and a non-superuser application role.
    DB_PASSWORD=$(openssl rand -hex 32)
    chroot "$INSTALL_MOUNT" groupadd -f kirat-db
    chroot "$INSTALL_MOUNT" usermod -aG kirat-db sentinel-ai
    chroot "$INSTALL_MOUNT" usermod -aG kirat-db kirat-dashboard
    install -d -m 0750 -o root -g root "$INSTALL_MOUNT/etc/kirat-os"
    chroot "$INSTALL_MOUNT" chown root:kirat-db /etc/kirat-os
    install -m 0640 -o root -g root /dev/null "$INSTALL_MOUNT/etc/kirat-os/postgresql.env"
    chroot "$INSTALL_MOUNT" chown root:kirat-db /etc/kirat-os/postgresql.env
    printf 'DATABASE_URL=postgresql://kirat_app:%s@127.0.0.1:5432/kirat_business\n' "$DB_PASSWORD" > "$INSTALL_MOUNT/etc/kirat-os/postgresql.env"
    chroot "$INSTALL_MOUNT" bash -c 'for d in /etc/postgresql/*/main/conf.d; do [ ! -d "$d" ] || printf "listen_addresses = \x27127.0.0.1\x27\n" > "$d/kirat-loopback.conf"; done'
    chroot "$INSTALL_MOUNT" env DB_PASSWORD="$DB_PASSWORD" bash -c '
set -euo pipefail
service postgresql start
trap "service postgresql stop >/dev/null 2>&1 || true" EXIT
runuser -u postgres -- psql -v ON_ERROR_STOP=1 --set=dbpass="$DB_PASSWORD" <<"SQL"
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '"'"'kirat_app'"'"') THEN
    CREATE ROLE kirat_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
END $$;
ALTER ROLE kirat_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT PASSWORD :'"'"'dbpass'"'"';
SQL
if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname = '"'"'kirat_business'"'"'" | grep -q 1; then
    runuser -u postgres -- createdb -O kirat_app kirat_business
fi
runuser -u postgres -- psql -d kirat_business -v ON_ERROR_STOP=1 -c "REVOKE ALL ON SCHEMA public FROM PUBLIC; GRANT USAGE, CREATE ON SCHEMA public TO kirat_app;"
'
    unset DB_PASSWORD
    chroot "$INSTALL_MOUNT" systemctl enable postgresql
    log_ok "PostgreSQL application role and random credential configured"

    cat > "$INSTALL_MOUNT/etc/redis/kirat-loopback.conf" << 'EOF'
bind 127.0.0.1 ::1
protected-mode yes
EOF
    grep -q '^include /etc/redis/kirat-loopback.conf' "$INSTALL_MOUNT/etc/redis/redis.conf" \
        || echo 'include /etc/redis/kirat-loopback.conf' >> "$INSTALL_MOUNT/etc/redis/redis.conf"
    chroot "$INSTALL_MOUNT" systemctl enable redis-server docker

    cat > "$INSTALL_MOUNT/etc/nginx/sites-available/kirat-business" << EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN *.$DOMAIN;
    ssl_certificate /etc/nginx/ssl/kirat-cert.pem;
    ssl_certificate_key /etc/nginx/ssl/kirat-key.pem;
    ssl_protocols TLSv1.3;
    ssl_prefer_server_ciphers off;
    # Classical TLS only: hybrid PQC requires a separately validated OQS stack.
    ssl_ecdh_curve X25519:prime256v1:secp384r1;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
    location = /ws/metrics {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    # No unauthenticated Sentinel or Quantum public route is installed.
}
server {
    listen 80;
    listen [::]:80;
    server_name _;
    return 301 https://\$host\$request_uri;
}
EOF
    chroot "$INSTALL_MOUNT" ln -sf /etc/nginx/sites-available/kirat-business /etc/nginx/sites-enabled/
    chroot "$INSTALL_MOUNT" rm -f /etc/nginx/sites-enabled/default
    chroot "$INSTALL_MOUNT" nginx -t
    chroot "$INSTALL_MOUNT" systemctl enable nginx

    mkdir -p "$INSTALL_MOUNT/data/www" "$INSTALL_MOUNT/data/backups" "$INSTALL_MOUNT/data/postgres" \
        "$INSTALL_MOUNT/data/redis" "$INSTALL_MOUNT/data/business"
    T_UID=$(chroot "$INSTALL_MOUNT" id -u "$USERNAME")
    T_GID=$(chroot "$INSTALL_MOUNT" id -g "$USERNAME")
    chown -R "$T_UID:$T_GID" "$INSTALL_MOUNT/data/business"
    log_ok "Business stack configured; runtime health remains unverified until boot"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 7: OLLAMA + REAL AI BACKENDS
# ─────────────────────────────────────────────────────────────────────────────

stage7_ai_backends() {
    log_stage "STAGE 7: AI BACKENDS (VERIFIED OLLAMA $OLLAMA_VERSION)"

    cat > "$INSTALL_MOUNT/usr/local/sbin/kirat-ollama-install" << EOF
#!/bin/bash
set -euo pipefail
umask 077
[ -x /usr/local/bin/ollama ] && exit 0
[ -f /etc/kirat-os/ollama-install.env ] && . /etc/kirat-os/ollama-install.env
VERSION="$OLLAMA_VERSION"
ASSET="ollama-linux-amd64.tar.zst"
URL="https://github.com/ollama/ollama/releases/download/v\${VERSION}/\${ASSET}"
ARCHIVE="/tmp/\${ASSET}"
EXPECTED="\${OLLAMA_SHA256:-7bedab90dd122661be78798e9f0edf37fccf0cccf2699d2c58ea1a3afdc04b6d}"
[[ "\$EXPECTED" =~ ^[0-9a-fA-F]{64}\$ ]] || { echo "A 64-character SHA256 digest is required; set OLLAMA_SHA256 for a deliberately reviewed update" >&2; exit 1; }
curl -fsSL --retry 3 -o "\$ARCHIVE" "\$URL"
printf '%s  %s\n' "\$EXPECTED" "\$ARCHIVE" | sha256sum -c -
WORK=\$(mktemp -d /tmp/ollama-extract.XXXXXXXX)
trap 'rm -rf "\$WORK" /tmp/ollama-linux-amd64.tar.zst' EXIT
tar -xf "\$ARCHIVE" -C "\$WORK"
[ -f "\$WORK/bin/ollama" ] || [ -f "\$WORK/ollama" ] || { echo "Ollama binary missing from verified archive" >&2; exit 1; }
cp -a "\$WORK/." /usr/local/
[ -x /usr/local/bin/ollama ] || install -m 0755 "\$WORK/ollama" /usr/local/bin/ollama
/usr/local/bin/ollama --version | grep -F "\$VERSION"
EOF
    chmod 755 "$INSTALL_MOUNT/usr/local/sbin/kirat-ollama-install"
    if [ -n "${OLLAMA_SHA256:-}" ]; then
        [[ "$OLLAMA_SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || die "OLLAMA_SHA256 must be a SHA256 hex digest"
        install -m 0600 -o root -g root /dev/null "$INSTALL_MOUNT/etc/kirat-os/ollama-install.env"
        printf 'OLLAMA_SHA256=%s\n' "$OLLAMA_SHA256" > "$INSTALL_MOUNT/etc/kirat-os/ollama-install.env"
    fi
    chroot "$INSTALL_MOUNT" /usr/local/sbin/kirat-ollama-install || die "Verified Ollama installation failed"
    [ -x "$INSTALL_MOUNT/usr/local/bin/ollama" ] || die "Ollama binary missing after verified install"

    cat > "$INSTALL_MOUNT/etc/systemd/system/ollama.service" << 'EOF'
[Unit]
Description=Ollama AI Server (loopback only)
After=network-online.target ollama-install.service
Requires=ollama-install.service

[Service]
Type=simple
User=ollama
Group=ollama
WorkingDirectory=/data/business
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_MODELS=/data/business/models"
ExecStartPre=+/usr/bin/install -d -o ollama -g ollama /data/business/models
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    cat > "$INSTALL_MOUNT/etc/systemd/system/ollama-install.service" << 'EOF'
[Unit]
Description=Verified pinned Ollama first-boot fallback
Before=ollama.service
ConditionPathExists=!/usr/local/bin/ollama

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kirat-ollama-install
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_MOUNT" systemctl enable ollama ollama-install

    # Model downloads are opt-in: create this flag and start the unit explicitly.
    cat > "$INSTALL_MOUNT/etc/systemd/system/ollama-pull.service" << 'EOF'
[Unit]
Description=Opt-in Ollama model download
After=ollama.service
Requires=ollama.service
ConditionPathExists=/etc/kirat-os/ollama-pull-models.enabled

[Service]
Type=oneshot
User=ollama
Environment="OLLAMA_HOST=127.0.0.1:11434"
ExecStart=/usr/local/bin/ollama pull gemma4
ExecStart=/usr/local/bin/ollama pull qwen3.6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    rm -f "$INSTALL_MOUNT/etc/kirat-os/ollama-pull-models.enabled"

    AI_PY_PKGS="fastapi uvicorn httpx websockets psutil numpy pynacl pycryptodome jinja2 python-multipart aiofiles python-dotenv slowapi redis python-socketio pydantic"
    chroot "$INSTALL_MOUNT" pip3 install --break-system-packages $AI_PY_PKGS || die "Required Python dependencies failed"
    chroot "$INSTALL_MOUNT" pip3 install --break-system-packages torch --index-url https://download.pytorch.org/whl/cpu \
        || die "Required CPU torch installation failed"
    chroot "$INSTALL_MOUNT" pip3 install --break-system-packages openai-whisper \
        || log_warn "Optional openai-whisper was not installed"
    if [ "$ENABLE_QUANTUM" = true ]; then
        chroot "$INSTALL_MOUNT" pip3 install --break-system-packages qiskit qiskit-ibm-runtime cirq \
            || die "Quantum was enabled but its dependencies failed"
    else
        log_warn "Quantum disabled; no Quantum route, credentials, or runtime is provisioned"
    fi
    log_ok "AI backend files configured; no model was downloaded automatically"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 8: INSTALL KIRAT OS COMPONENTS
# ─────────────────────────────────────────────────────────────────────────────

stage8_kirat_components() {
    log_stage "STAGE 8: KIRAT OS COMPONENTS"

    mkdir -p "$INSTALL_MOUNT/opt/kirat-os"

    # Copy current project files. Components may live beside the installer
    # (dev checkout: ../<component>) or in the ISO live environment at
    # /opt/kirat-os/<component> — support BOTH. v2.0.6 rehearsal bug: only the
    # dev path was checked, so on ISO installs the code was never copied and
    # sentinel/dashboard services failed with 200/CHDIR.
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -d "$SCRIPT_DIR/../sentinel-core" ]; then
        COMPONENT_ROOT="$SCRIPT_DIR/.."
    elif [ -d /opt/kirat-os/sentinel-core ]; then
        COMPONENT_ROOT="/opt/kirat-os"
    else
        COMPONENT_ROOT="$SCRIPT_DIR/.."
    fi

    [ -d "$COMPONENT_ROOT/sentinel-core" ] || die "Required sentinel-core source is missing"
    cp -r "$COMPONENT_ROOT/sentinel-core" "$INSTALL_MOUNT/opt/kirat-os/"
    [ -d "$COMPONENT_ROOT/dashboard" ] || die "Required dashboard source is missing"
    cp -r "$COMPONENT_ROOT/dashboard" "$INSTALL_MOUNT/opt/kirat-os/"
    [ -f "$COMPONENT_ROOT/security/rbac/ed25519-sign.py" ] || die "Canonical RBAC signer is missing"
    [ -f "$COMPONENT_ROOT/security/rbac/executor-run.sh" ] || die "Canonical RBAC executor is missing"
    cp -r "$COMPONENT_ROOT/security" "$INSTALL_MOUNT/opt/kirat-os/"
    chroot "$INSTALL_MOUNT" chown -R root:root /opt/kirat-os/security/rbac
    chroot "$INSTALL_MOUNT" chmod 755 /opt/kirat-os/security/rbac/ed25519-sign.py \
        /opt/kirat-os/security/rbac/executor-run.sh
    chroot "$INSTALL_MOUNT" python3 /opt/kirat-os/security/rbac/ed25519-sign.py genkey \
        || die "Canonical Ed25519 key generation failed"
    chroot "$INSTALL_MOUNT" chown root:root /opt/kirat-os/security/rbac/.admin-ed25519-secret \
        /opt/kirat-os/security/rbac/admin-ed25519.pub
    chroot "$INSTALL_MOUNT" chmod 600 /opt/kirat-os/security/rbac/.admin-ed25519-secret
    chroot "$INSTALL_MOUNT" chmod 644 /opt/kirat-os/security/rbac/admin-ed25519.pub
    chroot "$INSTALL_MOUNT" chmod 700 /opt/kirat-os/security/rbac \
        /opt/kirat-os/security/rbac/instructions /opt/kirat-os/security/rbac/logs \
        /opt/kirat-os/security/rbac/executed-ids
    [ "$(wc -c < "$INSTALL_MOUNT/opt/kirat-os/security/rbac/.admin-ed25519-secret")" -eq 32 ] \
        || die "Canonical private key is not a raw 32-byte Ed25519 seed"
    [ "$(wc -c < "$INSTALL_MOUNT/opt/kirat-os/security/rbac/admin-ed25519.pub")" -eq 32 ] \
        || die "Canonical public key is not a raw 32-byte Ed25519 key"
    [ -d "$COMPONENT_ROOT/ai-agents" ] || die "Required ai-agents source is missing"
    cp -r "$COMPONENT_ROOT/ai-agents" "$INSTALL_MOUNT/opt/kirat-os/"

    # Runtime directories required by agent sandboxing (ReadWritePaths) and SQLite state.
    # Signed requests are read-only to agents; backup artifacts are root-only.
    mkdir -p "$INSTALL_MOUNT/var/lib/kirat-os/executor-requests" \
             "$INSTALL_MOUNT/var/cache/kirat-os" \
             "$INSTALL_MOUNT/var/log/kirat" \
             "$INSTALL_MOUNT/data/business" \
             "$INSTALL_MOUNT/data/backups" \
             "$INSTALL_MOUNT/data/forensics"
    chroot "$INSTALL_MOUNT" chown -R root:ai-agents \
        /var/lib/kirat-os /var/cache/kirat-os /var/log/kirat \
        /data/business /data/forensics
    chroot "$INSTALL_MOUNT" chmod 2775 \
        /var/lib/kirat-os /var/cache/kirat-os /var/log/kirat \
        /data/business /data/forensics
    chroot "$INSTALL_MOUNT" chown root:ai-agents /var/lib/kirat-os/executor-requests
    chroot "$INSTALL_MOUNT" chmod 0750 /var/lib/kirat-os/executor-requests
    chroot "$INSTALL_MOUNT" chown root:root /data/backups
    chroot "$INSTALL_MOUNT" chmod 0700 /data/backups

    mkdir -p "$INSTALL_MOUNT/opt/kirat-os/scripts"
    for script in first-boot-wizard.sh backup-dr.sh; do
        [ -f "$SCRIPT_DIR/../scripts/$script" ] || die "Required installed script missing: $script"
        install -m 0755 "$SCRIPT_DIR/../scripts/$script" "$INSTALL_MOUNT/opt/kirat-os/scripts/$script"
    done
    for script in post-install-mok.sh post-install-tpm.sh verify-security.sh final-100-hardening.sh; do
        [ ! -f "$SCRIPT_DIR/../scripts/$script" ] || install -m 0755 "$SCRIPT_DIR/../scripts/$script" "$INSTALL_MOUNT/opt/kirat-os/scripts/$script"
    done

    # Independent high-entropy API secrets, readable only by their service group.
    SENTINEL_API_KEY=$(openssl rand -hex 32)
    DASHBOARD_API_KEY=$(openssl rand -hex 32)
    [ "$SENTINEL_API_KEY" != "$DASHBOARD_API_KEY" ] || die "API key generation collision"
    install -m 0640 -o root -g root /dev/null "$INSTALL_MOUNT/etc/kirat-os/sentinel.env"
    install -m 0640 -o root -g root /dev/null "$INSTALL_MOUNT/etc/kirat-os/dashboard.env"
    chroot "$INSTALL_MOUNT" chown root:sentinel-ai /etc/kirat-os/sentinel.env
    chroot "$INSTALL_MOUNT" chown root:kirat-dashboard /etc/kirat-os/dashboard.env
    printf 'SENTINEL_API_KEY=%s\n' "$SENTINEL_API_KEY" > "$INSTALL_MOUNT/etc/kirat-os/sentinel.env"
    printf 'DASHBOARD_API_KEY=%s\n' "$DASHBOARD_API_KEY" > "$INSTALL_MOUNT/etc/kirat-os/dashboard.env"
    unset SENTINEL_API_KEY DASHBOARD_API_KEY
    rm -f "$INSTALL_MOUNT/etc/kirat-os/quantum.env"

    # Create Sentinel service using the loopback backend.
    cat > "$INSTALL_MOUNT/etc/systemd/system/sentinel.service" << 'EOF'
[Unit]
Description=Sentinel AI Core
After=ollama.service network-online.target
Wants=ollama.service

[Service]
Type=simple
User=sentinel-ai
Group=sentinel-ai
WorkingDirectory=/opt/kirat-os/sentinel-core
EnvironmentFile=/etc/kirat-os/sentinel.env
Environment="OLLAMA_HOST=http://127.0.0.1:11434"
Environment="SENTINEL_HOST=127.0.0.1"
Environment="SENTINEL_MODEL=gemma4:latest"
Environment="SENTINEL_PORT=3000"
Environment="PYTHONPATH=/opt/kirat-os"
ExecStart=/usr/bin/python3 /opt/kirat-os/sentinel-core/main-real.py
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
StartLimitInterval=60
StartLimitBurst=3
LimitNOFILE=65536
MemoryMax=4G
CPUQuota=300%
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/kirat-os /data/business

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_MOUNT" systemctl enable sentinel
    AGENTS_ENABLED=0
    for agent in jitedasti-ai galinja-ai oysgja-ai suyarma-ai papa-ai aadhipati-ai; do
        [ -f "$INSTALL_MOUNT/opt/kirat-os/ai-agents/$agent/$agent.service" ] || die "Required agent service missing: $agent"
        cp "$INSTALL_MOUNT/opt/kirat-os/ai-agents/$agent/$agent.service" "$INSTALL_MOUNT/etc/systemd/system/"
        chroot "$INSTALL_MOUNT" systemctl enable "$agent"
        AGENTS_ENABLED=$((AGENTS_ENABLED+1))
    done
    log_ok "AI agent units enabled: $AGENTS_ENABLED/6; runtime health not yet measured"

    cat > "$INSTALL_MOUNT/etc/systemd/system/kirat-dashboard.service" << 'EOF'
[Unit]
Description=KIRAT OS Dashboard
After=sentinel.service

[Service]
Type=simple
User=kirat-dashboard
Group=kirat-dashboard
WorkingDirectory=/opt/kirat-os/dashboard
EnvironmentFile=/etc/kirat-os/dashboard.env
Environment="PYTHONPATH=/opt/kirat-os"
Environment="SENTINEL_URL=http://127.0.0.1:3000"
ExecStart=/usr/bin/python3 -m uvicorn main:app --host 127.0.0.1 --port 8080
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    chroot "$INSTALL_MOUNT" systemctl enable kirat-dashboard
    cat > "$INSTALL_MOUNT/opt/kirat-os/security/BACKUP-GPG.txt" << 'EOF'
Backups are disabled until a GPG recipient is configured.
1. Import or generate an encryption-capable GPG public key in root's keyring.
2. Export BACKUP_GPG_RECIPIENT to that key's fingerprint or email.
3. Run: sudo BACKUP_GPG_RECIPIENT=<fingerprint> /opt/kirat-os/scripts/backup-dr.sh --action backup
4. Verify recovery with --action dr-test; keep the private key off this server.
No backup passphrase is generated and no successful backup is assumed.
EOF
    log_warn "Backup requires explicit BACKUP_GPG_RECIPIENT setup and a successful DR test"

    log_ok "KIRAT OS components configured"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 9: FIRST-BOOT SETUP
# ─────────────────────────────────────────────────────────────────────────────

stage9_first_boot() {
    log_stage "STAGE 9: FIRST-BOOT CONFIGURATION"
    [ -x "$INSTALL_MOUNT/opt/kirat-os/scripts/first-boot-wizard.sh" ] || die "First-boot wizard was not installed"
    cat > "$INSTALL_MOUNT/usr/local/bin/kirat-first-boot" << 'SCRIPT'
#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo from kirat-admin" >&2; exit 1; }
exec /opt/kirat-os/scripts/first-boot-wizard.sh
SCRIPT
    chmod 0755 "$INSTALL_MOUNT/usr/local/bin/kirat-first-boot"
    cat > "$INSTALL_MOUNT/etc/profile.d/kirat-first-boot-reminder.sh" << 'EOF'
# Remind only the intended administrator, never the locked root account.
if [ "$(id -un)" = "kirat-admin" ] && [ "$(id -u)" -ne 0 ] && [ ! -f /var/lib/kirat-first-boot-done ]; then
    echo "KIRAT OS: run 'sudo kirat-first-boot' to enroll your SSH public key and finish setup."
fi
EOF
    log_ok "First-boot wizard installed; run as kirat-admin with sudo"
}

# ─────────────────────────────────────────────────────────────────────────────
# STAGE 10: FINALIZE AND VERIFY
# ─────────────────────────────────────────────────────────────────────────────

stage10_finalize() {
    log_stage "STAGE 10: STATIC FINAL VERIFICATION"
    local required service mode
    local required_files=(
        /opt/kirat-os/sentinel-core/main-real.py
        /opt/kirat-os/dashboard/main.py
        /opt/kirat-os/scripts/first-boot-wizard.sh
        /opt/kirat-os/scripts/backup-dr.sh
        /opt/kirat-os/security/rbac/ed25519-sign.py
        /opt/kirat-os/security/rbac/executor-run.sh
        /opt/kirat-os/security/rbac/.admin-ed25519-secret
        /opt/kirat-os/security/rbac/admin-ed25519.pub
        /usr/local/bin/ollama
        /etc/kirat-os/sentinel.env
        /etc/kirat-os/dashboard.env
        /etc/kirat-os/postgresql.env
        /etc/nginx/sites-available/kirat-business
        /etc/ssh/sshd_config.d/kirat-production.conf
    )
    for required in "${required_files[@]}"; do
        [ -s "$INSTALL_MOUNT$required" ] || die "Final verification: required file missing or empty: $required"
    done
    for service in ssh nginx postgresql redis-server docker ollama ollama-install sentinel kirat-dashboard ufw fail2ban apparmor; do
        chroot "$INSTALL_MOUNT" systemctl is-enabled "$service" >/dev/null 2>&1 \
            || die "Final verification: required service is not enabled: $service"
    done
    chroot "$INSTALL_MOUNT" nginx -t || die "Final verification: nginx configuration is invalid"
    chroot "$INSTALL_MOUNT" sshd -t || die "Final verification: sshd configuration is invalid"
    mode=$(chroot "$INSTALL_MOUNT" stat -c '%a:%U:%G' /opt/kirat-os/security/rbac/.admin-ed25519-secret)
    [ "$mode" = "600:root:root" ] || die "Final verification: unsafe RBAC private-key permissions: $mode"
    [ -z "$(chroot "$INSTALL_MOUNT" find /opt/kirat-os/security/rbac ! -user root -print -quit)" ] \
        || die "Final verification: RBAC code or state is not root-owned"
    for required in instructions logs executed-ids; do
        [ "$(chroot "$INSTALL_MOUNT" stat -c '%a:%U:%G' "/opt/kirat-os/security/rbac/$required")" = "700:root:root" ] \
            || die "Final verification: unsafe RBAC state permissions: $required"
    done
    mode=$(chroot "$INSTALL_MOUNT" stat -c '%a:%U:%G' /etc/kirat-os/sentinel.env)
    [ "$mode" = "640:root:sentinel-ai" ] || die "Final verification: unsafe Sentinel secret permissions: $mode"
    mode=$(chroot "$INSTALL_MOUNT" stat -c '%a:%U:%G' /etc/kirat-os/dashboard.env)
    [ "$mode" = "640:root:kirat-dashboard" ] || die "Final verification: unsafe Dashboard secret permissions: $mode"
    if chroot "$INSTALL_MOUNT" grep -R -E '(SENTINEL_API_KEY|DASHBOARD_API_KEY)=(changeme|change-me|default|secret|password)$' /etc/kirat-os >/dev/null 2>&1; then
        die "Final verification: default API secret detected"
    fi
    [ "$(chroot "$INSTALL_MOUNT" stat -c '%a' /etc/kirat-os/postgresql.env)" = "640" ] \
        || die "Final verification: unsafe database credential permissions"
    [ "$(chroot "$INSTALL_MOUNT" stat -c '%a:%U:%G' /var/lib/kirat-os/executor-requests)" = "750:root:ai-agents" ] \
        || die "Final verification: signed-request directory must be read-only to agents"
    [ "$(chroot "$INSTALL_MOUNT" stat -c '%a:%U:%G' /data/backups)" = "700:root:root" ] \
        || die "Final verification: backup directory must be root-only"
    mountpoint -q "$INSTALL_MOUNT" && mountpoint -q "$INSTALL_MOUNT/boot" && mountpoint -q "$INSTALL_MOUNT/data" \
        || die "Final verification: required mounts disappeared"
    log_ok "Required files, configurations, enabled units, and secret permissions verified"

    echo ""
    echo "KIRAT OS $KIRAT_VERSION files and static configuration verified."
    echo "Disk: $TARGET_DISK; hostname: $HOSTNAME; domain: $DOMAIN; boot: $BOOT_MODE"
    echo "Measured limitations:"
    echo "  - Services are enabled, but runtime health is NOT measured until reboot."
    echo "  - TLS is classical; no hybrid PQC TLS is configured."
    echo "  - SSH includes a hybrid KEX preference; interoperability needs testing."
    echo "  - Signed shim/GRUB files were checked, not Secure Boot activation or MOK enrollment."
    echo "  - TPM auto-unlock is not configured; passphrases are required at boot."
    echo "  - Native Quantum service integration is disabled and unsupported in this pre-release."
    echo "  - No AI models were pulled automatically; backups require GPG recipient setup and DR testing."
    echo "Next: reboot, run sudo kirat-first-boot as kirat-admin, then test SSH, HTTPS, APIs, services, and recovery."
}

unmount_and_close_target() {
    sync
    umount -R "$INSTALL_MOUNT" || die "Could not unmount target cleanly; do not reboot until resolved"
    cryptsetup close kirat-data || die "Could not close kirat-data"
    cryptsetup close kirat-root || die "Could not close kirat-root"
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────

show_banner() {
    echo ""
    echo "  _  ___ _ _ ___ _ _ ___ _  _"
    echo "  | |/ / | | | _ ) | | __| \| |"
    echo "  | ' <| |_| | _ \_  _| _ | .\` |"
    echo "  |_|\_\\___/|___/ |_| |___|_|\_|"
    echo ""
    echo "  KIRAT OS — Native Business Installation"
    echo "  Version $KIRAT_VERSION"
    echo ""
}

show_help() {
    cat << 'EOF'
Usage: sudo bash install-native.sh [OPTIONS]

REQUIRED:
  --disk DEVICE       Target disk to DESTROY (e.g., /dev/nvme0n1, /dev/sda)

OPTIONS:
  --hostname NAME     Server hostname (default: kirat-os-business)
  --username NAME     Admin username (default: kirat-admin)
  --timezone ZONE     Timezone (default: UTC)
  --domain DOMAIN     Business domain (default: localhost)
  --email EMAIL       Admin email (default: admin@localhost)
  --help              Show this help

EXAMPLE:
  sudo bash install-native.sh --disk /dev/nvme0n1 --hostname empire-01 --domain mybusiness.com

WARNING:
  This DESTROYS ALL DATA on the target disk. BACKUP FIRST.
  Must be run from a Debian Live USB (not from an installed OS).

EOF
}

parse_args() {
    local disk_given=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk) TARGET_DISK="$2"; disk_given=true; shift 2 ;;
            --hostname) HOSTNAME="$2"; shift 2 ;;
            --username) USERNAME="$2"; shift 2 ;;
            --timezone) TIMEZONE="$2"; shift 2 ;;
            --domain) DOMAIN="$2"; shift 2 ;;
            --email) BUSINESS_EMAIL="$2"; shift 2 ;;
            --help) show_help; exit 0 ;;
            *) echo "Unknown option: $1"; show_help; exit 1 ;;
        esac
    done

    # Require --disk explicitly. Do NOT reject /dev/sda when the user typed
    # it — SATA disks are /dev/sda on most laptops/desktops. (The old check
    # compared against the default value and rejected an explicit
    # '--disk /dev/sda', found by installer boot test 2026-10-13.)
    if [ "$disk_given" != true ]; then
        echo "ERROR: --disk is required."
        show_help
        exit 1
    fi

    # Validate target disk is a real block device (not a partition, not a regular file)
    if ! echo "$TARGET_DISK" | grep -qE '^/dev/(sd[a-z]|nvme[0-9]+n[0-9]+|vd[a-z]|hd[a-z]|mmcblk[0-9]+)$'; then
        die "Invalid --disk format: $TARGET_DISK. Must be a full disk (e.g., /dev/sda, /dev/nvme0n1), not a partition."
    fi
    if [ ! -b "$TARGET_DISK" ]; then
        die "Target disk does not exist or is not a block device: $TARGET_DISK"
    fi
}

main() {
    show_banner
    parse_args "$@"

    log_crit "══════════════════════════════════════════════════════════════════════"
    log_crit "  YOU ARE ABOUT TO DESTROY ALL DATA ON $TARGET_DISK"
    log_crit "  This will install KIRAT OS as the PRIMARY operating system."
    log_crit "══════════════════════════════════════════════════════════════════════"
    echo ""

    preflight

    # Resume offer — if this disk already holds an encrypted KIRAT OS
    # installation, let the user continue an interrupted install instead
    # of wiping everything.
    if detect_existing_install; then
        echo ""
        log_warn "Existing encrypted KIRAT OS installation detected on $TARGET_DISK."
        read -p "Resume the interrupted installation instead of wiping? [y/N]: " resume_ans
        case "$resume_ans" in
            y|Y|yes|YES|Yes)
                resume_mount_target
                ;;
            *)
                log_info "Fresh install chosen — ALL data on $TARGET_DISK will be destroyed."
                ;;
        esac
    fi

    if [ "$RESUME_MODE" != true ]; then
        stage1_partition
    fi
    run_stage stage2  stage2_base_install
    run_stage stage3  stage3_system_config
    run_stage stage3b stage3b_rbac_setup
    run_stage stage4  stage4_kernel_harden
    run_stage stage5  stage5_security_stack
    run_stage stage5b stage5b_ids_and_audit
    run_stage stage6  stage6_business_stack
    run_stage stage7  stage7_ai_backends
    run_stage stage8  stage8_kirat_components
    run_stage stage9  stage9_first_boot
    run_stage stage10 stage10_finalize
    # The completion marker is persisted before either encrypted volume closes.
    sync "$STAGE_MARKER"
    unmount_and_close_target
}

main "$@"
