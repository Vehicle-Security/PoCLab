#!/usr/bin/env bash
# Build Linux kernel for the target architecture

set -euo pipefail

ARCH="${ARCH:-x86_64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
IMAGE_NAME="${IMAGE_NAME:-bzImage}"
KERNEL_VERSION="${KERNEL_VERSION:-6.1.14}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
POC_CONFIG="${POC_CONFIG:-}"
KCFLAGS="${KCFLAGS:-}"
SOURCE_PATCH_LEVEL=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"        # kernel-poc/build
PROJECT_ROOT="$(dirname "$BUILD_DIR")"      # kernel-poc
SRC_DIR="$PROJECT_ROOT/src"
OUT_DIR="$PROJECT_ROOT/out"
ARCH_OUT="$OUT_DIR/$ARCH"
CONFIG_DIR="$BUILD_DIR/config"

KERNEL_SRC="$SRC_DIR/linux-$KERNEL_VERSION"
KERNEL_BUILD="$OUT_DIR/kernel-build-$ARCH"
VERSION_STAMP="$KERNEL_BUILD/.poclab-kernel-version"

mkdir -p "$SRC_DIR" "$ARCH_OUT"

# The build directory is arch-scoped, so switching KERNEL_VERSION can otherwise
# leave generated headers from a previous kernel in place.
if [ -d "$KERNEL_BUILD" ]; then
    PREVIOUS_VERSION="$(cat "$VERSION_STAMP" 2>/dev/null || true)"
    if [ -z "$PREVIOUS_VERSION" ] && [ -e "$KERNEL_BUILD/.config" ]; then
        echo "[*] Removing stale unversioned kernel build dir for $ARCH ..."
        rm -rf "$KERNEL_BUILD"
    elif [ -n "$PREVIOUS_VERSION" ] && [ "$PREVIOUS_VERSION" != "$KERNEL_VERSION" ]; then
        echo "[*] Kernel version changed ($PREVIOUS_VERSION -> $KERNEL_VERSION); cleaning build dir ..."
        rm -rf "$KERNEL_BUILD"
    fi
fi

mkdir -p "$KERNEL_BUILD"
echo "$KERNEL_VERSION" > "$VERSION_STAMP"

# Older x86 kernels predate modern distro toolchains that default to PIE.
# GCC 10+ turned several warnings into errors that older kernels trigger:
#   -Wno-error=implicit-function-declaration  – old-style C calls in arch/x86
#   -Wno-error=array-parameter                – strict array decay (GCC 11+)
#   -Wno-error=address-of-packed-member       – unaligned packed struct access
# Silencing these as errors (not disabling the warnings) is safe for PoC builds.
cc_supports_flag() {
    printf 'int main(void) { return 0; }\n' | \
        "${CROSS_COMPILE}gcc" "$1" -x c -c -o /tmp/poclab-cc-test.o - \
        >/dev/null 2>&1
}

case "$KERNEL_VERSION" in
    3.*|4.*)
        SOURCE_PATCH_LEVEL="old-kernel-log2-nan-v2-x86-plt32-config-v5"
        for flag in -fno-pie \
                    -fno-stack-protector \
                    -fcf-protection=none \
                    -Wno-error=implicit-function-declaration \
                    -Wno-error=array-parameter \
                    -Wno-error=address-of-packed-member; do
            if cc_supports_flag "$flag"; then
                case " $KCFLAGS " in
                    *" $flag "*) ;;
                    *) KCFLAGS="${KCFLAGS:+$KCFLAGS }$flag" ;;
                esac
            fi
        done
        ;;
esac

[ -n "$KCFLAGS" ] && echo "[*] Kernel KCFLAGS: $KCFLAGS"

# ── Incremental build guard ───────────────────────────────────────────────────
# Hash of all config inputs: version, arch, toolchain, KCFLAGS, and every fragment file.
# If the kernel image already exists and this hash matches the last build,
# skip the entire configure+compile cycle.  Use FORCE_REBUILD=1 to bypass.
CONFIG_HASH_FILE="$KERNEL_BUILD/.poclab-config-hash"

_compiler_id() {
    "${CROSS_COMPILE}gcc" --version | head -n 1
    "${CROSS_COMPILE}ld" --version | head -n 1
}

_config_hash() {
    {
        echo "$KERNEL_VERSION"
        echo "$ARCH"
        _compiler_id
        echo "$KCFLAGS"
        echo "$SOURCE_PATCH_LEVEL"
        cat "$CONFIG_DIR/kernel-common.config" 2>/dev/null
        cat "$CONFIG_DIR/kernel-${ARCH}.config" 2>/dev/null
        [ -n "${POC_CONFIG:-}" ] && cat "$PROJECT_ROOT/$POC_CONFIG" 2>/dev/null || true
    } | md5sum | cut -d' ' -f1
}

CURRENT_CONFIG_HASH="$(_config_hash)"
IMAGE_OUT="$ARCH_OUT/$IMAGE_NAME"

