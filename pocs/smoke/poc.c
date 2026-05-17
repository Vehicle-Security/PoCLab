/*
 * smoke – kernel-poc environment smoke test
 *
 * Validates the end-to-end build pipeline and confirms the kernel is
 * correctly configured for exploitation research.  Run this first after
 * cloning the repo to verify everything works before writing a real PoC.
 *
 * Checks performed:
 *   1. Running as root (uid=0)
 *   2. Kernel version readable via uname(2)
 *   3. /proc/kallsyms exposes symbols (KASLR=n, key exploit targets visible)
 *   4. BPF syscall available  (CONFIG_BPF_SYSCALL=y)
 *   5. User namespace creation (CONFIG_USER_NS=y)
 *   6. debugfs mounted at /sys/kernel/debug
 *   7. perf_event_paranoid set to -1 by init script
 *   8. dmesg rate limiting disabled (printk_ratelimit=0)
 *
 * No per-PoC kernel.config needed – all required options are already
 * in build/config/kernel-common.config.
 *
 * Usage:  make poc POC=pocs/smoke/poc.c
 * Expect: all checks pass, exit 0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

/* ── BPF syscall number fallback ─────────────────────────────────────────── */
#ifndef __NR_bpf
# if defined(__x86_64__)
#  define __NR_bpf 321
# elif defined(__aarch64__)
#  define __NR_bpf 280
# else
#  error "Unsupported architecture – add __NR_bpf manually"
# endif
#endif

/* ── output helpers ──────────────────────────────────────────────────────── */
#define info(fmt, ...) fprintf(stdout, "[*] " fmt "\n", ##__VA_ARGS__)

/* ── check accounting ────────────────────────────────────────────────────── */
static int n_pass = 0, n_fail = 0;

static void report(const char *name, int passed, const char *detail)
{
    if (passed) {
        printf("[+]  %-42s  %s\n", name, detail ? detail : "");
        n_pass++;
    } else {
        printf("[-]  %-42s  %s\n", name, detail ? detail : "");
        n_fail++;
    }
}

/* ══ check 1 – root ═════════════════════════════════════════════════════════ */
static void check_root(void)
{
    uid_t uid = getuid();
    char buf[32];
    snprintf(buf, sizeof(buf), "uid=%d", uid);
    report("Running as root (uid=0)", uid == 0, buf);
}

/* ══ check 2 – kernel version ═══════════════════════════════════════════════ */
static void check_uname(void)
{
    struct utsname u;
    if (uname(&u) != 0) {
        report("uname(2) succeeds", 0, strerror(errno));
        return;
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "%s %s", u.release, u.machine);
    report("uname(2) succeeds", 1, buf);
}

/* ══ check 3 – /proc/kallsyms visible (KASLR=n) ════════════════════════════ */
static unsigned long kallsyms_find(const char *target)
{
    FILE *f = fopen("/proc/kallsyms", "r");
    if (!f) return 0;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        unsigned long addr;
        char type, name[256];
        if (sscanf(line, "%lx %c %255s", &addr, &type, name) >= 3 &&
            strcmp(name, target) == 0) {
            fclose(f);
            return addr;
        }
    }
    fclose(f);
    return 0;
}

static void check_kallsyms(void)
{
    unsigned long cc  = kallsyms_find("commit_creds");
    unsigned long pkc = kallsyms_find("prepare_kernel_cred");

    if (cc == 0) {
        report("/proc/kallsyms (KASLR=n, symbols visible)", 0,
               "commit_creds not found – KASLR may be enabled");
        return;
    }
    char buf[128];
    snprintf(buf, sizeof(buf), "commit_creds=0x%lx", cc);
    report("/proc/kallsyms (KASLR=n, symbols visible)", 1, buf);
    info("    prepare_kernel_cred = 0x%lx  (key ret2usr target)", pkc);
}

/* ══ check 4 – BPF_MAP_CREATE ═══════════════════════════════════════════════ */
static void check_bpf(void)
{
    struct {
        uint32_t map_type;    /* BPF_MAP_TYPE_ARRAY = 2 */
        uint32_t key_size;
        uint32_t value_size;
        uint32_t max_entries;
        uint32_t map_flags;
    } attr;
    memset(&attr, 0, sizeof(attr));
    attr.map_type    = 2;
    attr.key_size    = 4;
    attr.value_size  = 8;
    attr.max_entries = 1;

    int fd = (int)syscall(__NR_bpf, 0 /* BPF_MAP_CREATE */, &attr, sizeof(attr));
    if (fd >= 0) {
        close(fd);
        report("BPF_MAP_CREATE (CONFIG_BPF_SYSCALL=y)", 1, "BPF_MAP_TYPE_ARRAY OK");
    } else {
        report("BPF_MAP_CREATE (CONFIG_BPF_SYSCALL=y)", 0, strerror(errno));
    }
}

/* ══ check 5 – user namespace ═══════════════════════════════════════════════ */
static void check_userns(void)
{
    pid_t pid = fork();
    if (pid < 0) { report("User namespace (CONFIG_USER_NS=y)", 0, strerror(errno)); return; }
    if (pid == 0) _exit(unshare(CLONE_NEWUSER) == 0 ? 0 : 1);
    int status = 0;
    waitpid(pid, &status, 0);
    int ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    report("User namespace (CONFIG_USER_NS=y)", ok, ok ? "CLONE_NEWUSER OK" : "unshare failed");
}

/* ══ check 6 – debugfs ══════════════════════════════════════════════════════ */
static void check_debugfs(void)
{
    int fd = open("/sys/kernel/debug", O_RDONLY | O_DIRECTORY);
    report("debugfs mounted (/sys/kernel/debug)", fd >= 0,
           fd >= 0 ? "accessible" : strerror(errno));
    if (fd >= 0) close(fd);
}

/* ══ check 7 – perf_event_paranoid ═════════════════════════════════════════ */
static void check_perf(void)
{
    FILE *f = fopen("/proc/sys/kernel/perf_event_paranoid", "r");
    if (!f) { report("perf_event_paranoid = -1", 0, "file not found"); return; }
    int v = 3;
    fscanf(f, "%d", &v);
    fclose(f);
    char buf[32];
    snprintf(buf, sizeof(buf), "value=%d (want -1)", v);
    report("perf_event_paranoid = -1", v <= 0, buf);
}

/* ══ check 8 – dmesg rate limit ═════════════════════════════════════════════ */
static void check_dmesg(void)
{
    FILE *f = fopen("/proc/sys/kernel/printk_ratelimit", "r");
    if (!f) { report("printk_ratelimit = 0", 0, "file not found"); return; }
    int v = 1;
    fscanf(f, "%d", &v);
    fclose(f);
    char buf[32];
    snprintf(buf, sizeof(buf), "value=%d (want 0)", v);
    report("printk_ratelimit = 0 (dmesg not throttled)", v == 0, buf);
}

/* ══ main ════════════════════════════════════════════════════════════════════ */
int main(void)
{
    info("kernel-poc smoke test  pid=%d uid=%d", getpid(), getuid());
    puts("──────────────────────────────────────────────────────────────");

    check_root();
    check_uname();
    check_kallsyms();
    check_bpf();
    check_userns();
    check_debugfs();
    check_perf();
    check_dmesg();

    puts("──────────────────────────────────────────────────────────────");
    if (n_fail == 0)
        printf("[+] All %d checks passed – environment ready for exploitation research\n",
               n_pass);
    else
        printf("[!] %d/%d checks passed – review failed items above\n",
               n_pass, n_pass + n_fail);

    return n_fail > 0 ? 1 : 0;
}
