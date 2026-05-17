#!/usr/bin/env bash
# Check host dependencies for kernel-poc

set -euo pipefail

OK=0; WARN=1; FAIL=2
pass=0; warn=0; fail=0

check() {
    local level="$1" name="$2" cmd="$3"
    if eval "$cmd" >/dev/null 2>&1; then
        echo "  [+] $name"
        pass=$((pass + 1))
    elif [ "$level" = "$WARN" ]; then
        echo "  [!] $name (optional)"
        warn=$((warn + 1))
    else
        echo "  [-] $name  MISSING"
        fail=$((fail + 1))
    fi
}

OS=$(uname)
echo "=== kernel-poc dependency check ($(uname -s) $(uname -m)) ==="
echo ""

if [ "$OS" = "Darwin" ]; then
    echo "── macOS build tools (via Docker) ──"
    check $OK  "docker"                "command -v docker"
    check $OK  "docker running"        "docker info"
    echo ""
    echo "── macOS runtime (native QEMU) ──"
    check $OK  "qemu-system-x86_64"   "command -v qemu-system-x86_64"
    check $OK  "qemu-system-aarch64"  "command -v qemu-system-aarch64"
    check $WARN "gdb (for debugging)" "command -v gdb"
else
    echo "── Linux build tools ──"
    for t in make gcc flex bison bc cpio wget xz; do
        check $OK "$t" "command -v $t"
    done
    check $OK  "libelf-dev"     "[ -f /usr/include/libelf.h ] || pkg-config libelf"
    check $OK  "libssl-dev"     "[ -f /usr/include/openssl/ssl.h ] || pkg-config openssl"
    check $WARN "musl-gcc"      "command -v musl-gcc"
    check $WARN "aarch64-gcc"   "command -v aarch64-linux-gnu-gcc"
    echo ""
    echo "── Linux runtime (QEMU) ──"
    check $OK  "qemu-system-x86_64"  "command -v qemu-system-x86_64"
    check $WARN "qemu-system-aarch64" "command -v qemu-system-aarch64"
    check $WARN "gdb"                 "command -v gdb"
fi

echo ""
echo "── Summary ──"
echo "  Passed: $pass   Warnings: $warn   Missing: $fail"

if [ "$fail" -gt 0 ]; then
    echo ""
    echo "Install missing dependencies and re-run 'make setup'."
    if [ "$OS" = "Darwin" ]; then
        echo "  brew install qemu"
        echo "  # Install Docker Desktop from https://www.docker.com/products/docker-desktop"
    else
        echo "  sudo apt install build-essential gcc flex bison bc cpio wget xz-utils \\"
        echo "      libelf-dev libssl-dev qemu-system-x86 musl-tools gdb"
    fi
    exit 1
fi
