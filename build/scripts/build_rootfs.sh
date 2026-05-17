#!/usr/bin/env bash
# Build minimal busybox-based initramfs

set -euo pipefail

ARCH="${ARCH:-x86_64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"        # kernel-poc/build
PROJECT_ROOT="$(dirname "$BUILD_DIR")"      # kernel-poc
SRC_DIR="$PROJECT_ROOT/src"
OUT_DIR="$PROJECT_ROOT/out"
ARCH_OUT="$OUT_DIR/$ARCH"
CONFIG_DIR="$BUILD_DIR/config"
ROOTFS_OVERLAY="$BUILD_DIR/rootfs"

BUSYBOX_SRC="$SRC_DIR/busybox-$BUSYBOX_VERSION"
BUSYBOX_BUILD="$OUT_DIR/busybox-build-$ARCH"
ROOTFS_DIR="$ARCH_OUT/rootfs"
ROOTFS_IMG="$ARCH_OUT/rootfs.img"

mkdir -p "$SRC_DIR" "$ARCH_OUT"

# ── 1. Download busybox ───────────────────────────────────────────────────────
if [ ! -d "$BUSYBOX_SRC" ]; then
    TARBALL="busybox-$BUSYBOX_VERSION.tar.bz2"
    URL="https://busybox.net/downloads/$TARBALL"
    echo "[*] Downloading busybox-$BUSYBOX_VERSION ..."
    wget -q --show-progress -c -P "$SRC_DIR" "$URL"
    echo "[*] Extracting ..."
    tar -xf "$SRC_DIR/$TARBALL" -C "$SRC_DIR"
    rm -f "$SRC_DIR/$TARBALL"
fi

# ── 2. Configure busybox (static, minimal) ───────────────────────────────────
echo "[*] Configuring busybox for $ARCH ..."

# Clean intermediate build dir if the previous build wasn't static.
# This avoids a stale dynamically-linked binary silently surviving.
if [ -f "$BUSYBOX_BUILD/.config" ] && \
   ! grep -q "^CONFIG_STATIC=y" "$BUSYBOX_BUILD/.config"; then
    echo "[*] Removing stale busybox build dir (was not static) ..."
    rm -rf "$BUSYBOX_BUILD"
fi

mkdir -p "$BUSYBOX_BUILD"

make -C "$BUSYBOX_SRC" O="$BUSYBOX_BUILD" CROSS_COMPILE="$CROSS_COMPILE" defconfig

# Apply user config fragment if present
FRAG="$CONFIG_DIR/busybox.config"
if [ -f "$FRAG" ]; then
    cat "$FRAG" >> "$BUSYBOX_BUILD/.config"
fi

# silentoldconfig uses the FIRST occurrence of a symbol, so defconfig's
# "# CONFIG_STATIC is not set" wins over anything appended later.
# Remove prior occurrences and append the values we require.
sed -i '/CONFIG_STATIC\b/d'           "$BUSYBOX_BUILD/.config"
sed -i '/CONFIG_FEATURE_INSTALLER/d'  "$BUSYBOX_BUILD/.config"
printf 'CONFIG_STATIC=y\nCONFIG_FEATURE_INSTALLER=y\n' >> "$BUSYBOX_BUILD/.config"

make -C "$BUSYBOX_SRC" O="$BUSYBOX_BUILD" CROSS_COMPILE="$CROSS_COMPILE" \
    silentoldconfig </dev/null

# ── 3. Build busybox ──────────────────────────────────────────────────────────
echo "[*] Building busybox for $ARCH ($JOBS jobs) ..."
make -C "$BUSYBOX_SRC" O="$BUSYBOX_BUILD" CROSS_COMPILE="$CROSS_COMPILE" -j"$JOBS"
make -C "$BUSYBOX_SRC" O="$BUSYBOX_BUILD" CROSS_COMPILE="$CROSS_COMPILE" install

# Quick sanity check: the binary must be statically linked.
# Use readelf (always available from binutils) instead of 'file' which may be absent.
BUSYBOX_BIN="$BUSYBOX_BUILD/_install/bin/busybox"
if readelf -d "$BUSYBOX_BIN" 2>/dev/null | grep -q "INTERP\|NEEDED"; then
    echo "[-] busybox is dynamically linked – CONFIG_STATIC=y did not take effect." >&2
    echo "    Try: rm -rf $BUSYBOX_BUILD && make rootfs" >&2
    exit 1
fi

# ── 4. Populate rootfs directory ─────────────────────────────────────────────
echo "[*] Building rootfs directory ..."
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc/init.d,home/user,lib,lib64,mnt,proc,root,run,sbin,sys,tmp,usr/{bin,sbin}}

# Copy busybox install tree
cp -a "$BUSYBOX_BUILD/_install/." "$ROOTFS_DIR/"

# Copy our rootfs overlay (etc/init.d/rcS, etc.)
if [ -d "$ROOTFS_OVERLAY" ]; then
    cp -a "$ROOTFS_OVERLAY/." "$ROOTFS_DIR/"
fi

chmod +x "$ROOTFS_DIR/etc/init.d/rcS" 2>/dev/null || true

# ── 5. Pack into initramfs cpio image ────────────────────────────────────────
echo "[*] Packing rootfs.img ..."
(
    cd "$ROOTFS_DIR"
    find . | cpio -H newc -o
) > "$ROOTFS_IMG"

SIZE_KB=$(du -k "$ROOTFS_IMG" | cut -f1)
echo ""
echo "[+] Rootfs image ($ARCH): $ROOTFS_IMG ($SIZE_KB KB)"
echo "    Rootfs dir:            $ROOTFS_DIR"
