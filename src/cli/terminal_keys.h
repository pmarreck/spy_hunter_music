/* Map a Windows virtual-key event to the kitty CSI-u bytes the player
 * already decodes. vk uses the Win32 codes (VK_SPACE = 0x20, letters A-Z).
 * kind is 1 press, 2 repeat, 3 release. Returns bytes written, or 0. */
#ifndef SPY_HUNTER_TERMINAL_KEYS_H
#define SPY_HUNTER_TERMINAL_KEYS_H

#include <stddef.h>

size_t windows_encode_key(unsigned vk, int ctrl, int shift, int kind, unsigned char *out, size_t cap);

#endif
