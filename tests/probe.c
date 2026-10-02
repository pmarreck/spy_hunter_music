/* PTY test of terminal_probe: the parent plays the terminal, reading the
 * kitty flags query plus device-attributes request and answering (or not). */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif
#include "../src/cli/terminal.h"

static int run_case(const char *reply, const char *expect) {
	size_t expect_len = strlen(expect);
	int master;
	pid_t child = forkpty(&master, 0, 0, 0);
	assert(child >= 0);
	if (!child) {
		unsigned char out[256];
		assert(terminal_start() == 0);
		size_t n = terminal_probe(out, sizeof out, 300);
		terminal_stop();
		if (n != expect_len || memcmp(out, expect, expect_len) != 0) {
			fprintf(stderr, "probe got %zu bytes, want %zu\n", n, expect_len);
			_exit(1);
		}
		_exit(0);
	}
	/* Wait for the query, then answer like the terminal under test. */
	char buf[512];
	size_t used = 0;
	ssize_t r;
	while (used < sizeof buf - 1 && (r = read(master, buf + used, sizeof buf - 1 - used)) > 0) {
		used += (size_t)r;
		buf[used] = 0;
		if (strstr(buf, "\033[c")) break;
	}
	if (!strstr(buf, "\033[?u\033[c")) { fprintf(stderr, "probe query not sent: %zu bytes\n", used); return 1; }
	if (reply && *reply) assert(write(master, reply, strlen(reply)) == (ssize_t)strlen(reply));
	int status;
	/* Drain output (the kitty pop) so the child never blocks on a full PTY. */
	while (waitpid(child, &status, WNOHANG) == 0) { if (read(master, buf, sizeof buf) <= 0) break; }
	waitpid(child, &status, 0);
	close(master);
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}

int main(void) {
	int failures = 0;
	failures += run_case("\033[?11u\033[?62;22c", "\033[?11u\033[?62;22c");
	failures += run_case("\033[?62;22c", "\033[?62;22c");
	failures += run_case("", ""); /* silent terminal: times out empty */
	if (failures) fprintf(stderr, "FAIL: %d probe case(s)\n", failures);
	return failures != 0;
}
