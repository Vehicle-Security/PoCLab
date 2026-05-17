/*
 * kernel-poc template
 *
 * Replace the exploit() body with your vulnerability reproduction code.
 * Compile:  make poc POC=pocs/template/poc.c
 * Run:      the binary executes automatically on boot as root (uid=0)
 *
 * Common headers for kernel exploit work are pre-included below.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <unistd.h>

/* ── helpers ─────────────────────────────────────────────────────────────── */

#define info(fmt, ...)  fprintf(stdout, "[*] " fmt "\n", ##__VA_ARGS__)
#define ok(fmt, ...)    fprintf(stdout, "[+] " fmt "\n", ##__VA_ARGS__)
#define err(fmt, ...)   fprintf(stderr, "[-] " fmt "\n", ##__VA_ARGS__)
#define die(fmt, ...)   do { err(fmt, ##__VA_ARGS__); exit(EXIT_FAILURE); } while (0)

static void check_root(void)
{
    if (getuid() == 0)
        ok("Got root!");
    else
        err("Still uid=%d – exploit did not work", getuid());
}

/* ── exploit body ────────────────────────────────────────────────────────── */

static void exploit(void)
{
    struct utsname u;
    uname(&u);
    info("Kernel: %s %s", u.sysname, u.release);
    info("Starting exploit ...");

    /*
     * TODO: implement exploit here
     *
     * Useful starting points:
     *   int fd = open("/dev/target_dev", O_RDWR);
     *   if (fd < 0) die("open: %s", strerror(errno));
     *
     *   unsigned long addr = kallsyms_find("commit_creds");
     *   ...
     */

    check_root();
}

/* ── main ────────────────────────────────────────────────────────────────── */

int main(void)
{
    info("kernel-poc  pid=%d uid=%d", getpid(), getuid());

    exploit();

    if (getuid() == 0) {
        char *argv[] = { "/bin/sh", NULL };
        execve("/bin/sh", argv, NULL);
    }

    return 0;
}
