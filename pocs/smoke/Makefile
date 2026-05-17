# pocs/smoke/Makefile – smoke test PoC
#
# Usage (from this directory):
#   make        – build kernel + rootfs + PoC, launch QEMU
#   make run    – same as above
#   make debug  – same but with GDB server on :1234
#   make clean  – remove built images for current ARCH
#
# All variables (ARCH, KASLR, SMEP, SMAP, KERNEL_VERSION, …) can be
# overridden on the command line, e.g.:
#   make KASLR=y SMEP=n
#
# PoC-specific kernel configuration is in kernel.config (if present).

# Locate the repo root relative to this file
REPO_ROOT      := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))../..)
POC_C          := pocs/smoke/poc.c
KERNEL_VERSION ?= 6.1.14

.PHONY: all run debug clean

all run:
	$(MAKE) -C "$(REPO_ROOT)" poc POC=$(POC_C) KERNEL_VERSION=$(KERNEL_VERSION) $(MAKEOVERRIDES)

debug:
	$(MAKE) -C "$(REPO_ROOT)" debug POC=$(POC_C) KERNEL_VERSION=$(KERNEL_VERSION) $(MAKEOVERRIDES)

clean:
	$(MAKE) -C "$(REPO_ROOT)" clean $(MAKEOVERRIDES)
