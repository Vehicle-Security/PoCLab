# pocs/<name>/Makefile – PoC entry point
#
# Instructions:
#   1. Copy this whole directory:  cp -r pocs/template pocs/my-cve
#   2. Edit poc.c:  fill in exploit()
#   3. Edit this Makefile:
#        a. Update the header comment
#        b. Change POC_C to  pocs/my-cve/poc.c
#        c. Set KERNEL_VERSION to the version that contains the bug
#   4. (Optional) add kernel.config with PoC-specific kernel options
#   5. Run:  make   (from this directory, or make poc POC=pocs/my-cve/poc.c from root)
#
# Variable overrides:
#   make SMEP=n SMAP=n       – disable x86_64 mitigations
#   make KASLR=y             – enable KASLR
#   make KERNEL_VERSION=X.Y.Z – switch kernel version

REPO_ROOT      := $(realpath $(dir $(lastword $(MAKEFILE_LIST)))../..)
POC_C          := pocs/template/poc.c   # ← change to pocs/<name>/poc.c
KERNEL_VERSION ?= 6.1.14               # ← set to the affected kernel version

.PHONY: all run debug clean

all run:
	$(MAKE) -C "$(REPO_ROOT)" poc POC=$(POC_C) KERNEL_VERSION=$(KERNEL_VERSION) $(MAKEOVERRIDES)

debug:
	$(MAKE) -C "$(REPO_ROOT)" debug POC=$(POC_C) KERNEL_VERSION=$(KERNEL_VERSION) $(MAKEOVERRIDES)

clean:
	$(MAKE) -C "$(REPO_ROOT)" clean $(MAKEOVERRIDES)
