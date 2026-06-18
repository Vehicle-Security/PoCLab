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
AUTOSHIELD_DIR  ?= ../AutoShield
AUTOSHIELD_OUT  ?= $(abspath out/$(ARCH)/autoshield)
SHIELD_MODE     ?= kernel

# ── Arch-specific defaults ────────────────────────────────────────────────────
ifeq ($(ARCH),arm64)
CROSS_COMPILE ?= aarch64-linux-gnu-
QEMU_BIN      := qemu-system-aarch64
IMAGE_NAME    := Image
else ifeq ($(ARCH),x86_64)
ifneq ($(HOST_ARCH),x86_64)
CROSS_COMPILE ?= x86_64-linux-gnu-
else
CROSS_COMPILE ?=
endif
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

POC_USER      ?=
POC_CAPS      ?=
SMP           ?= 1
PANIC_ON_WARN ?= y
FORCE_REBUILD ?= 0
EXIT_AFTER_POC ?= 0

export ARCH CROSS_COMPILE QEMU_BIN IMAGE_NAME
export KERNEL_VERSION BUSYBOX_VERSION JOBS SMEP SMAP KASLR
export POC_CONFIG POC_USER POC_CAPS SMP PANIC_ON_WARN FORCE_REBUILD
export AUTOSHIELD_OUT SHIELD_MODE EXIT_AFTER_POC

# ── macOS: build via Docker, run via native QEMU ──────────────────────────────
DOCKER_IMAGE        := kernel-poc-builder:latest
DOCKER_IMAGE_LEGACY := kernel-poc-builder-legacy:latest
KERNEL_MAJOR        := $(firstword $(subst ., ,$(KERNEL_VERSION)))
ACTIVE_DOCKER_IMAGE := $(if $(filter 3 4,$(KERNEL_MAJOR)),$(DOCKER_IMAGE_LEGACY),$(DOCKER_IMAGE))
DOCKER_RUN   := docker run --rm -v "$(shell pwd):/work" -w /work \
                    -e ARCH -e CROSS_COMPILE -e IMAGE_NAME \
                    -e KERNEL_VERSION -e BUSYBOX_VERSION -e JOBS \
                    -e POC_CONFIG -e POC_USER -e POC_CAPS \
                    -e SMP -e PANIC_ON_WARN -e FORCE_REBUILD \
                    $(ACTIVE_DOCKER_IMAGE)

ifeq ($(shell uname),Darwin)
BUILD_CMD := $(DOCKER_RUN) bash

# Select the right Dockerfile for the kernel major version.
# kernel 3.x / 4.x  → Dockerfile.legacy (stable image; does not change when
#                      the main Dockerfile is updated)
# kernel 5.x / 6.x  → Dockerfile
DOCKERFILE = $(if $(filter 3 4,$(KERNEL_MAJOR)),build/Dockerfile.legacy,build/Dockerfile)

# ensure_docker_image.sh builds the image only when:
#   (a) it does not exist in the local Docker daemon, OR
#   (b) the Dockerfile has changed since the last successful build.
# A stamp file in out/.docker/ records the MD5 of the last successful
# Dockerfile so the check is instant on subsequent runs.
DOCKER_ENSURE = bash build/scripts/ensure_docker_image.sh \
                    $(ACTIVE_DOCKER_IMAGE) $(DOCKERFILE)
else
BUILD_CMD := bash
DOCKER_ENSURE = true
endif

.PHONY: all setup check docker-image kernel rootfs run poc poc-shielded autoshield debug clean distclean

all: kernel rootfs

## Setup: check host dependencies
setup:
	@bash build/scripts/check_deps.sh

## Lightweight repository checks that do not build kernels or launch QEMU
check:
	@bash -n pocctl build/scripts/build_kernel.sh build/scripts/build_rootfs.sh \
		build/scripts/check_deps.sh build/scripts/ensure_docker_image.sh \
		build/scripts/pack_poc.sh build/scripts/pack_shield_artifacts.sh \
		build/scripts/run.sh build/scripts/test_pocctl.sh
	@sh -n build/rootfs/etc/init.d/rcS
	@bash build/scripts/test_pocctl.sh >/dev/null
	@./pocctl list >/dev/null
	@./pocctl validate >/dev/null

## Build Docker compiler image explicitly (macOS; also done automatically by other targets)
docker-image:
	@bash build/scripts/ensure_docker_image.sh $(ACTIVE_DOCKER_IMAGE) $(DOCKERFILE)

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

## Export AutoShield artifacts from a local private checkout.
## Usage: make autoshield SHIELD_MODE=kernel AUTOSHIELD_DIR=../AutoShield
autoshield:
	@test -d "$(AUTOSHIELD_DIR)" || \
	  (echo "AutoShield not found. Set AUTOSHIELD_DIR=/path/to/AutoShield"; exit 1)
	@case "$(SHIELD_MODE)" in kernel|frida) ;; \
	  *) echo "Unsupported SHIELD_MODE=$(SHIELD_MODE). Use kernel or frida."; exit 1 ;; \
	esac
	$(MAKE) -C "$(AUTOSHIELD_DIR)" export SHIELD_MODE="$(SHIELD_MODE)" \
		OUT="$(AUTOSHIELD_OUT)" ARCH="$(ARCH)" KERNEL_VERSION="$(KERNEL_VERSION)" \
		KERNEL_SRC="$(abspath src/linux-$(KERNEL_VERSION))" \
		KERNEL_BUILD="$(abspath out/kernel-build-$(ARCH))" \
		CROSS_COMPILE="$(CROSS_COMPILE)" \
		DOCKER_IMAGE="$(ACTIVE_DOCKER_IMAGE)"

## Build everything and run PoC with AutoShield artifacts injected into rootfs.
## Usage: make poc-shielded POC=pocs/smoke/poc.c SHIELD_MODE=kernel AUTOSHIELD_DIR=../AutoShield
poc-shielded:
	@[ -n "$(POC)" ] || (echo "Usage: make poc-shielded POC=<path/to/poc.c> SHIELD_MODE=kernel|frida"; exit 1)
	@test -d "$(AUTOSHIELD_DIR)" || \
	  (echo "AutoShield not found. Set AUTOSHIELD_DIR=/path/to/AutoShield"; exit 1)
	@case "$(SHIELD_MODE)" in kernel|frida) ;; \
	  *) echo "Unsupported SHIELD_MODE=$(SHIELD_MODE). Use kernel or frida."; exit 1 ;; \
	esac
	@$(DOCKER_ENSURE)
	@$(BUILD_CMD) build/scripts/build_kernel.sh
	$(MAKE) -C "$(AUTOSHIELD_DIR)" export SHIELD_MODE="$(SHIELD_MODE)" \
		OUT="$(AUTOSHIELD_OUT)" ARCH="$(ARCH)" KERNEL_VERSION="$(KERNEL_VERSION)" \
		KERNEL_SRC="$(abspath src/linux-$(KERNEL_VERSION))" \
		KERNEL_BUILD="$(abspath out/kernel-build-$(ARCH))" \
		CROSS_COMPILE="$(CROSS_COMPILE)" \
		DOCKER_IMAGE="$(ACTIVE_DOCKER_IMAGE)"
	@$(BUILD_CMD) build/scripts/build_rootfs.sh
	@$(BUILD_CMD) build/scripts/pack_poc.sh "$(POC)"
	@bash build/scripts/pack_shield_artifacts.sh "$(SHIELD_MODE)" "$(AUTOSHIELD_OUT)"
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

## Remove everything including downloaded sources and Docker stamps
distclean:
	rm -rf src/ out/
