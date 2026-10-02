/* Drive the Windows console and waveOut adapters under Wine. Key events are
 * written into a private console, then read back through the player. */
#include "audio.h"
#include "terminal.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <string.h>

static int failures;
static HANDLE console_in;

static void fail(const char *message) {
	printf("FAIL: %s\n", message);
	failures++;
}

static int setup_console(void) {
	FreeConsole();
	if (!AllocConsole()) {
		fail("AllocConsole");
		return -1;
	}
	console_in = CreateFileA("CONIN$", GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
	if (console_in == INVALID_HANDLE_VALUE || !SetStdHandle(STD_INPUT_HANDLE, console_in)) {
		fail("console input handle");
		return -1;
	}
	return 0;
}

static int inject(WORD vk, int down, int ctrl, int shift) {
	INPUT_RECORD record;
	DWORD wrote = 0;
	memset(&record, 0, sizeof record);
	record.EventType = KEY_EVENT;
	record.Event.KeyEvent.bKeyDown = down ? TRUE : FALSE;
	record.Event.KeyEvent.wRepeatCount = 1;
	record.Event.KeyEvent.wVirtualKeyCode = vk;
	record.Event.KeyEvent.dwControlKeyState = (ctrl ? LEFT_CTRL_PRESSED : 0) | (shift ? SHIFT_PRESSED : 0);
	FlushConsoleInputBuffer(console_in);
	if (!WriteConsoleInputA(console_in, &record, 1, &wrote) || wrote != 1) return -1;
	return 0;
}

/* Collect the bytes of one injected event. A focus or menu record can sit
 * ahead of the key; keep reading while the console still has events. */
static int read_sequence(unsigned char *out, size_t cap) {
	size_t n = 0;
	for (int spins = 0; spins < 32; spins++) {
		int byte = terminal_key();
		if (byte >= 0) {
			if (n < cap) out[n++] = (unsigned char)byte;
			continue;
		}
		DWORD pending = 0;
		if (!GetNumberOfConsoleInputEvents(console_in, &pending) || pending == 0) break;
	}
	return (int)n;
}

static void expect_key(const char *name, WORD vk, int down, int ctrl, int shift, const char *want) {
	unsigned char got[64];
	int n;
	if (inject(vk, down, ctrl, shift) != 0) {
		fail(name);
		return;
	}
	n = read_sequence(got, sizeof got);
	if (n != (int)strlen(want) || memcmp(got, want, (size_t)n) != 0) {
		printf("FAIL: %s produced %d bytes\n", name, n);
		failures++;
	}
}

static void check_audio(void) {
	float samples[480];
	int done = 0;
	if (audio_open() != 0) {
		printf("FAIL: %s\n", audio_error());
		failures++;
		return;
	}
	for (int i = 0; i < 480; i++) samples[i] = (i & 1) ? 0.2f : -0.2f;
	if (audio_write(samples, 480, 1.0) != 0) {
		printf("FAIL: %s\n", audio_error());
		failures++;
		audio_close();
		return;
	}
	for (int i = 0; i < 200 && !done; i++) {
		if (audio_queued() == 0) done = 1;
		else audio_sleep();
	}
	if (!done) fail("waveOut buffer did not complete");
	audio_close();
}

int main(void) {
	unsigned char probe[32];
	size_t n;
	if (setup_console() != 0) return 1;
	if (terminal_start() != 0) {
		fail("terminal_start");
		return 1;
	}
	expect_key("space press", VK_SPACE, 1, 0, 0, "\033[32u");
	expect_key("space repeat", VK_SPACE, 1, 0, 0, "\033[32;1:2u");
	expect_key("space release", VK_SPACE, 0, 0, 0, "\033[32;1:3u");
	expect_key("d press", 'D', 1, 0, 0, "\033[100u");
	expect_key("d release", 'D', 0, 0, 0, "\033[100;1:3u");
	expect_key("shift d", 'D', 1, 0, 1, "\033[100;2u");
	expect_key("shift d release", 'D', 0, 0, 1, "\033[100;2:3u");
	expect_key("ctrl c", 'C', 1, 1, 0, "\033[99;5u");
	n = terminal_probe(probe, sizeof probe, 50);
	if (n < 6 || memcmp(probe, "\033[?11u", 6) != 0) fail("console probe");
	terminal_stop();
	check_audio();
	if (failures) return 1;
	printf("PASS: windows console key-up and waveOut playback\n");
	return 0;
}
