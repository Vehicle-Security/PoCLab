# kernel-poc

Minimal Linux kernel + QEMU environment for reproducing kernel vulnerability
PoCs. Supports per-PoC manifests and kernel configuration so each exploit runs
in the exact kernel environment it needs without polluting shared defaults.

---

## One-command quick start

### macOS (Apple Silicon)

```bash
# Prerequisites (one-time)
brew install qemu
# Docker Desktop must be installed and running

# From a fresh clone - list PoCs, then run the smoke test
./pocctl list
./pocctl run smoke
```

### macOS (Intel) / Linux (x86-64)

The bundled `smoke` manifest currently pins `target.arch: arm64`, so x86-64
hosts should override the arch on the command line.

```bash
# macOS prerequisites (one-time)
brew install qemu
# Docker Desktop must be installed and running

# Linux dependencies (one-time)
sudo apt install build-essential gcc flex bison bc cpio wget xz-utils \
    libelf-dev libssl-dev qemu-system-x86 musl-tools gdb

# From a fresh clone
./pocctl list
./pocctl run smoke ARCH=x86_64
```

`pocctl run <id>` reads `pocs/<id>/poc.yaml`, builds the Docker
cross-compilation image (first run only on macOS), downloads Linux and BusyBox
sources, compiles the kernel, builds the initramfs, compiles the PoC, injects
it into the rootfs, and launches QEMU.

---

## Available PoCs

Use `./pocctl list` to print the PoCs discovered from `pocs/*/poc.yaml`,
including each manifest's `target.type`.

| ID | Source | Description |
|----|--------|-------------|
| `smoke` | `pocs/smoke/poc.c` | **Environment smoke test** - run first to validate the full pipeline. Checks kernel symbols, BPF, namespaces, debugfs, perf settings, and the optional AutoShield dummy hook when loaded. |
| `copyfail` | `pocs/copyfail/poc.c` | **CVE-2026-31431** - page-cache write without write permission via authencesn AEAD ESN out-of-bounds write. |
| `template` | `pocs/template/poc.c` | **Skeleton** - copy this to start a new PoC. |

---

## Directory layout

```
kernel-poc/
├── Makefile                      # low-level build entry point
├── pocctl                        # PoC controller: list/run/debug/clean by id
├── build/
│   ├── Dockerfile                # cross-compilation toolchain image (macOS)
│   ├── config/
│   │   ├── kernel-common.config  # debug symbols, KASAN, BPF, namespaces, ...
│   │   ├── kernel-arm64.config   # PL011 UART, GIC, PSCI, ...
│   │   └── kernel-x86_64.config  # 8250 UART, ...
│   ├── rootfs/
│   │   └── etc/init.d/rcS        # init: mounts fs, runs /root/poc, drops shell
│   └── scripts/
│       ├── build_kernel.sh       # fetch + configure + build Linux kernel
│       ├── build_rootfs.sh       # build static busybox initramfs
│       ├── pack_poc.sh           # compile PoC, inject into rootfs, repack
│       ├── run.sh                # launch QEMU
│       └── check_deps.sh         # dependency checker
├── pocs/
│   ├── smoke/
│   │   ├── poc.yaml              # metadata + runtime/kernel defaults
│   │   └── poc.c                 # end-to-end smoke test (start here)
│   ├── template/
│   │   ├── poc.yaml              # copy and edit for a new PoC
│   │   └── poc.c                 # PoC skeleton
│   └── copyfail/
│       ├── poc.yaml              # id, kernel version, source, runtime knobs
│       ├── poc.c                 # CVE-2026-31431
│       └── kernel.config         # AF_ALG AEAD options required by this PoC
├── src/                          # downloaded kernel / busybox sources
└── out/                          # build artifacts
    └── <arch>/
        ├── Image / bzImage       # kernel image passed to QEMU
        ├── vmlinux               # unstripped ELF for GDB
        └── rootfs.img            # initramfs cpio with PoC injected
```

---

## PoC manifests

Each runnable PoC lives under `pocs/<id>/` and is described by
`pocs/<id>/poc.yaml`. The directory name is the id passed to `pocctl`.

Important fields:

