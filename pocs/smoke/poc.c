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
 *   9. AutoShield dummy hook, when the kernel module is loaded
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
static int n_pass = 0, n_fail = 0, n_skip = 0;

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

static void skip(const char *name, const char *detail)
{
    printf("[*]  %-42s  %s\n", name, detail ? detail : "skipped");
    n_skip++;
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

/* ══ optional check 9 – AutoShield dummy kernel hook ════════════════════════ */
static int read_text_file(const char *path, char *buf, size_t buf_len)
{
    int fd;
    ssize_t n;

    if (buf_len == 0) return -1;
    fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    n = read(fd, buf, buf_len - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    return 0;
}

static int write_text_file(const char *path, const char *text)
{
    int fd = open(path, O_WRONLY);
    size_t len = strlen(text);
    ssize_t n;

    if (fd < 0) return -1;
    n = write(fd, text, len);
    close(fd);
    return n == (ssize_t)len ? 0 : -1;
}

static int proc_field_is(const char *state, const char *key, const char *want)
{
    char needle[128];
    const char *line;
    const char *value;
    size_t want_len;

    snprintf(needle, sizeof(needle), "%s=", key);
    line = strstr(state, needle);
    if (!line) return 0;

    value = line + strlen(needle);
    want_len = strlen(want);
    return strncmp(value, want, want_len) == 0 &&
           (value[want_len] == '\n' || value[want_len] == '\0');
}

static void check_autoshield_dummy(void)
{
    const char *proc = "/proc/autoshield_dummy";
    char normal[1024];
    char attack[1024];
    int ok;

    if (access(proc, F_OK) != 0) {
        skip("AutoShield dummy hook", "not loaded; optional shield check skipped");
        return;
    }

    if (write_text_file(proc, "normal\n") != 0 ||
        read_text_file(proc, normal, sizeof(normal)) != 0) {
        report("AutoShield dummy hook", 0, "normal trigger failed");
        return;
    }

    if (write_text_file(proc, "attack\n") != 0 ||
        read_text_file(proc, attack, sizeof(attack)) != 0) {
        report("AutoShield dummy hook", 0, "attack trigger failed");
        return;
    }

    ok = proc_field_is(normal, "last_decision", "PASS") &&
         proc_field_is(normal, "last_result", "0") &&
         proc_field_is(normal, "vuln_reached", "1") &&
         proc_field_is(attack, "last_decision", "BLOCK") &&
         proc_field_is(attack, "last_result", "-13") &&
         proc_field_is(attack, "vuln_reached", "1");

    report("AutoShield dummy hook", ok,
           ok ? "normal PASS; attack BLOCK before dummy body"
              : "unexpected /proc/autoshield_dummy state");
    if (!ok) {
        info("    normal state:\n%s", normal);
        info("    attack state:\n%s", attack);
    }
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
    check_autoshield_dummy();

    puts("──────────────────────────────────────────────────────────────");
    if (n_fail == 0) {
        if (n_skip == 0) {
            printf("[+] All %d checks passed – environment ready for exploitation research\n",
                   n_pass);
        } else {
            printf("[+] All %d mandatory checks passed (%d optional skipped) – environment ready for exploitation research\n",
                   n_pass, n_skip);
        }
    } else {
        printf("[!] %d/%d checks passed – review failed items above\n",
               n_pass, n_pass + n_fail);
    }

    return n_fail > 0 ? 1 : 0;
}
