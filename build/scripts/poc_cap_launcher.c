/*
 * Small initramfs launcher for PoCs that must start as a non-root uid while
 * retaining a narrow capability required to reach the vulnerable path.
 */

#define _GNU_SOURCE

#include <grp.h>
#include <linux/capability.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#endif

#ifndef PR_CAP_AMBIENT_RAISE
#define PR_CAP_AMBIENT_RAISE 2
#endif

struct user_info {
    uid_t uid;
    gid_t gid;
};

static void die(const char *msg)
{
    perror(msg);
    exit(EXIT_FAILURE);
}

static int parse_user(const char *name, struct user_info *out)
{
    char line[512];
    FILE *fp = fopen("/etc/passwd", "r");

    if (!fp)
        return -1;

    while (fgets(line, sizeof(line), fp)) {
        char *save = NULL;
        char *user = strtok_r(line, ":", &save);
        char *unused = strtok_r(NULL, ":", &save);
        char *uid = strtok_r(NULL, ":", &save);
        char *gid = strtok_r(NULL, ":", &save);

        (void)unused;
        if (!user || !uid || !gid)
            continue;
        if (strcmp(user, name))
            continue;

        out->uid = (uid_t)strtoul(uid, NULL, 10);
        out->gid = (gid_t)strtoul(gid, NULL, 10);
        fclose(fp);
        return 0;
    }

    fclose(fp);
    return -1;
}

static int cap_from_name(const char *name)
{
    if (!strcmp(name, "cap_net_admin") || !strcmp(name, "net_admin"))
        return CAP_NET_ADMIN;

    fprintf(stderr, "unsupported capability: %s\n", name);
    exit(EXIT_FAILURE);
}

static void add_cap(struct __user_cap_data_struct data[2], int cap)
{
    unsigned int idx = (unsigned int)cap >> 5;
    unsigned int bit = 1U << ((unsigned int)cap & 31);

    data[idx].effective |= bit;
    data[idx].permitted |= bit;
    data[idx].inheritable |= bit;
}

static void apply_caps(const char *caps)
{
    char buf[256];
    char *save = NULL;
    char *tok;
    struct __user_cap_header_struct hdr = {
        .version = _LINUX_CAPABILITY_VERSION_3,
        .pid = 0,
    };
    struct __user_cap_data_struct data[2] = {};

    snprintf(buf, sizeof(buf), "%s", caps);

    for (tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        while (*tok == ' ' || *tok == '\t')
            tok++;
        add_cap(data, cap_from_name(tok));
    }

    if (syscall(SYS_capset, &hdr, data) < 0)
        die("capset");

    snprintf(buf, sizeof(buf), "%s", caps);
    save = NULL;
    for (tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        while (*tok == ' ' || *tok == '\t')
            tok++;
        if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_RAISE, cap_from_name(tok), 0, 0) < 0)
            die("PR_CAP_AMBIENT_RAISE");
    }
}

int main(int argc, char **argv)
{
    struct user_info user;
    char *child_argv[2];

    if (argc != 4) {
        fprintf(stderr, "usage: %s <user> <caps> <poc>\n", argv[0]);
        return EXIT_FAILURE;
    }

    if (parse_user(argv[1], &user) < 0) {
        fprintf(stderr, "unknown user: %s\n", argv[1]);
        return EXIT_FAILURE;
    }

    if (prctl(PR_SET_KEEPCAPS, 1, 0, 0, 0) < 0)
        die("PR_SET_KEEPCAPS");

    setgroups(0, NULL);
    if (setgid(user.gid) < 0)
        die("setgid");
    if (setuid(user.uid) < 0)
        die("setuid");

    apply_caps(argv[2]);

    if (prctl(PR_SET_KEEPCAPS, 0, 0, 0, 0) < 0)
        die("PR_SET_KEEPCAPS clear");

    child_argv[0] = argv[3];
    child_argv[1] = NULL;
    execv(argv[3], child_argv);
    die("execv");
}
