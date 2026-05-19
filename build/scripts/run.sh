#!/usr/bin/env bash
# Launch QEMU with the kernel and rootfs
# Set ENABLE_GDB=1 to expose gdbserver on :1234

set -euo pipefail

ARCH="${ARCH:-x86_64}"
IMAGE_NAME="${IMAGE_NAME:-bzImage}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$BUILD_DIR")"
OUT_DIR="$PROJECT_ROOT/out"
ARCH_OUT="$OUT_DIR/$ARCH"

KERNEL_IMG="$ARCH_OUT/$IMAGE_NAME"
ROOTFS_IMG="$ARCH_OUT/rootfs.img"

if [ ! -f "$KERNEL_IMG" ]; then
    echo "[-] $KERNEL_IMG not found. Run 'make kernel' first."
    exit 1
fi

if [ ! -f "$ROOTFS_IMG" ]; then
    echo "[-] $ROOTFS_IMG not found. Run 'make rootfs' first."
    exit 1
fi

# ── Security knobs ────────────────────────────────────────────────────────────
KASLR="${KASLR:-n}"

APPEND="root=/dev/ram rdinit=/sbin/init oops=panic panic=1 panic_on_warn=1"
[ "$KASLR" != "y" ] && APPEND="$APPEND nokaslr"

# ── Arch-specific QEMU setup ──────────────────────────────────────────────────
EXTRA_ARGS=()

case "$ARCH" in
    arm64)
        MACHINE_ARGS=(-M virt)
        ARM64_CPU_TCG="cortex-a57"
        APPEND="console=ttyAMA0 $APPEND"
        ;;
    x86_64)
        SMEP="${SMEP:-y}"
        SMAP="${SMAP:-y}"
        CPU_FLAGS="qemu64"
        [ "$SMEP" = "y" ] && CPU_FLAGS="$CPU_FLAGS,+smep"
        [ "$SMAP" = "y" ] && CPU_FLAGS="$CPU_FLAGS,+smap"
        MACHINE_ARGS=(-cpu "$CPU_FLAGS")
        APPEND="console=ttyS0 $APPEND"
        echo "    SMEP=$SMEP  SMAP=$SMAP"
        ;;
    *)
        MACHINE_ARGS=()
        APPEND="console=ttyS0 $APPEND"
        ;;
esac

# ── macOS: HVF acceleration when host arch matches target arch ────────────────
if [ "$(uname)" = "Darwin" ]; then
    HOST_ARCH=$(uname -m)
    if [ "$HOST_ARCH" = "$ARCH" ]; then
        EXTRA_ARGS+=(-accel hvf)
        [ "$ARCH" = "arm64" ] && MACHINE_ARGS+=(-cpu host)
        echo "    HVF acceleration enabled"
    else
        [ "$ARCH" = "arm64" ] && MACHINE_ARGS+=(-cpu "${ARM64_CPU_TCG:-cortex-a57}")
        echo "    TCG emulation (cross-arch, no HVF)"
    fi
else
    [ "$ARCH" = "arm64" ] && MACHINE_ARGS+=(-cpu "${ARM64_CPU_TCG:-cortex-a57}")
fi

# ── GDB ───────────────────────────────────────────────────────────────────────
ENABLE_GDB="${ENABLE_GDB:-0}"
if [ "$ENABLE_GDB" = "1" ]; then
    EXTRA_ARGS+=(-gdb tcp::1234 -S)
    echo "[*] GDB server on :1234  (paused – attach before VM boots)"
    echo "    gdb out/$ARCH/vmlinux  →  target remote :1234"
    if [ "$ARCH" = "arm64" ] && [ "$(uname)" = "Darwin" ]; then
        echo "    (on macOS use aarch64-elf-gdb or lldb)"
    fi
    echo ""
fi

# ── Launch ─────────────────────────────────────────────────────────────────────
echo "[*] Starting QEMU ($ARCH) ...  KASLR=$KASLR"
echo "    Press Ctrl-A X to quit QEMU"
echo ""

QEMU_CMD=(
    "$QEMU_BIN"
    "${MACHINE_ARGS[@]}"
    -kernel "$KERNEL_IMG"
    -initrd "$ROOTFS_IMG"
    -append "$APPEND"
    -m 256M
    -display none
    -serial mon:stdio
    -no-reboot
)

if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
    QEMU_CMD+=("${EXTRA_ARGS[@]}")
fi

exec "${QEMU_CMD[@]}"