| Field | Meaning |
|-------|---------|
| `metadata.id` / `metadata.name` | Display metadata for `./pocctl list`; keep `metadata.id` equal to the directory name |
| `target.type` | Phase 1 supports `linux-kernel` |
| `target.arch` | Optional target arch: `arm64` or `x86_64` |
| `target.kernel` | Kernel version to build |
| `exploit.source` | PoC C source path, relative to `poc.yaml` |
| `runtime.user` | Optional non-root user for LPE PoCs |
| `runtime.kaslr/smep/smap` | Security mitigation defaults |
| `verify.type` | Output verifier type; currently `log` |
| `verify.success_pattern` | Extended regex that identifies successful PoC output |
| `verify.fail_pattern` | Extended regex that identifies failed or blocked PoC output |

Example:

```yaml
metadata:
  id: smoke
  name: Smoke Test

target:
  type: linux-kernel
  arch: arm64
  kernel: "6.1.14"

exploit:
  source: poc.c

runtime:
  kaslr: "false"
  smep: "true"
  smap: "true"
```

---

## Per-PoC kernel configuration

Each PoC can ship its own `kernel.config` fragment alongside `poc.c`. When you
run `./pocctl run <id>`, `pocctl` reads `pocs/<id>/poc.yaml`, forwards the PoC
source and runtime settings to `make`, and the build system:

1. Merges `build/config/kernel-common.config`
2. Merges `build/config/kernel-<arch>.config`
3. Merges `pocs/<id>/kernel.config` (if it exists)
4. Runs `olddefconfig` to resolve any conflicts
5. Rebuilds the kernel incrementally (only changed modules recompile)

This keeps each PoC's requirements isolated.

**Example** (`pocs/copyfail/kernel.config`):

```text
CONFIG_CRYPTO_USER_API_AEAD=y
CONFIG_CRYPTO_AUTHENC=y
```

---

## Writing a new PoC

```bash
# 1. Copy the template directory
cp -r pocs/template pocs/my-cve

# 2. Edit the PoC source
#    Fill in exploit() in pocs/my-cve/poc.c

# 3. Edit pocs/my-cve/poc.yaml
#    Set metadata.id/name, target.kernel, exploit.source, and runtime knobs.
#    Keep metadata.id equal to the directory name used by pocctl.

# 4. Optional: add PoC-specific kernel requirements
cat > pocs/my-cve/kernel.config <<'EOF'
CONFIG_SOME_SUBSYSTEM=y
EOF

# 5. Run from the repo root
./pocctl list
./pocctl run my-cve
```

`pocctl` accepts extra `KEY=VALUE` pairs and forwards them to the root
`Makefile`, so you can override manifest defaults without editing `poc.yaml`:

```bash
./pocctl run my-cve SMEP=n SMAP=n        # disable x86_64 mitigations
./pocctl run my-cve KASLR=y              # enable KASLR
./pocctl debug my-cve                    # launch with GDB server
```

The PoC binary is compiled statically, placed at `/root/poc` in the initramfs,
and executed automatically on boot. A root shell follows for interactive
exploration.

Manifest validation is available with `./pocctl validate`. For real PoCs,
`metadata.id` must match the `pocs/<id>` directory name, IDs must be unique,
referenced `exploit.source` / `target.kernel_config` files must exist, and
`verify.type` must be supported while `verify.success_pattern` /
`verify.fail_pattern` must be valid extended regexes.
`pocs/template` is the only directory allowed to keep placeholder metadata.

---

## pocctl commands

| Command | Description |
|---------|-------------|
| `./pocctl list` | List PoCs discovered from `pocs/*/poc.yaml` |
| `./pocctl validate` | Validate manifest references and verify patterns |
| `./pocctl run <id> [K=V ...]` | Build kernel + rootfs + PoC, inject it, and launch QEMU |
| `./pocctl shielded <id> [K=V ...]` | Run the PoC with AutoShield artifacts injected into the guest |
| `./pocctl debug <id> [K=V ...]` | Same as `run`, but starts QEMU with a GDB server on `:1234` |
| `./pocctl clean [<id>]` | Remove build artifacts for all, or for the PoC's configured arch |
| `./pocctl help` | Show command help |

`make` remains the lower-level implementation interface:

