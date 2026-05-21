#!/usr/bin/env bash
# Build copy-fail-c and the PoCLab kernel/rootfs needed by the exploit.
# Usage: [ARCH=arm64|x86_64] [KERNEL_VERSION=6.1.14] ./build-copyfail.sh

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"

ARCH="${ARCH:-arm64}"
KERNEL_VERSION="${KERNEL_VERSION:-6.1.14}"
SRC="$DIR/copy-fail-c"
IMG="kernel-poc-builder"
POC_SOURCE="pocs/copyfail/poc.c"
POC_CONFIG="pocs/copyfail/kernel.config"
REQUIRED_CONFIGS=(
  CONFIG_CRYPTO_USER_API
  CONFIG_CRYPTO_USER_API_AEAD
  CONFIG_CRYPTO_AUTHENC
  CONFIG_CRYPTO_HMAC
  CONFIG_CRYPTO_SHA256
  CONFIG_CRYPTO_CBC
  CONFIG_CRYPTO_AES
)
REQUIRED_OBJECTS=(
  crypto/af_alg.o
  crypto/algif_aead.o
  crypto/authenc.o
  crypto/authencesn.o
)

case "$ARCH" in
  arm64)
    CC=aarch64-linux-gnu-gcc
    LD=aarch64-linux-gnu-ld
    ;;
  x86_64)
    CC=x86_64-linux-gnu-gcc
    LD=x86_64-linux-gnu-ld
    ;;
  *)
    echo "Unsupported ARCH=$ARCH; use arm64 or x86_64" >&2
    exit 1
    ;;
esac

[ -d "$SRC" ] || git clone https://github.com/tgies/copy-fail-c "$SRC"

docker image inspect "$IMG" >/dev/null 2>&1 || docker build -t "$IMG" "$ROOT/build"
docker run --rm -v "$SRC:/work" -w /work "$IMG" make clean
docker run --rm -v "$SRC:/work" -w /work "$IMG" make CC="$CC" LD="$LD"

make -C "$ROOT" kernel rootfs \
  ARCH="$ARCH" \
  KERNEL_VERSION="$KERNEL_VERSION" \
  POC="$POC_SOURCE" \
  POC_CONFIG="$POC_CONFIG"

KERNEL_CONFIG="$ROOT/out/kernel-build-$ARCH/.config"
for config in "${REQUIRED_CONFIGS[@]}"; do
  if ! grep -q "^${config}=y$" "$KERNEL_CONFIG"; then
    echo "[-] $config is not enabled in $KERNEL_CONFIG" >&2
    echo "    Expected it from $POC_CONFIG" >&2
    exit 1
  fi
done

for obj in "${REQUIRED_OBJECTS[@]}"; do
  if [ ! -f "$ROOT/out/kernel-build-$ARCH/$obj" ]; then
    echo "[-] Required kernel object missing: out/kernel-build-$ARCH/$obj" >&2
    exit 1
  fi
done

echo "[+] copyfail build ready. Run ./run-copyfail.sh to inject and start QEMU."
