#!/usr/bin/env bash
# Ensure a Docker builder image exists, rebuilding only when the Dockerfile
# changes or the image has been removed.  A stamp file in out/.docker/ records
# the MD5 of the last Dockerfile that produced a successful build.
#
# Usage: ensure_docker_image.sh <image-tag> <dockerfile-path>
#
# Exits 0 if the image is ready; non-zero (+ error message) on failure.

set -euo pipefail

IMAGE="${1:?Usage: $0 <image-tag> <dockerfile>}"
DOCKERFILE="${2:?Usage: $0 <image-tag> <dockerfile>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(dirname "$BUILD_DIR")"

# Stamp lives outside out/<ARCH>/ so it is not removed by 'make clean'.
STAMP_DIR="$PROJECT_ROOT/out/.docker"
# Sanitize image tag (replace : and / with _) for use as a filename.
STAMP_FILE="$STAMP_DIR/$(echo "$IMAGE" | tr ':/' '__').stamp"

mkdir -p "$STAMP_DIR"

# Portable MD5: macOS ships 'md5', Linux ships 'md5sum'.
_hash() {
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$1"
    else
        md5sum "$1" | cut -d' ' -f1
    fi
}

DF_HASH="$(_hash "$DOCKERFILE")"
CACHED_HASH="$(cat "$STAMP_FILE" 2>/dev/null || echo "")"

# Fast path: image present in local daemon AND Dockerfile unchanged.
# Use 'docker images -q' rather than 'docker image inspect': the inspect
# sub-command returns non-zero on Docker Desktop with the containerd image
# store even when the image exists and is fully usable.  'docker images -q'
# always returns the image ID (non-empty) when the image is present.
if [ "$CACHED_HASH" = "$DF_HASH" ] && \
   [ -n "$(docker images -q "$IMAGE" 2>/dev/null)" ]; then
    exit 0
fi

# Build context is the directory that contains the Dockerfile.
BUILD_CONTEXT="$(dirname "$DOCKERFILE")"

echo "[*] Building Docker image $IMAGE ..."
echo "    Dockerfile : $DOCKERFILE"
echo "    Context    : $BUILD_CONTEXT"

if ! docker build -t "$IMAGE" -f "$DOCKERFILE" "$BUILD_CONTEXT"; then
    echo "[-] Docker image build FAILED." >&2
    echo "    Dockerfile: $DOCKERFILE" >&2
    echo "    Try running manually:" >&2
    echo "      docker build -t $IMAGE -f $DOCKERFILE $BUILD_CONTEXT" >&2
    exit 1
fi

# Write stamp only after a confirmed successful build.
echo "$DF_HASH" > "$STAMP_FILE"
echo "[+] Docker image $IMAGE ready."
