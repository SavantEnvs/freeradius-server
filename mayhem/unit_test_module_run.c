/*
 * File-input driver for unit_test_module. The fuzz input is a whole server configuration; the server
 * only reads <confdir>/<name>.conf and refuses a configuration file or directory that is world-writable
 * (which is how a staged input may look). So: copy argv[1] to a private 0700 directory, run
 * unit_test_module on it with a canned request, remove the copy, and report the child's fate.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SRC_DIR
#  define SRC_DIR "/mayhem"
#endif

int main(int argc, char **argv)
{
	char dir[] = "/tmp/frfuzzXXXXXX";
	char path[sizeof(dir) + 16];
	char buf[65536];
	int in, out, status = 1;
	ssize_t n;
	pid_t pid;

	if (argc != 2) {
		fprintf(stderr, "usage: %s <config file>\n", argv[0]);
		return 2;
	}
	if (!mkdtemp(dir)) {
		perror("mkdtemp");
		return 2;
	}
	snprintf(path, sizeof(path), "%s/fuzz.conf", dir);

	in = open(argv[1], O_RDONLY);
	out = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
	if (in < 0 || out < 0) {
		perror("open");
		goto done;
	}
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		if (write(out, buf, (size_t)n) != n) {
			perror("write");
			goto done;
		}
	}
	close(in);
	close(out);

	pid = fork();
	if (pid < 0) {
		perror("fork");
		goto done;
	}
	if (pid == 0) {
		execl(SRC_DIR "/build/bin/local/unit_test_module", "unit_test_module",
		      "-d", dir, "-n", "fuzz",
		      "-i", SRC_DIR "/mayhem/unit_test_module-mined-a3ceda8/input.attrs",
		      "-r", "receipt", (char *)NULL);
		perror("execl");
		_exit(127);
	}
	if (waitpid(pid, &status, 0) < 0) {
		perror("waitpid");
		status = 1 << 8;
	}

done:
	unlink(path);
	rmdir(dir);
	if (WIFSIGNALED(status)) {
		signal(WTERMSIG(status), SIG_DFL);
		raise(WTERMSIG(status));
	}
	return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
