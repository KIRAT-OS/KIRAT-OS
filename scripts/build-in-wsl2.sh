#!/bin/bash
# =============================================================================
# KIRAT OS — ISO Build Script (Run INSIDE WSL2 Debian)
# =============================================================================
# This script runs inside WSL2 Debian to build the bootable KIRAT OS ISO.
# Prerequisites: Debian/Ubuntu WSL2 with debootstrap, grub, xorriso installed
#
# Usage:
#   sudo bash build-in-wsl2.sh
# =============================================================================

set -euo pipefail

echo "═══════════════════════════════════════════════════════════════"
echo "  KIRAT OS ISO Builder — WSL2 Edition"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# ── Configuration ──
OUTPUT_ISO="$HOME/kirat-os-2.0.0.iso"
KIRAT_DIR="$HOME/kirat-build"
BUILD_LOG="$HOME/kirat-build.log"

# ── Check if running as root ──
if [ "$EUID" -ne 0 ]; then
    echo "This script must run as root inside WSL2."
    echo "Run: sudo bash build-in-wsl2.sh"
    exit 1
fi

# ── Check disk space ──
FREE_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
echo "Free disk space: ${FREE_GB}GB"
if [ "${FREE_GB:-0}" -lt 15 ]; then
    echo "ERROR: Need at least 15GB free in WSL2. You have ${FREE_GB}GB."
    echo "Free up space or expand WSL2 disk: wsl --manage Debian --set-sparse false"
    exit 1
fi

# ── Install build dependencies if missing ──
echo ""
echo "[1/5] Checking build dependencies..."
DEPS_OK=true
for pkg in debootstrap grub-pc-bin grub-efi-amd64-bin xorriso mksquashfs curl; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        echo "  Missing: $pkg"
        DEPS_OK=false
    fi
done

if [ "$DEPS_OK" = false ]; then
    echo "Installing missing packages..."
    apt-get update -qq
    apt-get install -y -qq debootstrap grub-pc-bin grub-efi-amd64-bin xorriso squashfs-tools curl || {
        echo "ERROR: Failed to install build dependencies."
        echo "Run manually: sudo apt-get install debootstrap grub-pc-bin grub-efi-amd64-bin xorriso squashfs-tools"
        exit 1
    }
fi
echo "  ✓ All dependencies installed"

# ── Check KIRAT OS source ──
echo ""
echo "[2/5] Checking KIRAT OS source..."
if [ ! -d "$KIRAT_DIR/scripts" ]; then
    echo "ERROR: KIRAT OS source not found at $KIRAT_DIR"
    echo "Copy from Windows first, or clone from your workspace:"
    echo "  cp -r /mnt/c/Users/\$USER/Documents/kimi/workspace/kirat-os-server ~/kirat-build"
    exit 1
fi
echo "  ✓ Source found at $KIRAT_DIR"

# ── Clean previous builds ──
echo ""
echo "[3/5] Cleaning previous builds..."
rm -f "$OUTPUT_ISO" "$OUTPUT_ISO.sha256" "$OUTPUT_ISO.md5"
rm -rf /tmp/kirat-os-iso-build*
echo "  ✓ Cleaned"

# ── Build the ISO ──
echo ""
echo "[4/5] Building KIRAT OS ISO..."
echo "    This will take 15-45 minutes depending on internet speed."
echo "    Log file: $BUILD_LOG"
echo ""

cd "$KIRAT_DIR/scripts"
bash build-iso.sh \
    --output "$OUTPUT_ISO" \
    --include-installer \
    --compression xz 2>&1 | tee "$BUILD_LOG"

BUILD_STATUS=$?

# ── Verify result ──
echo ""
echo "[5/5] Verifying build..."
if [ $BUILD_STATUS -eq 0 ] && [ -f "$OUTPUT_ISO" ]; then
    ISO_SIZE=$(du -h "$OUTPUT_ISO" | cut -f1)
    echo "  ✓ ISO built successfully!"
    echo "  ✓ Location: $OUTPUT_ISO"
    echo "  ✓ Size: $ISO_SIZE"
    
    if [ -f "$OUTPUT_ISO.sha256" ]; then
        echo "  ✓ SHA256 checksum: $(cat "$OUTPUT_ISO.sha256" | awk '{print $1}')"
    fi
    
    # Copy to Windows Desktop for easy access
    WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r')
    if [ -n "$WIN_USER" ]; then
        DESKTOP_PATH="/mnt/c/Users/$WIN_USER/Desktop"
        if [ -d "$DESKTOP_PATH" ]; then
            cp "$OUTPUT_ISO" "$DESKTOP_PATH/" 2>/dev/null && echo "  ✓ Copied to Windows Desktop"
            cp "$OUTPUT_ISO.sha256" "$DESKTOP_PATH/" 2>/dev/null || true
        fi
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  🎉 KIRAT OS ISO BUILD COMPLETE!"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Next steps:"
    echo "  1. Use Rufus (https://rufus.ie) to write ISO to USB"
    echo "  2. Boot new laptop from USB"
    echo "  3. Select 'Install KIRAT OS' from GRUB menu"
    echo "  4. Follow installer prompts"
    echo ""
    echo "To test in VM first:"
    echo "  qemu-system-x86_64 -m 4096 -cdrom $OUTPUT_ISO -boot d"
    echo ""
    
else
    echo "  ✗ ISO build FAILED"
    echo "  Check log: $BUILD_LOG"
    echo "  Common issues:"
    echo "    - Internet connection lost during debootstrap"
    echo "    - Not enough disk space"
    echo "    - Missing packages"
    exit 1
fi
