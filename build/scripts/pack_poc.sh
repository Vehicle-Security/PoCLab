#!/usr/bin/env bash
# Compile a PoC source file, inject it into rootfs, and repack the initramfs.
# Usage: pack_poc.sh <path/to/poc.c>

set -euo pipefail

ARCH="${ARCH:-x86_64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$BUILD_DIR")"
OUT_DIR="$PROJECT_ROOT/out"
ARCH_OUT="$OUT_DIR/$ARCH"
ROOTFS_DIR="$ARCH_OUT/rootfs"
ROOTFS_IMG="$ARCH_OUT/rootfs.img"

POC_INPUT="$1"
POC_BIN="$ARCH_OUT/poc"

if [ -n "$CROSS_COMPILE" ] && command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1; then
    CC="${CROSS_COMPILE}gcc"
    CC_DESC="Cross-compiling with $CC"
elif command -v musl-gcc >/dev/null 2>&1 && [ "$ARCH" = "x86_64" ]; then
    CC="musl-gcc"
    CC_DESC="Compiling with musl-gcc (smaller static binary)"
else
    CC="gcc"
    CC_DESC="Compiling with $CC -static"
fi

# ── Validate inputs ───────────────────────────────────────────────────────────
if [ -z "$POC_INPUT" ]; then
    echo "Usage: pack_poc.sh <path/to/poc.c>" >&2
    exit 1
fi

if [ ! -f "$ROOTFS_IMG" ]; then
    echo "[-] $ROOTFS_IMG not found. Run 'make rootfs' first." >&2
    exit 1
fi

if [ ! -d "$ROOTFS_DIR" ]; then
    echo "[-] $ROOTFS_DIR not found. Run 'make rootfs' first." >&2
    exit 1
fi

# ── Compile PoC ───────────────────────────────────────────────────────────────
if [[ "$POC_INPUT" == *.c ]]; then
    echo "[*] Compiling $POC_INPUT for $ARCH ..."
    echo "    $CC_DESC"

    "$CC" -O1 -static -g -Wall -Wno-unused-result \
        -o "$POC_BIN" "$POC_INPUT" \
        -static -lpthread

    SIZE=$(du -k "$POC_BIN" | cut -f1)
    echo "[+] Compiled: $POC_BIN  (${SIZE}K)"
else
    # Treat as precompiled binary
    echo "[*] Using precompiled binary: $POC_INPUT"
    cp "$POC_INPUT" "$POC_BIN"
fi

chmod +x "$POC_BIN"

# ── Inject into rootfs ────────────────────────────────────────────────────────
echo "[*] Injecting poc binary into rootfs ..."
cp "$POC_BIN" "$ROOTFS_DIR/root/poc"

# If POC_USER is set, the PoC is a privilege-escalation exploit that must start
# as a non-root user.  Write the username to poc.user and open up permissions so
# the non-root user can read and execute the binary from /root/.
if [ -n "${POC_USER:-}" ]; then
    echo "[*] LPE mode: PoC will start as user '$POC_USER' (expects to escalate to root)"
    echo "$POC_USER" > "$ROOTFS_DIR/root/poc.user"
    chmod 755 "$ROOTFS_DIR/root/poc"   # world-executable
    chmod 755 "$ROOTFS_DIR/root"       # open /root/ so non-root can enter

    if [ -n "${POC_CAPS:-}" ]; then
        echo "[*] LPE mode: granting PoC capabilities '$POC_CAPS'"
        echo "$POC_CAPS" > "$ROOTFS_DIR/root/poc.caps"
        "$CC" -O2 -static -Wall -Wno-unused-result \
            -o "$ARCH_OUT/poc-cap-launcher" "$BUILD_DIR/scripts/poc_cap_launcher.c"
        cp "$ARCH_OUT/poc-cap-launcher" "$ROOTFS_DIR/root/poc-cap-launcher"
        chmod 700 "$ROOTFS_DIR/root/poc-cap-launcher"
    else
        rm -f "$ROOTFS_DIR/root/poc.caps" "$ROOTFS_DIR/root/poc-cap-launcher"
    fi
else
    rm -f "$ROOTFS_DIR/root/poc.user"  # clean up if switching from LPE to root mode
    rm -f "$ROOTFS_DIR/root/poc.caps" "$ROOTFS_DIR/root/poc-cap-launcher"
    chmod 700 "$ROOTFS_DIR/root/poc"
fi

# ── Repack rootfs.img ─────────────────────────────────────────────────────────
echo "[*] Repacking rootfs.img ..."
(
    cd "$ROOTFS_DIR"
    find . | cpio -H newc -o
) > "$ROOTFS_IMG"

echo "[+] Done ($ARCH). rootfs.img updated with /root/poc"
echo "    The PoC will run automatically on boot."
