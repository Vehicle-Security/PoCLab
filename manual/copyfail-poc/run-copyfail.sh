#!/usr/bin/env bash
# Compile copy-fail-c, inject into rootfs, and launch QEMU.
# PoC boots as non-root user 'user' (LPE scenario).
# Run build-copyfail.sh once first to prepare kernel + rootfs.
# Usage: [ARCH=arm64|x86_64] ./run-copyfail.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"

ARCH="${ARCH:-arm64}"
SRC="$DIR/copy-fail-c"
IMG="kernel-poc-builder"

case "$ARCH" in
  arm64)
    CC=aarch64-linux-gnu-gcc
    LD=aarch64-linux-gnu-ld
    IMAGE_NAME=Image
    QEMU_BIN=qemu-system-aarch64
    ;;
  x86_64)
    CC=x86_64-linux-gnu-gcc
    LD=x86_64-linux-gnu-ld
    IMAGE_NAME=bzImage
    QEMU_BIN=qemu-system-x86_64
    ;;
  *)
    echo "Unsupported ARCH=$ARCH; use arm64 or x86_64" >&2
    exit 1
    ;;
esac

command -v "$QEMU_BIN" >/dev/null || { echo "$QEMU_BIN not found" >&2; exit 1; }

ROOTFS="$ROOT/out/$ARCH/rootfs"
[ -d "$ROOTFS" ] || { echo "rootfs not found – run build-copyfail.sh first" >&2; exit 1; }
[ -d "$SRC" ]   || { echo "copy-fail-c not found – run build-copyfail.sh first" >&2; exit 1; }

# Compile copy-fail-c (incremental; no clean)
docker run --rm -v "$SRC:/work" -w /work "$IMG" make CC="$CC" LD="$LD"

# Inject binaries into rootfs
GUEST_DIR="$ROOTFS/root/copyfail"
install -d -m 755 "$GUEST_DIR"
install -m 755 "$SRC/exploit"         "$GUEST_DIR/exploit"
install -m 755 "$SRC/exploit-passwd"  "$GUEST_DIR/exploit-passwd"
install -m 755 "$SRC/vulnerable"      "$GUEST_DIR/vulnerable"

# copy-fail-c defaults to /usr/bin/su. Keep the main BusyBox binary normal
# because /sbin/init also resolves to it; use a separate setuid copy as target.
# Copy without setuid first; chmod 4755 happens inside Docker so the Linux
# kernel sets the bit – macOS→VirtioFS→Docker loses the setuid bit otherwise.
chmod 755 "$ROOTFS/bin/busybox"
rm -f "$ROOTFS/usr/bin/su"
cp "$ROOTFS/bin/busybox" "$ROOTFS/usr/bin/su"

# LPE mode: start exploit as non-root uid 1000. The exploit mutates the cached
# setuid target and execs "su", which should load the payload as root.
cat > "$ROOTFS/root/poc" <<'EOF'
#!/bin/sh
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
cd /root/copyfail
whoami
exec ./exploit
EOF
echo "user" > "$ROOTFS/root/poc.user"
chmod 755 "$ROOTFS/root" "$GUEST_DIR" "$ROOTFS/root/poc"

# Suppress busybox init's default askfirst shells (they fight for /dev/console)
install -m 644 "$ROOT/build/rootfs/etc/inittab" "$ROOTFS/etc/inittab"

# Sync any other overlay files that may have changed since make rootfs
install -m 755 "$ROOT/build/rootfs/etc/init.d/rcS" "$ROOTFS/etc/init.d/rcS"

# Repack rootfs.img
echo "[*] Repacking rootfs.img ..."
docker run --rm \
  -v "$ROOT:/work" \
  -w "/work/out/$ARCH/rootfs" \
  "$IMG" \
  bash -lc 'find . | cpio --quiet -R 0:0 -H newc -o' \
  > "$ROOT/out/$ARCH/rootfs.img"

# Launch QEMU
ARCH="$ARCH" IMAGE_NAME="$IMAGE_NAME" QEMU_BIN="$QEMU_BIN" \
  bash "$ROOT/build/scripts/run.sh"
