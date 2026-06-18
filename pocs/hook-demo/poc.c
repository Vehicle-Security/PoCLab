/*
 * AutoAgent PoCLab userspace driver
 *
 * This is the minimal userspace program that runs inside the QEMU VM.
 * The real action happens in the kernel module (autoagent.ko).
 * This program simply opens a few files to trigger the hook, then exits.
 *
 * The init script (poc.yaml → init_commands) loads the module before
 * running this binary and unloads it after.
 */
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

int main(void)
{
	int fd;

	/* Trigger the filp_open hook with benign opens */
	fd = open("/etc/hostname", O_RDONLY);
	if (fd >= 0) {
		char buf[64] = {};
		read(fd, buf, sizeof(buf) - 1);
		printf("hostname: %s\n", buf);
		close(fd);
	}

	/* This open should trigger the "blocked" log entry */
	fd = open("/etc/shadow", O_RDONLY);
	if (fd >= 0) {
		printf("shadow opened (unexpected)\n");
		close(fd);
	} else {
		printf("shadow blocked or absent — expected\n");
	}

	printf("done — check dmesg for autoagent hook events\n");
	return 0;
}
