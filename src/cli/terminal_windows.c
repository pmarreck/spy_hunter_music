/* Console adapter for Windows. ReadConsoleInput supplies key-up, which the
 * shared encoder turns into the kitty CSI-u bytes the decoder already tests.
 * A canned probe reply marks releases without querying a terminal emulator. */
#include "terminal.h"
#include "terminal_keys.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <string.h>

static HANDLE input;
static DWORD saved_mode;
static int active;
static volatile LONG interrupted;
static unsigned char queue[256];
static size_t q_head, q_tail;
static int down[256];

static BOOL WINAPI ctrl_handler(DWORD type) {
	if (type == CTRL_C_EVENT || type == CTRL_BREAK_EVENT || type == CTRL_CLOSE_EVENT) {
		InterlockedExchange(&interrupted, 1);
		return TRUE;
	}
	return FALSE;
}

static void enqueue(const unsigned char *bytes, size_t n) {
	for (size_t i = 0; i < n; i++) {
		size_t next = (q_tail + 1) % sizeof queue;
		if (next == q_head) return;
		queue[q_tail] = bytes[i];
		q_tail = next;
	}
}

static int dequeue(void) {
	if (q_head == q_tail) return -1;
	int byte = queue[q_head];
	q_head = (q_head + 1) % sizeof queue;
	return byte;
}

int terminal_start(void) {
	if (active) return 0;
	input = GetStdHandle(STD_INPUT_HANDLE);
	if (input == INVALID_HANDLE_VALUE || input == NULL) return -1;
	if (!GetConsoleMode(input, &saved_mode)) return -1;
	/* No line buffering, echo, or processed Ctrl+C. Key-up arrives as an event. */
	if (!SetConsoleMode(input, ENABLE_EXTENDED_FLAGS)) return -1;
	SetConsoleCtrlHandler(ctrl_handler, TRUE);
	active = 1;
	InterlockedExchange(&interrupted, 0);
	q_head = q_tail = 0;
	memset(down, 0, sizeof down);
	return 0;
}

void terminal_stop(void) {
	if (!active) return;
	SetConsoleMode(input, saved_mode);
	SetConsoleCtrlHandler(ctrl_handler, FALSE);
	active = 0;
}

static void take_key(const KEY_EVENT_RECORD *key) {
	unsigned vk = key->wVirtualKeyCode;
	if (vk >= 256) return;
	int ctrl = (key->dwControlKeyState & (LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED)) != 0;
	int shift = (key->dwControlKeyState & SHIFT_PRESSED) != 0;
	unsigned char encoded[32];
	if (key->bKeyDown) {
		int kind = down[vk] ? 2 : 1;
		down[vk] = 1;
		unsigned reps = key->wRepeatCount ? key->wRepeatCount : 1;
		if (reps > 8) reps = 8;
		for (unsigned i = 0; i < reps; i++) {
			size_t n = windows_encode_key(vk, ctrl, shift, kind, encoded, sizeof encoded);
			enqueue(encoded, n);
			kind = 2;
		}
	} else if (down[vk]) {
		down[vk] = 0;
		size_t n = windows_encode_key(vk, ctrl, shift, 3, encoded, sizeof encoded);
		enqueue(encoded, n);
	}
}

int terminal_key(void) {
	if (InterlockedCompareExchange(&interrupted, 0, 0)) return 3;
	int queued = dequeue();
	if (queued >= 0) return queued;
	DWORD pending = 0;
	if (!GetNumberOfConsoleInputEvents(input, &pending) || pending == 0) return -1;
	INPUT_RECORD record;
	DWORD read = 0;
	if (!ReadConsoleInputA(input, &record, 1, &read) || read != 1) return -1;
	if (record.EventType == KEY_EVENT) take_key(&record.Event.KeyEvent);
	return dequeue();
}

size_t terminal_probe(unsigned char *out, size_t cap, int timeout_ms) {
	(void)timeout_ms;
	static const unsigned char canned[] = "\033[?11u\033[?62c";
	size_t n = sizeof canned - 1;
	if (n > cap) n = cap;
	memcpy(out, canned, n);
	return n;
}