if [ "${FORCE_REBUILD:-0}" = "0" ] && \
   [ -f "$IMAGE_OUT" ] && \
   [ "$(cat "$CONFIG_HASH_FILE" 2>/dev/null)" = "$CURRENT_CONFIG_HASH" ]; then
    echo "[*] Kernel ($ARCH, $KERNEL_VERSION) up-to-date — skipping build."
    echo "    Use FORCE_REBUILD=1 to force a full rebuild."
    exit 0
fi

PREVIOUS_CONFIG_HASH="$(cat "$CONFIG_HASH_FILE" 2>/dev/null || true)"
if [ -e "$KERNEL_BUILD/.config" ] && \
   { [ "${FORCE_REBUILD:-0}" != "0" ] || [ "$PREVIOUS_CONFIG_HASH" != "$CURRENT_CONFIG_HASH" ]; }; then
    echo "[*] Kernel build inputs changed; cleaning stale objects for $ARCH ..."
    rm -rf "$KERNEL_BUILD"
    mkdir -p "$KERNEL_BUILD"
    echo "$KERNEL_VERSION" > "$VERSION_STAMP"
fi

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

apply_old_kernel_compat_patches() {
    case "$KERNEL_VERSION" in
        3.*|4.*)
            local log2_h="$KERNEL_SRC/include/linux/log2.h"
            if [ -f "$log2_h" ] && grep -q '____ilog2_NaN()' "$log2_h"; then
                echo "[*] Applying old-kernel log2() toolchain compatibility patch ..."
                perl -0pi -e '
                    s/\(n\) < 1 \? ____ilog2_NaN\(\) :/(n) < 2 ? 0 :/g;
                    s/\n(\s*)____ilog2_NaN\(\)(\s*)\\/\n$1 0$2\\/g;
                ' "$log2_h"
            fi
            local x86_module_c="$KERNEL_SRC/arch/x86/kernel/module.c"
            if [ -f "$x86_module_c" ] &&
               grep -q 'case R_X86_64_PC32:' "$x86_module_c" &&
               ! grep -q 'case R_X86_64_PLT32:' "$x86_module_c"; then
                echo "[*] Applying old-kernel x86_64 PLT32 module relocation patch ..."
                perl -0pi -e 's/case R_X86_64_PC32:/case R_X86_64_PLT32:\n\t\tcase R_X86_64_PC32:/' "$x86_module_c"
            fi
            ;;
    esac
}

apply_old_kernel_compat_patches

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

case "$KERNEL_VERSION" in
    3.*|4.*)
        OLD_KERNEL_CONFIG="$KERNEL_BUILD/.poclab-old-kernel.config"
        cat > "$OLD_KERNEL_CONFIG" <<'EOF'
# Older kernels in the legacy builder do not support this KASAN mode, and
# linux-4.4.21's NETFILTER_XT_TARGET_TCPMSS Makefile entry references a
# missing xt_TCPMSS.c. Heavy debug/KGDB options make 4.x x86_64 bzImages
# trip during very early QEMU direct boot on current macOS hosts.
# None of these are required for PoCLab smoke or AutoShield's kprobe module.
# CONFIG_KASAN is not set
# CONFIG_NETFILTER_XT_TARGET_TCPMSS is not set
# CONFIG_RELOCATABLE is not set
# CONFIG_KALLSYMS_ALL is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_DEBUG_FS is not set
# CONFIG_KGDB is not set
# CONFIG_KGDB_SERIAL_CONSOLE is not set
# CONFIG_BPF_JIT is not set
EOF
        MERGE_CONFIGS="$MERGE_CONFIGS $OLD_KERNEL_CONFIG"
        ;;
esac

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
    KCFLAGS="$KCFLAGS" \
    -j"$JOBS" "$IMAGE_NAME"

# ── 4. Copy output ────────────────────────────────────────────────────────────
case "$ARCH" in
    arm64)  BOOT_IMAGE="$KERNEL_BUILD/arch/arm64/boot/$IMAGE_NAME" ;;
    x86_64) BOOT_IMAGE="$KERNEL_BUILD/arch/x86/boot/$IMAGE_NAME" ;;
    *)      BOOT_IMAGE="$KERNEL_BUILD/arch/$ARCH/boot/$IMAGE_NAME" ;;
esac

cp "$BOOT_IMAGE" "$ARCH_OUT/$IMAGE_NAME"
cp "$KERNEL_BUILD/vmlinux" "$ARCH_OUT/vmlinux"

# Save config hash so the next run can skip this build if nothing changed.
echo "$CURRENT_CONFIG_HASH" > "$CONFIG_HASH_FILE"

SIZE_MB=$(du -m "$ARCH_OUT/$IMAGE_NAME" | cut -f1)
echo ""
echo "[+] Kernel ($ARCH): $ARCH_OUT/$IMAGE_NAME  (${SIZE_MB} MB)"
echo "    vmlinux:         $ARCH_OUT/vmlinux  (unstripped, for GDB)"
