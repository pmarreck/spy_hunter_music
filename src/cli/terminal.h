/* Terminal adapter for interactive playback: raw input, kitty keyboard
 * protocol enable/query/disable, and signal-safe restoration. */
#ifndef SPY_HUNTER_TERMINAL_H
#define SPY_HUNTER_TERMINAL_H

#include <stddef.h>

/* Enter raw mode and push kitty keyboard flags. Idempotent.
 * Returns 0, or -1 when stdin is not a terminal. */
int terminal_start(void);
/* Pop kitty flags and restore the saved terminal settings and signal
 * handlers. Idempotent; safe after a failed start. */
void terminal_stop(void);
/* Next input byte, 3 (Ctrl-C) after SIGINT/SIGTERM/SIGHUP, 4 on hangup, or -1. */
int terminal_key(void);
/* Probe the kitty keyboard protocol: send `CSI ? u` then `CSI c` and copy
 * the reply bytes into out until the device-attributes reply ends or
 * timeout_ms passes. Requires terminal_start(). Returns bytes read. */
size_t terminal_probe(unsigned char *out, size_t cap, int timeout_ms);

#endif
