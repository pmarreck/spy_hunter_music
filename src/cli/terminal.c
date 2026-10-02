/* Terminal adapter, ported from the C board adapter src/native/sound.c
 * (MIT) into the C CLI on 2026-10-02 by Peter Marreck with Claude Opus 5.5
 * (claude-opus-5-5). Adds the kitty keyboard flag query. */
#include "terminal.h"
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static struct termios saved_terminal;
static int terminal_active;
static volatile sig_atomic_t interrupted;
static struct sigaction previous_signals[3];
static const int watched_signals[3] = {SIGINT, SIGTERM, SIGHUP};

static void interrupted_handler(int s) { (void)s; interrupted = 1; }

/* Kitty keyboard protocol flags 1|2|8: disambiguate, report press/repeat/
 * release, and encode every key as CSI-u so a held space has a release event.
 * Terminals without the protocol ignore both and keep sending plain bytes. */
static const char kitty_push[] = "\033[>11u", kitty_pop[] = "\033[<u";

static void terminal_send(const char *s, size_t n) {
	if (write(STDIN_FILENO, s, n) == (ssize_t)n) return;
	if (isatty(STDERR_FILENO) && write(STDERR_FILENO, s, n)) {}
}

int terminal_start(void) {
	if (terminal_active) return 0;
	if (!isatty(STDIN_FILENO)) return -1;
	if (tcgetattr(STDIN_FILENO, &saved_terminal)) return -1;
	struct termios t = saved_terminal;
	t.c_lflag &= ~(ICANON | ECHO);
	t.c_iflag &= ~IXON;
	t.c_cc[VMIN] = 0;
	t.c_cc[VTIME] = 0;
	if (tcsetattr(STDIN_FILENO, TCSANOW, &t)) return -1;
	terminal_active = 1;
	interrupted = 0;
	terminal_send(kitty_push, sizeof(kitty_push) - 1);
	struct sigaction action;
	memset(&action, 0, sizeof(action));
	action.sa_handler = interrupted_handler;
	sigemptyset(&action.sa_mask);
	for (int i = 0; i < 3; i++) sigaction(watched_signals[i], &action, &previous_signals[i]);
	return 0;
}

void terminal_stop(void) {
	if (!terminal_active) return;
	terminal_send(kitty_pop, sizeof(kitty_pop) - 1);
	while (tcsetattr(STDIN_FILENO, TCSANOW, &saved_terminal) < 0 && errno == EINTR) {}
	for (int i = 0; i < 3; i++) sigaction(watched_signals[i], &previous_signals[i], 0);
	terminal_active = 0;
}

int terminal_key(void) {
	if (interrupted) return 3;
	struct pollfd p = {STDIN_FILENO, POLLIN, 0};
	if (poll(&p, 1, 0) > 0) {
		unsigned char c;
		if (read(STDIN_FILENO, &c, 1) == 1) return c;
		if (p.revents & POLLHUP) return 4;
	}
	return -1;
}

/* True once `buf` holds a complete primary device-attributes reply
 * (ESC [ ? digits/semicolons c), which every terminal sends last. */
static int has_device_attributes(const unsigned char *buf, size_t n) {
	for (size_t i = 0; i + 3 < n; i++) {
		if (buf[i] != 033 || buf[i + 1] != '[' || buf[i + 2] != '?') continue;
		size_t j = i + 3;
		while (j < n && ((buf[j] >= '0' && buf[j] <= '9') || buf[j] == ';')) j++;
		if (j < n && buf[j] == 'c') return 1;
	}
	return 0;
}

static long long now_ms(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

size_t terminal_probe(unsigned char *out, size_t cap, int timeout_ms) {
	static const char query[] = "\033[?u\033[c";
	if (!terminal_active || !out || !cap) return 0;
	terminal_send(query, sizeof(query) - 1);
	size_t n = 0;
	long long deadline = now_ms() + timeout_ms;
	while (n < cap && !has_device_attributes(out, n)) {
		long long left = deadline - now_ms();
		if (left <= 0) break;
		struct pollfd p = {STDIN_FILENO, POLLIN, 0};
		int ready = poll(&p, 1, (int)left);
		if (ready < 0 && errno == EINTR) continue;
		if (ready <= 0) break;
		ssize_t r = read(STDIN_FILENO, out + n, cap - n);
		if (r <= 0) break;
		n += (size_t)r;
	}
	return n;
}
