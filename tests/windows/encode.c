/* Host-side check for the Windows console key encoder. The sequences are the
 * kitty CSI-u bytes the player already decodes, so hold-to-fire does not need
 * a second keyboard path. */
#include "terminal_keys.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void expect(const char *name, unsigned vk, int ctrl, int shift, int kind, const char *want) {
	unsigned char out[64];
	size_t n = windows_encode_key(vk, ctrl, shift, kind, out, sizeof out);
	if (n != strlen(want) || memcmp(out, want, n) != 0) {
		fprintf(stderr, "FAIL: %s\n", name);
		failures++;
	}
}

int main(void) {
	expect("space press", 0x20, 0, 0, 1, "\033[32u");
	expect("space repeat", 0x20, 0, 0, 2, "\033[32;1:2u");
	expect("space release", 0x20, 0, 0, 3, "\033[32;1:3u");
	expect("d press", 'D', 0, 0, 1, "\033[100u");
	expect("shift d", 'D', 0, 1, 1, "\033[100;2u");
	expect("p press", 'P', 0, 0, 1, "\033[112u");
	expect("shift p", 'P', 0, 1, 1, "\033[112;2u");
	expect("q press", 'Q', 0, 0, 1, "\033[113u");
	expect("shift q", 'Q', 0, 1, 1, "\033[113;2u");
	expect("ctrl c", 'C', 1, 0, 1, "\033[99;5u");
	expect("ctrl d", 'D', 1, 0, 1, "\033[100;5u");
	expect("ctrl q", 'Q', 1, 0, 1, "\033[113;5u");
	unsigned char tiny[4];
	memset(tiny, 0x5a, sizeof tiny);
	if (windows_encode_key(0x20, 0, 0, 1, tiny, sizeof tiny) != 0 || tiny[0] != 0x5a) {
		fprintf(stderr, "FAIL: short buffer must not write a partial sequence\n");
		failures++;
	}
	if (windows_encode_key(0x26, 0, 0, 1, tiny, sizeof tiny) != 0) {
		fprintf(stderr, "FAIL: unmapped key must encode nothing\n");
		failures++;
	}
	if (failures) return 1;
	printf("PASS: windows console keys encode as kitty CSI-u\n");
	return 0;
}
