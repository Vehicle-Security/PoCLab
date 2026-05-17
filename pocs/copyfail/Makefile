# pocs/copyfail/Makefile – CVE-2026-31431 page-cache write PoC
#
# Vulnerability: authencesn AEAD ESN out-of-bounds write → page-cache write
#   without write permission.
# Affected kernels: Linux 5.x – 6.1.x (before patch)
#
# Usage (from this directory):
#   make            – build kernel 6.1.14 + rootfs + PoC, launch QEMU
#   make run        – same as above
#   make debug      – same but with GDB server on :1234
#   make clean      – remove built images for current ARCH
#   make KERNEL_VERSION=5.15.0   – test on a specific version
#
# The kernel.config fragment in this directory enables:
#   CONFIG_CRYPTO_USER_API_AEAD=y  CONFIG_CRYPTO_AUTHENC=y  (and more)
# These are merged automatically when POC= points to a path in this directory.

REPO_ROOT      := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))../..)
POC_C          := pocs/copyfail/poc.c
# Pinned to a known-vulnerable kernel version; override on the command line.
KERNEL_VERSION ?= 6.1.14

.PHONY: all run debug clean

all run:
	$(MAKE) -C "$(REPO_ROOT)" poc POC=$(POC_C) KERNEL_VERSION=$(KERNEL_VERSION) $(MAKEOVERRIDES)

debug:
	$(MAKE) -C "$(REPO_ROOT)" debug POC=$(POC_C) KERNEL_VERSION=$(KERNEL_VERSION) $(MAKEOVERRIDES)

clean:
	$(MAKE) -C "$(REPO_ROOT)" clean $(MAKEOVERRIDES)
