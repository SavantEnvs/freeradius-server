/*
 * File-input driver for unit_test_module. The fuzz input is a whole server configuration; the server
 * only reads <confdir>/<name>.conf and refuses a configuration file or directory that is world-writable
 * (which is how a staged input may look). So: copy argv[1] to <private 0700 dir>/<pid>.conf and exec
 * unit_test_module on it with a canned request, so the server is the traced root process. A copy cannot be
 * removed after the exec, so each run first removes the copies of processes that no longer exist.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef SRC_DIR
#  define SRC_DIR "/mayhem"
#endif

static void sweep(char const *dir)
{
	DIR *d = opendir(dir);
	struct dirent *e;
	char path[512];

	if (!d) return;
	while ((e = readdir(d)) != NULL) {
		char *end;
		long pid = strtol(e->d_name, &end, 10);

		if ((end == e->d_name) || strcmp(end, ".conf") != 0) continue;
		if ((kill((pid_t)pid, 0) < 0) && (errno == ESRCH)) {
			snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
			unlink(path);
		}
	}
	closedir(d);
}

int main(int argc, char **argv)
{
	char dir[64], path[128], name[32], buf[65536];
	int in, out;
	ssize_t n;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <config file>\n", argv[0]);
		return 2;
	}

	snprintf(dir, sizeof(dir), "/tmp/frfuzz-%u", (unsigned)getuid());
	if ((mkdir(dir, 0700) < 0) && (errno != EEXIST)) {
		perror("mkdir");
		return 2;
	}
	chmod(dir, 0700);
	sweep(dir);

	snprintf(name, sizeof(name), "%d", (int)getpid());
	snprintf(path, sizeof(path), "%s/%s.conf", dir, name);

	in = open(argv[1], O_RDONLY);
	out = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (in < 0 || out < 0) {
		perror("open");
		return 2;
	}
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		if (write(out, buf, (size_t)n) != n) {
			perror("write");
			return 2;
		}
	}
	close(in);
	close(out);

	execl(SRC_DIR "/build/bin/local/unit_test_module", "unit_test_module",
	      "-d", dir, "-n", name,
	      "-i", SRC_DIR "/mayhem/unit_test_module-mined-a3ceda8/input.attrs",
	      "-r", "receipt", (char *)NULL);
	perror("execl");
	return 127;
}
