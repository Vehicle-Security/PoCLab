# Auto-detect host arch; normalize arm64/aarch64 → arm64, everything else → x86_64
HOST_ARCH := $(shell uname -m)
ifeq ($(HOST_ARCH),arm64)
ARCH ?= arm64
else ifeq ($(HOST_ARCH),aarch64)
ARCH ?= arm64
else
ARCH ?= x86_64
endif

KERNEL_VERSION  ?= 6.1.14
BUSYBOX_VERSION ?= 1.36.1
JOBS            ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ── Arch-specific defaults ────────────────────────────────────────────────────
ifeq ($(ARCH),arm64)
CROSS_COMPILE ?= aarch64-linux-gnu-
QEMU_BIN      := qemu-system-aarch64
IMAGE_NAME    := Image
else ifeq ($(ARCH),x86_64)
CROSS_COMPILE ?=
QEMU_BIN      := qemu-system-x86_64
IMAGE_NAME    := bzImage
else
$(error Unsupported ARCH=$(ARCH). Supported: x86_64 arm64)
endif

# Security mitigations (x86_64 only: SMEP/SMAP; arm64 uses PAN/PXN by default)
SMEP  ?= y
SMAP  ?= y
KASLR ?= n

# ── Per-PoC kernel config ─────────────────────────────────────────────────────
# If pocs/<name>/kernel.config exists alongside the PoC source, it is merged
# on top of the common + arch config during the kernel build triggered by
# 'make poc'.  Other targets (make kernel) use only the common configs.
POC_DIR    := $(if $(POC),$(dir $(POC)),)
POC_CONFIG := $(if $(POC_DIR),$(wildcard $(POC_DIR)kernel.config),)

export ARCH CROSS_COMPILE QEMU_BIN IMAGE_NAME
export KERNEL_VERSION BUSYBOX_VERSION JOBS SMEP SMAP KASLR
export POC_CONFIG

# ── macOS: build via Docker, run via native QEMU ──────────────────────────────
DOCKER_IMAGE := kernel-poc-builder
DOCKER_RUN   := docker run --rm -v "$(shell pwd):/work" -w /work \
                    -e ARCH -e CROSS_COMPILE -e IMAGE_NAME \
                    -e KERNEL_VERSION -e BUSYBOX_VERSION -e JOBS \
                    -e POC_CONFIG \
                    $(DOCKER_IMAGE)

ifeq ($(shell uname),Darwin)
BUILD_CMD := $(DOCKER_RUN) bash

# Auto-build the Docker image on first run so plain 'make poc POC=...' works
# from a fresh clone without a separate 'make docker-image' step.
DOCKER_ENSURE = docker image inspect $(DOCKER_IMAGE) >/dev/null 2>&1 || \
                    (echo "[*] Docker image $(DOCKER_IMAGE) not found – building (one-time) ..." && \
                     docker build -t $(DOCKER_IMAGE) build/)
else
BUILD_CMD := bash
DOCKER_ENSURE = true
endif

.PHONY: all setup docker-image kernel rootfs run poc debug clean distclean

all: kernel rootfs

## Setup: check host dependencies
setup:
	@bash build/scripts/check_deps.sh

## Build Docker compiler image explicitly (macOS; also done automatically by other targets)
docker-image:
	docker build -t $(DOCKER_IMAGE) build/

## Build Linux kernel (uses common config; pass POC= to also apply PoC-specific config)
kernel:
	@$(DOCKER_ENSURE)
	@$(BUILD_CMD) build/scripts/build_kernel.sh

## Build busybox-based initramfs (no PoC injected)
rootfs:
	@$(DOCKER_ENSURE)
	@$(BUILD_CMD) build/scripts/build_rootfs.sh

## Build everything and run PoC inside QEMU – one command on any platform.
## If pocs/<name>/kernel.config exists, the kernel is rebuilt with that config.
## Usage: make poc POC=pocs/smoke/poc.c
poc:
	@[ -n "$(POC)" ] || (echo "Usage: make poc POC=<path/to/poc.c>"; exit 1)
	@$(DOCKER_ENSURE)
	@$(BUILD_CMD) build/scripts/build_kernel.sh
	@$(BUILD_CMD) build/scripts/build_rootfs.sh
	@$(BUILD_CMD) build/scripts/pack_poc.sh "$(POC)"
	@bash build/scripts/run.sh

## Run QEMU (plain shell, no PoC)
run:
	@bash build/scripts/run.sh

## Run QEMU with GDB server on :1234 (attach VSCode or gdb manually)
debug:
	@ENABLE_GDB=1 bash build/scripts/run.sh

## Remove built images for current arch (keep source and other arch outputs)
clean:
	rm -rf out/$(ARCH)/

## Remove everything including downloaded sources
distclean:
	rm -rf src/ out/
