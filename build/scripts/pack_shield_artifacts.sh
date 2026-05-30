#!/usr/bin/env bash
# Inject externally built shield artifacts into the initramfs rootfs.
# Usage: pack_shield_artifacts.sh <kernel|frida> <artifact-dir>

set -euo pipefail

MODE="${1:-}"
ARTIFACT_DIR="${2:-}"
ARCH="${ARCH:-x86_64}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$BUILD_DIR")"
ARCH_OUT="$PROJECT_ROOT/out/$ARCH"
ROOTFS_DIR="$ARCH_OUT/rootfs"
ROOTFS_IMG="$ARCH_OUT/rootfs.img"
SHIELD_ROOT="$ROOTFS_DIR/root/autoshield"

usage() {
    echo "Usage: $0 <kernel|frida> <artifact-dir>" >&2
}

if [ -z "$MODE" ] || [ -z "$ARTIFACT_DIR" ]; then
    usage
    exit 1
fi

case "$MODE" in
    kernel|frida) ;;
    *)
        echo "[-] Unsupported shield mode: $MODE" >&2
        usage
        exit 1
        ;;
esac

if [ ! -d "$ROOTFS_DIR" ]; then
    echo "[-] $ROOTFS_DIR not found. Run 'make rootfs' first." >&2
    exit 1
fi

if [ ! -f "$ROOTFS_IMG" ]; then
    echo "[-] $ROOTFS_IMG not found. Run 'make rootfs' first." >&2
    exit 1
fi

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "[-] AutoShield artifact directory not found: $ARTIFACT_DIR" >&2
    exit 1
fi

SRC_DIR="$ARTIFACT_DIR/$MODE"
if [ ! -d "$SRC_DIR" ]; then
    SRC_DIR="$ARTIFACT_DIR"
fi

mkdir -p "$SHIELD_ROOT/$MODE"
rm -rf "$SHIELD_ROOT/$MODE"
mkdir -p "$SHIELD_ROOT/$MODE"

case "$MODE" in
    kernel)
        MODULE_COUNT="$(find "$SRC_DIR" -maxdepth 2 -type f -name '*.ko' | wc -l | tr -d ' ')"
        if [ "$MODULE_COUNT" = "0" ]; then
            echo "[-] No kernel module (*.ko) found in $SRC_DIR" >&2
            exit 1
        fi
        cp -a "$SRC_DIR"/. "$SHIELD_ROOT/$MODE/"
        ;;
    frida)
        if [ ! -f "$SRC_DIR/run-frida-hook.sh" ] && [ ! -f "$SRC_DIR/agent.js" ]; then
            echo "[-] Frida artifacts need run-frida-hook.sh or agent.js in $SRC_DIR" >&2
            exit 1
        fi
        cp -a "$SRC_DIR"/. "$SHIELD_ROOT/$MODE/"
        if [ ! -f "$SHIELD_ROOT/$MODE/run-frida-hook.sh" ]; then
            cat > "$SHIELD_ROOT/$MODE/run-frida-hook.sh" <<'EOF'
#!/bin/sh
set -eu

TARGET="${1:-/root/poc}"
AGENT="/root/autoshield/frida/agent.js"

if command -v frida >/dev/null 2>&1; then
    exec frida -f "$TARGET" -l "$AGENT" --no-pause
fi

echo "frida command not found; provide run-frida-hook.sh in AutoShield artifacts" >&2
exit 127
EOF
        fi
        cat > "$SHIELD_ROOT/$MODE/poc-frida-wrapper" <<'EOF'
#!/bin/sh
exec /root/autoshield/frida/run-frida-hook.sh /root/poc
EOF
        chmod +x "$SHIELD_ROOT/$MODE/run-frida-hook.sh" "$SHIELD_ROOT/$MODE/poc-frida-wrapper"
        ;;
esac

cat > "$SHIELD_ROOT/shield.env" <<EOF
SHIELD_MODE=$MODE
SHIELD_DIR=/root/autoshield/$MODE
EOF

echo "[*] Injected AutoShield $MODE artifacts into /root/autoshield"

echo "[*] Repacking rootfs.img ..."
(
    cd "$ROOTFS_DIR"
    find . | cpio -H newc -o
) > "$ROOTFS_IMG"

echo "[+] Done ($ARCH). rootfs.img updated with AutoShield $MODE artifacts"
