#!/bin/bash
# Focused build-iso.sh regressions. This test never builds an ISO.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_SCRIPT="$SCRIPT_DIR/../scripts/build-iso.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
assert_contains() { grep -Fq -- "$2" "$BUILD_SCRIPT" || fail "$1"; }
assert_not_contains() { ! grep -Fq -- "$2" "$BUILD_SCRIPT" || fail "$1"; }

assert_contains "2.0.8 version" 'readonly SCRIPT_VERSION="2.0.8"'
assert_contains "2.0.8 OS version" 'readonly KIRAT_VERSION="2.0.8"'
assert_contains "pre-release version output" 'PRE-RELEASE'
assert_contains "no production guarantee" 'Not production-ready'

assert_not_contains "no universal live credential" 'kirat:kirat'
assert_not_contains "no password assignment" 'chpasswd'
assert_contains "live password locked" 'chroot "$rootfs" passwd -l kirat'
assert_contains "SSH password authentication disabled" 'PasswordAuthentication no'
assert_contains "SSH keyboard-interactive authentication disabled" 'KbdInteractiveAuthentication no'
assert_contains "SSH challenge-response authentication disabled" 'ChallengeResponseAuthentication no'
assert_not_contains "SSH password authentication never enabled" 'PasswordAuthentication yes'
! grep -Eq 'systemctl[[:space:]]+enable[^[:cntrl:]]*(ssh|nginx)' "$BUILD_SCRIPT" ||
    fail "SSH or nginx is enabled"
assert_contains "service disablement" 'systemctl disable "$unit"'
assert_contains "SSH wants links removed" '*.target.wants/ssh.service'
pass "live SSH/account hardening"

assert_contains "initramfs regeneration is fatal" 'Initramfs regeneration failed for kernel'
assert_contains "initramfs artifact required" 'Initramfs is missing or empty for kernel'
assert_contains "kernel required before squash" '[[ -s "$kernel" ]]'
assert_contains "matching initramfs required before squash" '[[ -s "$initrd" ]]'
assert_contains "kernel and initramfs versions matched" 'initrd="$rootfs/boot/initrd.img-$kver"'
assert_not_contains "no fail-open initramfs creation" 'update-initramfs -c -k "$kver" 2>/dev/null || true'
pass "required boot files"

assert_contains "nonempty ISO required" '[[ -s "$OUTPUT" ]]'
assert_contains "checksum verified" 'sha256sum -c "$output_name.sha256"'
assert_contains "El Torito report required" '-report_el_torito plain'
assert_contains "squashfs inspected" 'unsquashfs -ll "$WORK_DIR/live/filesystem.squashfs"'
assert_contains "installer payload checked" 'opt/kirat-os-installer/install-native.sh'
assert_contains "installer launcher checked" 'usr/local/bin/kirat-os-install'
pass "post-build artifact validation"

assert_contains "signed shim retained" '/usr/lib/shim/shimx64.efi.signed'
assert_contains "signed CD GRUB retained" 'gcdx64.efi.signed'
assert_contains "signed chain condition retained" 'if [[ "$shim" == *.signed && "$grub" == *.signed ]]'
assert_contains "signed shim ESP path retained" 'mcopy -i "$efi_img" "$shim" ::/EFI/BOOT/BOOTX64.EFI'
assert_contains "signed GRUB ESP path retained" 'mcopy -i "$efi_img" "$grub" ::/EFI/BOOT/grubx64.efi'
pass "Secure Boot signed chain"

# Extract the generated installer's functions and exercise them with mocked
# lsblk/findmnt data: sda=system, sdb=live, sdd=mounted, sdf=read-only, sr0=ROM.
LAUNCHER=$(awk "/<< 'INSTALLER'/ { copy=1; next } copy && /^INSTALLER$/ { exit } copy { print }" "$BUILD_SCRIPT")
[[ "$LAUNCHER" == '#!/bin/bash'* ]] || fail "unable to extract installer launcher"
LAUNCHER_FUNCTIONS=${LAUNCHER%%$'\nclear\n'*}