| Target | Description |
|--------|-------------|
| `make poc POC=<path>` | Build kernel + rootfs + PoC, then launch QEMU |
| `make poc-shielded POC=<path> SHIELD_MODE=kernel\|frida AUTOSHIELD_DIR=../AutoShield` | Export AutoShield artifacts from a local private checkout, inject them into rootfs, then launch QEMU |
| `make kernel` | Build kernel only |
| `make rootfs` | Build busybox initramfs only |
| `make run` | Launch QEMU (plain shell, no PoC) |
| `make debug` | Launch QEMU with GDB server on `:1234` |
| `make docker-image` | Build the cross-compilation Docker image (macOS, explicit) |
| `make setup` | Check host dependencies |
| `make check` | Run lightweight script syntax and manifest reference checks |
| `make clean` | Remove built images for current `ARCH` |
| `make distclean` | Remove all sources and built artifacts |

For automated smoke checks, add `EXIT_AFTER_POC=1` to power off the guest after
`/root/poc` exits instead of dropping into the interactive shell.
The same override works through `pocctl`, for example
`./pocctl shielded smoke SHIELD_MODE=kernel AUTOSHIELD_DIR=../AutoShield EXIT_AFTER_POC=1`.

## Optional AutoShield integration

PoCLab does not vendor or require AutoShield. The public baseline path remains:

```bash
./pocctl run smoke
make poc POC=pocs/smoke/poc.c
```

When a local private AutoShield checkout is available, use the shielded path:

```bash
./pocctl shielded smoke SHIELD_MODE=kernel AUTOSHIELD_DIR=../AutoShield
./pocctl shielded smoke SHIELD_MODE=frida AUTOSHIELD_DIR=../AutoShield
```

The integration contract is artifact-based:

1. PoCLab calls `make -C "$AUTOSHIELD_DIR" export SHIELD_MODE=<kernel|frida> OUT=<PoCLab/out/.../autoshield>`.
2. PoCLab copies the exported artifacts into `/root/autoshield` inside the initramfs.
3. `/etc/init.d/rcS` loads kernel modules before `/root/poc`, or runs `/root/poc` through the exported Frida wrapper.

Kernel mode expects at least one `*.ko` in the exported `kernel/` artifacts, and each module must match the selected `ARCH`. Frida mode expects `run-frida-hook.sh` or `agent.js` in the exported `frida/` artifacts.

For kernel mode, the guest loads modules from `/root/autoshield/kernel` before
running `/root/poc`, then unloads them after the PoC exits. Module files are
loaded in sorted order and unloaded in reverse sorted order, so multi-module
exports can express simple dependency ordering by filename.

The smoke path has been verified with the local AutoShield kernel export on:

| Arch | Kernel | Command |
|------|--------|---------|
| `arm64` | `6.1.14` | `./pocctl shielded smoke SHIELD_MODE=kernel AUTOSHIELD_DIR=../AutoShield EXIT_AFTER_POC=1` |
| `x86_64` | `4.4.21` | `ARCH=x86_64 KERNEL_VERSION=4.4.21 make poc-shielded POC=pocs/smoke/poc.c SHIELD_MODE=kernel AUTOSHIELD_DIR=../AutoShield EXIT_AFTER_POC=1` |

---

## Overriding arch and kernel version

```bash
# ARCH is read from poc.yaml when present, otherwise auto-detected.
# CLI KEY=VALUE overrides take precedence.
./pocctl run smoke ARCH=x86_64    # force x86_64
./pocctl run smoke ARCH=arm64     # force arm64

# Use a different kernel version
./pocctl run smoke KERNEL_VERSION=5.15.0
```

---

## Security mitigations

```bash
# Disable SMEP/SMAP for easier exploitation (x86_64 only)
./pocctl run my-cve SMEP=n SMAP=n

# Enable KASLR for realistic testing (off by default)
./pocctl run my-cve KASLR=y
```

arm64 always has PAN (similar to SMAP) and PXN (similar to SMEP) enabled at the
hardware level.

---

## GDB kernel debugging

```bash
# Terminal 1: launch QEMU paused, waiting for GDB
./pocctl debug smoke

# Terminal 2: attach
gdb out/arm64/vmlinux
(gdb) target remote :1234
(gdb) break start_kernel
(gdb) continue
```
