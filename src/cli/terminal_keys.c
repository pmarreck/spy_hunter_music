/* Windows console keys become the same kitty CSI-u sequences the decoder
 * already tests. No Win32 calls, so the host can check the bytes directly. */
#include "terminal_keys.h"

#include <stdio.h>
#include <string.h>

size_t windows_encode_key(unsigned vk, int ctrl, int shift, int kind, unsigned char *out, size_t cap) {
	unsigned code = 0;
	if (vk == 0x20) code = 32;
	else if (vk >= 'A' && vk <= 'Z') code = (unsigned)('a' + (vk - 'A'));
	else return 0;
	if (code != 32 && code != 'c' && code != 'd' && code != 'p' && code != 'q') return 0;
	if (kind < 1 || kind > 3 || !out || cap == 0) return 0;
	int mods = 1 + (shift ? 1 : 0) + (ctrl ? 4 : 0);
	char tmp[32];
	int n;
	if (kind == 1 && mods == 1) n = snprintf(tmp, sizeof tmp, "\033[%uu", code);
	else if (kind == 1) n = snprintf(tmp, sizeof tmp, "\033[%u;%du", code, mods);
	else n = snprintf(tmp, sizeof tmp, "\033[%u;%d:%du", code, mods, kind);
	if (n < 0 || (size_t)n >= sizeof tmp || (size_t)n > cap) return 0;
	memcpy(out, tmp, (size_t)n);
	return (size_t)n;
}