lsblk() {
    local args="$*"
    if [[ "$args" == "-dnpo NAME,TYPE" ]]; then
        printf '%s\n' '/dev/sda disk' '/dev/sdb disk' '/dev/sdc disk' \
            '/dev/sdd disk' '/dev/sde disk' '/dev/sdf disk' '/dev/sr0 rom'
        return 0
    fi
    if [[ "$args" == "-dnro TYPE -- "* ]]; then
        case "$4" in
            /dev/sda1|/dev/sdb1) echo part ;;
            /dev/sr0) echo rom ;;
            /dev/sd[a-f]) echo disk ;;
            *) return 1 ;;
        esac
        return 0
    fi
    if [[ "$args" == "-dnro PKNAME -- "* ]]; then
        case "$4" in
            /dev/sda1) echo sda ;;
            /dev/sdb1) echo sdb ;;
            *) return 1 ;;
        esac
        return 0
    fi
    if [[ "$args" == "-dnro RO -- "* ]]; then
        [[ "$4" == /dev/sdf ]] && echo 1 || echo 0
        return 0
    fi
    if [[ "$args" == "-nrpo NAME,MOUNTPOINTS -- "* ]]; then
        case "$4" in
            /dev/sda) printf '%s\n' '/dev/sda' '/dev/sda1 /' ;;
            /dev/sdd) printf '%s\n' '/dev/sdd' '/dev/sdd1 /mnt/data' ;;
            *) printf '%s\n' "$4" ;;
        esac
        return 0
    fi
    if [[ "$args" == "-dno NAME,SIZE,MODEL,TRAN -- "* ]]; then
        printf '%s 128G TestDisk sata\n' "$4"
        return 0
    fi
    printf 'unexpected lsblk arguments: %s\n' "$args" >&2
    return 2
}

findmnt() {
    local target="${@: -1}"
    case "$target" in
        /) echo /dev/sda1 ;;
        /run/live/medium) echo /dev/sdb1 ;;
        *) return 1 ;;
    esac
}
clear() { :; }
sudo() { printf 'SUDO_CALLED:%s\n' "$*"; }

eval "$LAUNCHER_FUNCTIONS"
mapfile -t candidates < <(list_installable_disks)
[[ "${candidates[*]}" == '/dev/sdc /dev/sde' ]] ||
    fail "unsafe candidate list: ${candidates[*]:-<empty>}"
pass "system/live/mounted/optical/read-only disks excluded"

run_installer() {
    local input="$1"
    set +e
    RUN_OUTPUT=$(printf '%s' "$input" | (eval "$LAUNCHER") 2>&1)
    RUN_STATUS=$?
    set -e
}

for choice in 1 2; do
    run_installer "$choice"$'\n/dev/sdc\n/dev/sdc\n'
    [[ $RUN_STATUS -eq 0 ]] || fail "explicit install choice $choice failed: $RUN_OUTPUT"
    [[ "$RUN_OUTPUT" == *'SUDO_CALLED:bash /opt/kirat-os-installer/install-native.sh --disk /dev/sdc'* ]] ||
        fail "confirmed target was not passed safely"
done
pass "standard and advanced installs require explicit full-path selection"

run_installer $'1\n/dev/sdc\n/dev/not-the-target\n'
[[ $RUN_STATUS -ne 0 ]] || fail "wrong confirmation unexpectedly succeeded"
[[ "$RUN_OUTPUT" != *SUDO_CALLED* ]] || fail "native installer ran after wrong confirmation"
pass "wrong erasure confirmation refuses installation"

run_installer $'1\n/dev/sda\n'
[[ $RUN_STATUS -ne 0 ]] || fail "system disk selection unexpectedly succeeded"
[[ "$RUN_OUTPUT" != *SUDO_CALLED* ]] || fail "native installer ran for ineligible disk"
pass "ineligible explicit path refuses installation"

printf 'All build-iso.sh regression tests passed.\n'
