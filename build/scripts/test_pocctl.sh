#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pocctl-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/kernel-ok" "$TMP_DIR/service" "$TMP_DIR/template" "$TMP_DIR/bad-verify"
: > "$TMP_DIR/kernel-ok/poc.c"
: > "$TMP_DIR/service/poc.py"
: > "$TMP_DIR/template/poc.c"
: > "$TMP_DIR/template/kernel.config"
: > "$TMP_DIR/bad-verify/poc.c"

write_manifest() {
    local path="$1"; shift
    printf '%s\n' "$@" > "$path"
}

write_manifest "$TMP_DIR/kernel-ok/poc.yaml" \
    'apiVersion: poclab/v1' \
    'kind: PoC' \
    '' \
    'metadata:' \
    '  id: kernel-ok' \
    '  name: Kernel OK' \
    '' \
    'target:' \
    '  type: linux-kernel' \
    '  arch: x86_64' \
    '  kernel: "4.4.21"' \
    '' \
    'exploit:' \
    '  source: poc.c' \
    '' \
    'verify:' \
    '  type: log' \
    '  success_pattern: "ok|uid=0"' \
    '  fail_pattern: "failed"' \
    '' \
    'runtime:' \
    '  user: user' \
    '  smep: "false"'

write_manifest "$TMP_DIR/service/poc.yaml" \
    'apiVersion: poclab/v1' \
    'kind: PoC' \
    '' \
    'metadata:' \
    '  id: service' \
    '  name: Service PoC' \
    '' \
    'target:' \
    '  type: system-service' \
    '' \
    'exploit:' \
    '  source: poc.py' \
    '' \
    'verify:' \
    '  type: log' \
    '  success_pattern: "leaked"' \
    '  fail_pattern: "no leak"'

write_manifest "$TMP_DIR/template/poc.yaml" \
    'apiVersion: poclab/v1' \
    'kind: PoC' \
    '' \
    'metadata:' \
    '  id: your-id' \
    '  name: Template' \
    '' \
    'target:' \
    '  type: linux-kernel' \
    '  kernel: "6.1.14"' \
    '  kernel_config: kernel.config' \
    '' \
    'exploit:' \
    '  source: poc.c' \
    '' \
    'verify:' \
    '  type: log' \
    '  success_pattern: "pwned|root"' \
    '  fail_pattern: "EPERM"'

write_manifest "$TMP_DIR/bad-verify/poc.yaml" \
    'apiVersion: poclab/v1' \
    'kind: PoC' \
    '' \
    'metadata:' \
    '  id: bad-verify' \
    '  name: Bad Verify' \
    '' \
    'target:' \
    '  type: linux-kernel' \
    '' \
    'exploit:' \
    '  source: poc.c' \
    '' \
    'verify:' \
    '  type: json' \
    '  success_pattern: "ok"' \
    '  fail_pattern: "failed"'

run_pocctl() {
    POCLAB_POCS_DIR="$TMP_DIR" "$REPO_ROOT/pocctl" "$@"
}

list_output="$(run_pocctl list)"
printf '%s\n' "$list_output" | grep -E '^template[[:space:]]+linux-kernel[[:space:]]+6\.1\.14[[:space:]]+auto[[:space:]]+Template$' >/dev/null
printf '%s\n' "$list_output" | grep -E '^service[[:space:]]+system-service[[:space:]]+-[[:space:]]+auto[[:space:]]+Service PoC$' >/dev/null

if run_pocctl validate >"$TMP_DIR/validate.out" 2>"$TMP_DIR/validate.err"; then
    echo "expected invalid verify.type to fail validation" >&2
    exit 1
fi
grep "bad-verify: unsupported verify.type 'json'" "$TMP_DIR/validate.err" >/dev/null

rm -rf "$TMP_DIR/bad-verify"
run_pocctl validate >/dev/null

kernel_dry_run="$(run_pocctl run kernel-ok --dry-run)"
printf '%s\n' "$kernel_dry_run" | grep 'kernel=4.4.21  arch=x86_64  user=user (LPE)' >/dev/null
printf '%s\n' "$kernel_dry_run" | grep 'pack_poc.sh ".*/kernel-ok/poc.c"' >/dev/null
printf '%s\n' "$kernel_dry_run" | grep -- '-e POC_USER' >/dev/null

if run_pocctl run service --dry-run >"$TMP_DIR/service.out" 2>"$TMP_DIR/service.err"; then
    echo "expected unsupported target.type to fail before make" >&2
    exit 1
fi
grep "target.type 'system-service' not supported" "$TMP_DIR/service.err" >/dev/null
if grep 'pack_poc.sh ""' "$TMP_DIR/service.out" "$TMP_DIR/service.err" >/dev/null 2>&1; then
    echo "unsupported target.type reached make dry-run with an empty POC" >&2
    exit 1
fi

echo "[+] pocctl regression checks passed"
