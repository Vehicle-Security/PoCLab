# kernel-poc

Minimal Linux kernel + QEMU environment for reproducing kernel vulnerability PoCs.
Supports per-PoC kernel configuration so each exploit runs in the exact kernel
environment it needs without polluting the shared config.

---

## One-command quick start

### macOS (Apple Silicon / Intel)

```bash
# Prerequisites (one-time)
brew install qemu
# Docker Desktop must be installed and running

# From a fresh clone – the Docker image is built automatically on first run
make poc POC=pocs/smoke/poc.c
```

`make poc` handles everything: builds the Docker cross-compilation image
(first run only), downloads Linux and BusyBox sources, compiles the kernel,
builds the initramfs, compiles the PoC, and launches QEMU.

### Linux (x86-64)

```bash
# Install dependencies (one-time)
sudo apt install build-essential gcc flex bison bc cpio wget xz-utils \
    libelf-dev libssl-dev qemu-system-x86 musl-tools gdb

# From a fresh clone
make poc POC=pocs/smoke/poc.c
```

---

## Available PoCs

| PoC | Description |
|-----|-------------|
| `pocs/smoke/poc.c` | **Environment smoke test** – run first to validate the full pipeline. Checks kernel symbols, BPF, namespaces, debugfs, perf settings. |
| `pocs/copyfail/poc.c` | **CVE-2026-31431** – page-cache write without write permission via authencesn AEAD ESN out-of-bounds write. |
| `pocs/template/poc.c` | **Skeleton** – copy this to start a new PoC. |

---

## Directory layout

```
kernel-poc/
├── Makefile                      # main entry point (auto-detects ARCH)
├── build/
│   ├── Dockerfile                # cross-compilation toolchain image (macOS)
│   ├── config/
│   │   ├── kernel-common.config  # debug symbols, KASAN, BPF, namespaces, ...
│   │   ├── kernel-arm64.config   # PL011 UART, GIC, PSCI, ...
│   │   └── kernel-x86_64.config  # 8250 UART, ...
│   ├── rootfs/
│   │   └── etc/init.d/rcS        # init: mounts fs, runs /root/poc, drops to shell
│   └── scripts/
│       ├── build_kernel.sh       # fetch + configure + build Linux kernel
│       ├── build_rootfs.sh       # build static busybox initramfs
│       ├── pack_poc.sh           # compile PoC → inject into rootfs → repack
│       ├── run.sh                # launch QEMU
│       └── check_deps.sh         # dependency checker
├── pocs/
│   ├── smoke/poc.c               # end-to-end smoke test (start here)
│   ├── template/poc.c            # PoC skeleton
│   └── copyfail/
│       ├── poc.c                 # CVE-2026-31431
│       └── kernel.config         # AF_ALG AEAD options required by this PoC
├── src/                          # downloaded kernel / busybox sources (git-ignored)
└── out/                          # build artifacts (git-ignored)
    └── <arch>/
        ├── Image / bzImage       # kernel image passed to QEMU
        ├── vmlinux               # unstripped ELF for GDB
        └── rootfs.img            # initramfs cpio with PoC injected
```

---

## Per-PoC kernel configuration

Each PoC can ship its own `kernel.config` fragment alongside `poc.c`.
When you run `make poc POC=pocs/<name>/poc.c`, the build system:

1. Merges `build/config/kernel-common.config`
2. Merges `build/config/kernel-<arch>.config`
3. Merges `pocs/<name>/kernel.config` (if it exists)
4. Runs `olddefconfig` to resolve any conflicts
5. Rebuilds the kernel incrementally (only changed modules recompile)

This keeps each PoC's requirements isolated.

**Example** (`pocs/copyfail/kernel.config`):
```
CONFIG_CRYPTO_USER_API_AEAD=y
CONFIG_CRYPTO_AUTHENC=y
```

---

## Writing a new PoC

```bash
# 1. Copy the template directory (includes Makefile, poc.c)
cp -r pocs/template pocs/my-cve

# 2. Edit the PoC source
#    Fill in exploit() in pocs/my-cve/poc.c

# 3. Update the Makefile
#    Change POC_C to pocs/my-cve/poc.c in pocs/my-cve/Makefile

# 4. (Optional) Add PoC-specific kernel requirements
cat > pocs/my-cve/kernel.config <<'EOF'
CONFIG_SOME_SUBSYSTEM=y
EOF

# 5. Run – from the repo root OR from the PoC directory:
make poc POC=pocs/my-cve/poc.c   # from repo root
cd pocs/my-cve && make            # from PoC directory
```

Each PoC directory contains its own `Makefile` so you can `cd` into it and
run `make` directly without remembering the `POC=` argument.  Any root Makefile
variable can be overridden from the PoC directory:

```bash
cd pocs/my-cve
make SMEP=n SMAP=n        # disable mitigations
make KASLR=y              # enable KASLR
make debug                # launch with GDB server
```

The PoC binary is compiled statically, placed at `/root/poc` in the initramfs,
and executed automatically on boot as root.  A root shell follows for
interactive exploration.

---

## Make targets

| Target | Description |
|--------|-------------|
| `make poc POC=<path>` | **One-command:** build kernel + rootfs + PoC → launch QEMU |
| `make kernel` | Build kernel only |
| `make rootfs` | Build busybox initramfs only |
| `make run` | Launch QEMU (plain shell, no PoC) |
| `make debug` | Launch QEMU with GDB server on :1234 |
| `make docker-image` | Build the cross-compilation Docker image (macOS, explicit) |
| `make setup` | Check host dependencies |
| `make clean` | Remove built images for current ARCH |
| `make distclean` | Remove all sources and built artifacts |

---

## Overriding arch and kernel version

```bash
# ARCH is auto-detected from the host (arm64 on Apple Silicon, x86_64 otherwise)
make poc POC=pocs/smoke/poc.c ARCH=x86_64    # force x86_64
make poc POC=pocs/smoke/poc.c ARCH=arm64     # force arm64

# Use a different kernel version
make poc POC=pocs/smoke/poc.c KERNEL_VERSION=5.15.0
```

---

## Security mitigations

```bash
# Disable SMEP/SMAP for easier exploitation (x86_64 only)
make poc POC=pocs/my-cve/poc.c SMEP=n SMAP=n

# Enable KASLR for realistic testing (off by default)
make poc POC=pocs/my-cve/poc.c KASLR=y
```

arm64 always has PAN (≈SMAP) and PXN (≈SMEP) enabled at the hardware level.

---

## GDB kernel debugging

```bash
# Terminal 1: launch QEMU paused, waiting for GDB
make debug

# Terminal 2: attach
gdb out/arm64/vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```
