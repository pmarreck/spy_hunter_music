/* spy_hunter.h: C ABI of the Spy Hunter sound-board core (Zig).
 *
 * One emulated board per process: the Musashi 68000 core keeps its state in
 * globals, so these functions are not reentrant and must be called from one
 * thread. Buffers are pointer + byte/sample length; nothing is NUL-terminated
 * unless stated. The core performs no I/O and retains no caller pointers.
 */
#ifndef SPY_HUNTER_H
#define SPY_HUNTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return codes. */
#define SH_OK 0
#define SH_ERR_ARGUMENT (-1)   /* NULL pointer, wrong length or bad value */
#define SH_ERR_NOT_LOADED (-2) /* no ROM images loaded yet */
#define SH_ERR_RATE (-3)       /* sample rate outside 8000..192000 */
#define SH_ERR_ADMISSION (-4)  /* see sh_admission */

/* Why a ZIP was not admitted. */
#define SH_REASON_MALFORMED_ZIP 1
#define SH_REASON_UNSUPPORTED_ZIP 2
#define SH_REASON_DUPLICATE 3
#define SH_REASON_MISSING 4
#define SH_REASON_WRONG_SIZE 5
#define SH_REASON_DIGEST_MISMATCH 6
#define SH_REASON_CORRUPT 7

typedef struct {
	int reason;          /* SH_REASON_*, or 0 on success */
	size_t member_len;   /* bytes of member[] used (not NUL-terminated) */
	char member[64];     /* ZIP member name that failed, if any */
} sh_admission;

/* Admit a user-supplied spyhunt.zip held in memory: extract the seven sound
 * ROMs (legacy or current MAME names), verify sizes and historical SHA-1s,
 * load the board and reset it. Returns SH_OK or SH_ERR_ADMISSION with
 * details in *result (which may be NULL). The ZIP buffer is not retained. */
int sh_admit_zip(const uint8_t *zip, size_t zip_len, sh_admission *result);

/* Load raw board images (32768-byte interleaved 68000 ROM, 8192-byte Z80 ROM,
 * 32-byte gain PROM) without identity checks, then reset. For synthetic tests. */
int sh_load_images(const uint8_t *music, size_t music_len, const uint8_t *effects,
	size_t effects_len, const uint8_t *prom, size_t prom_len);

/* Run the ROM startup silently (SSIO self-test handshake, startup delays,
 * intro, then driving music) at the given rate, discarding the boot audio.
 * A different `initial_command` is delivered after driving is acknowledged. */
int sh_boot(int rate, unsigned int initial_command);

/* Send a four-bit music command: 0 death, 1 driving, 2 intro, 3 stop. */
void sh_command(unsigned int command);

/* Render `count` mono float samples. While paused, writes silence without
 * advancing emulation. Output is the raw board mix (roughly -1..1). */
int sh_render(float *out, size_t count, int rate);

/* Interactive session. Flags returned by the event functions: */
#define SH_FLAG_QUIT 1u    /* the user asked to quit */
#define SH_FLAG_KITTY 2u   /* kitty key events (with key releases) have arrived */
#define SH_FLAG_PAUSED 4u  /* playback is paused */
#define SH_FLAG_LEGACY 8u  /* a plain space byte arrived: no key releases */

/* Feed one terminal input byte (legacy key or part of a kitty CSI-u
 * sequence) at time `now` in seconds. */
unsigned int sh_key_byte(uint8_t byte, double now);

/* Direct events for hosts with real key-down/key-up (e.g. a browser). */
#define SH_EVENT_GUNS_DOWN 1
#define SH_EVENT_GUNS_UP 2
#define SH_EVENT_DEATH 3
#define SH_EVENT_PAUSE 4
unsigned int sh_event(int event, double now);

/* Advance timers (death-cue resume, legacy fire timeout) to `now`. */
unsigned int sh_tick(double now);

/* Reset session state (controller, key decoder, gun strobe). */
void sh_session_reset(void);

/* Apply output gain (volume * 4, clamped to -1..1) in place for playback. */
void sh_apply_gain(float *samples, size_t count, double volume);

/* Convert samples to 16-bit little-endian PCM with the same gain and clamp.
 * `out` must hold 2 * count bytes. Accumulates sum of squares and peak of the
 * gained values into *sum_squares and *peak when non-NULL. */
void sh_pcm16(const float *samples, size_t count, double volume, uint8_t *out,
	double *sum_squares, double *peak);

/* Write a 44-byte mono 16-bit PCM WAV header. `out_len` must be >= 44. */
int sh_wav_header(uint8_t *out, size_t out_len, uint32_t rate, uint64_t samples);

/* Hold-to-fire capability. `env` is a block of NUL-separated KEY=VALUE
 * entries (the process environment); `reply` holds the bytes the terminal
 * sent after `CSI ? u` `CSI c` (pass probed = 0 when no probe ran). */
#define SH_KEYS_UNKNOWN 0
#define SH_KEYS_RELEASES 1    /* key releases can reach the player */
#define SH_KEYS_NO_RELEASES 2 /* plain key bytes only: taps, no hold */
int sh_key_release_verdict(const uint8_t *env, size_t env_len, const uint8_t *reply, size_t reply_len, int probed);

/* `--tips`: what was detected and how to enable key releases here. Writes
 * at most out_cap bytes (not NUL-terminated) and returns the full length. */
#define SH_TIPS_JSON 1u
#define SH_TIPS_COLOR 2u
size_t sh_terminal_tips(const uint8_t *env, size_t env_len, const uint8_t *reply, size_t reply_len, int probed,
	unsigned int options, uint8_t *out, size_t out_cap);

/* Inspection. */
uint32_t sh_pc(void);
uint32_t sh_zpc(void);
uint64_t sh_dac_writes(void);
uint8_t sh_ay_register(unsigned int chip, unsigned int reg);
uint8_t sh_latch(unsigned int latch);

#ifdef __cplusplus
}
#endif
#endif
