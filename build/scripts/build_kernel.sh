#!/usr/bin/env bash
# Build Linux kernel for the target architecture

set -euo pipefail

ARCH="${ARCH:-x86_64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
IMAGE_NAME="${IMAGE_NAME:-bzImage}"
KERNEL_VERSION="${KERNEL_VERSION:-6.1.14}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
POC_CONFIG="${POC_CONFIG:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"        # kernel-poc/build
PROJECT_ROOT="$(dirname "$BUILD_DIR")"      # kernel-poc
SRC_DIR="$PROJECT_ROOT/src"
OUT_DIR="$PROJECT_ROOT/out"
ARCH_OUT="$OUT_DIR/$ARCH"
CONFIG_DIR="$BUILD_DIR/config"

KERNEL_SRC="$SRC_DIR/linux-$KERNEL_VERSION"
KERNEL_BUILD="$OUT_DIR/kernel-build-$ARCH"

mkdir -p "$SRC_DIR" "$KERNEL_BUILD" "$ARCH_OUT"

# ── 1. Download kernel source ─────────────────────────────────────────────────
if [ ! -d "$KERNEL_SRC" ]; then
    MAJOR="${KERNEL_VERSION%%.*}"
    TARBALL="linux-$KERNEL_VERSION.tar.xz"
    URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/$TARBALL"
    echo "[*] Downloading linux-$KERNEL_VERSION ..."
    wget -q --show-progress -c -P "$SRC_DIR" "$URL"
    echo "[*] Extracting ..."
    tar -xf "$SRC_DIR/$TARBALL" -C "$SRC_DIR"
    rm -f "$SRC_DIR/$TARBALL"
fi

# ── 2. Configure kernel ───────────────────────────────────────────────────────
echo "[*] Configuring kernel for $ARCH ..."
make -C "$KERNEL_SRC" O="$KERNEL_BUILD" \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    defconfig

# Merge config fragments in order:
#   1. kernel-common.config  (debug symbols, KASAN, BPF, namespaces, etc.)
#   2. kernel-${ARCH}.config (console, interrupt controller, etc.)
#   3. pocs/<name>/kernel.config (per-PoC requirements, optional)
MERGE_CONFIGS="$CONFIG_DIR/kernel-common.config $CONFIG_DIR/kernel-${ARCH}.config"
if [ -n "$POC_CONFIG" ]; then
    # POC_CONFIG may be relative (passed from pocctl) or absolute (direct make call).
    # Resolve relative paths against PROJECT_ROOT so this works inside Docker (/work).
    case "$POC_CONFIG" in
        /*) POC_CONFIG_ABS="$POC_CONFIG" ;;
        *)  POC_CONFIG_ABS="$PROJECT_ROOT/$POC_CONFIG" ;;
    esac
    MERGE_CONFIGS="$MERGE_CONFIGS $POC_CONFIG_ABS"
fi

# shellcheck disable=SC2086
"$KERNEL_SRC/scripts/kconfig/merge_config.sh" \
    -m -O "$KERNEL_BUILD" \
    "$KERNEL_BUILD/.config" \
    $MERGE_CONFIGS

make -C "$KERNEL_SRC" O="$KERNEL_BUILD" \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    olddefconfig

# ── 3. Build kernel ───────────────────────────────────────────────────────────
echo "[*] Building kernel for $ARCH ($JOBS jobs) ..."
make -C "$KERNEL_SRC" O="$KERNEL_BUILD" \
    ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
    -j"$JOBS" "$IMAGE_NAME"

# ── 4. Copy output ────────────────────────────────────────────────────────────
case "$ARCH" in
    arm64)  BOOT_IMAGE="$KERNEL_BUILD/arch/arm64/boot/$IMAGE_NAME" ;;
    x86_64) BOOT_IMAGE="$KERNEL_BUILD/arch/x86/boot/$IMAGE_NAME" ;;
    *)      BOOT_IMAGE="$KERNEL_BUILD/arch/$ARCH/boot/$IMAGE_NAME" ;;
esac

cp "$BOOT_IMAGE" "$ARCH_OUT/$IMAGE_NAME"
cp "$KERNEL_BUILD/vmlinux" "$ARCH_OUT/vmlinux"

SIZE_MB=$(du -m "$ARCH_OUT/$IMAGE_NAME" | cut -f1)
echo ""
echo "[+] Kernel ($ARCH): $ARCH_OUT/$IMAGE_NAME  (${SIZE_MB} MB)"
echo "    vmlinux:         $ARCH_OUT/vmlinux  (unstripped, for GDB)"
