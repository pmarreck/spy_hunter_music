/* spy-hunter-music: C CLI over the Zig core's C ABI (include/spy_hunter.h).
 * Ported from src/main.lua, src/cli.lua, src/archive.lua, src/render.lua and
 * src/session.lua on 2026-10-02 by Peter Marreck with Claude Opus 5.5
 * (claude-opus-5-5). All I/O lives here; the core is pure. */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <SDL.h>

#include "spy_hunter.h"
#include "terminal.h"

#define VERSION "0.2.0"
#define RATE 48000
#define MAX_ZIP_BYTES (16u * 1024u * 1024u)
#define RENDER_CHUNK 4800
#define PLAY_CHUNK 480
#define QUEUE_TARGET 2400        /* samples kept queued: 50 ms at 48 kHz */
#define PROBE_TIMEOUT_MS 300     /* wait for the terminal's device-attributes reply */
#define MAX_ENV_BYTES (256u * 1024u)

#if defined(__APPLE__)
#define PLATFORM "macos"
#elif defined(__linux__)
#define PLATFORM "linux"
#else
#define PLATFORM "unknown"
#endif
#if defined(__aarch64__)
#define ARCH "aarch64"
#elif defined(__x86_64__)
#define ARCH "x86_64"
#else
#define ARCH "unknown"
#endif

static const char help_text[] =
	"spy-hunter-music " VERSION "\n"
	"Original Spy Hunter arcade sound-ROM player. Linux and macOS.\n"
	"\n"
	"Usage: spy-hunter-music [play|render|inspect] [OPTIONS]\n"
	"\n"
	"  --rom PATH       Locally owned spyhunt.zip (or SPY_HUNTER_ROM).\n"
	"                   '-' or '@stdin' reads a ZIP, capped at 16 MiB.\n"
	"  --volume N       Output gain from 0 to 1 (default 0.65).\n"
	"  --command N      Initial music-board command, 0..15 (default 1).\n"
	"  --seconds N      Render duration, >0 and <=3600 (default 20).\n"
	"  -o, --output PATH  WAV destination for render; '-' or '@stdout' for stdout.\n"
	"  --json           Structured inspection or render statistics.\n"
	"  --simple, --ascii, --no-ansi, --no-color  Plain text display.\n"
	"  -h, --help       This help.\n"
	"  --about          One-line description, version and platform.\n"
	"  --tips           Check this terminal for hold-to-fire (key releases) and\n"
	"                   explain how to enable it here. Honors --json.\n"
	"\n"
	"Keyboard: space fires machine guns (hold to keep firing where the\n"
	"terminal reports key releases); d plays the death cue and resumes music;\n"
	"p pauses and resumes. Quit with q/Q, uppercase D, or Ctrl-C/Q/D.\n"
	"\n"
	"No ROM downloads. Only the sound boards run; no game/video emulation.\n"
	"Output files are never overwritten. Music and ROM assets stay private.\n";

typedef enum { MODE_PLAY, MODE_RENDER, MODE_INSPECT, MODE_HELP, MODE_ABOUT, MODE_TIPS } mode_t_;

typedef struct {
	mode_t_ mode;
	const char *rom;
	const char *output;
	double seconds, volume;
	long command;
	int json, simple;
} options;

static void die(const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	fputs("spy-hunter-music: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	exit(1);
}

static int parse_number(const char *s, double *out) {
	char *end;
	errno = 0;
	double v = strtod(s, &end);
	if (errno || end == s || *end || !isfinite(v)) return -1;
	*out = v;
	return 0;
}

/* Parse arguments; returns NULL or an error message. Later options override
 * earlier ones; --name=value is accepted; `--` takes exactly one ROM path. */
static const char *parse(int argc, char **argv, options *o) {
	const char *seconds = "20", *command = "1", *volume = "0.65";
	*o = (options){MODE_PLAY, NULL, NULL, 20, 0.65, 1, 0, 0};
	static char key[64];
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i], *value = NULL;
		const char *eq = strchr(a, '=');
		if (a[0] == '-' && a[1] == '-' && eq && (size_t)(eq - a) < sizeof(key)) {
			memcpy(key, a, (size_t)(eq - a));
			key[eq - a] = 0;
			a = key;
			value = eq + 1;
		}
		int takes_value = !strcmp(a, "--rom") || !strcmp(a, "-o") || !strcmp(a, "--output") || !strcmp(a, "--seconds") ||
			!strcmp(a, "--command") || !strcmp(a, "--volume");
		if (value && !takes_value) {
			static char message[160];
			snprintf(message, sizeof message, "Unknown option: %.120s", argv[i]);
			return message;
		}
		if (!strcmp(a, "--")) {
			if (i + 2 != argc) return "After --, provide exactly one ROM path";
			o->rom = argv[i + 1];
			break;
		} else if (!strcmp(a, "play")) o->mode = MODE_PLAY;
		else if (!strcmp(a, "render")) o->mode = MODE_RENDER;
		else if (!strcmp(a, "inspect")) o->mode = MODE_INSPECT;
		else if (!strcmp(a, "-h") || !strcmp(a, "--help")) o->mode = MODE_HELP;
		else if (!strcmp(a, "--about")) o->mode = MODE_ABOUT;
		else if (!strcmp(a, "--tips")) o->mode = MODE_TIPS;
		else if (!strcmp(a, "--json")) o->json = 1;
		else if (!strcmp(a, "--simple") || !strcmp(a, "--ascii") || !strcmp(a, "--no-color") || !strcmp(a, "--no-ansi")) o->simple = 1;
		else if (takes_value) {
			if (!value) {
				if (i + 1 >= argc) {
					static char message[96];
					snprintf(message, sizeof message, "Missing value for %s", a);
					return message;
				}
				value = argv[++i];
			}
			if (!strcmp(a, "--rom")) o->rom = value;
			else if (!strcmp(a, "-o") || !strcmp(a, "--output")) o->output = value;
			else if (!strcmp(a, "--seconds")) seconds = value;
			else if (!strcmp(a, "--command")) command = value;
			else volume = value;
		} else {
			static char message[160];
			snprintf(message, sizeof message, "Unknown option: %.120s", a);
			return message;
		}
	}
	double c;
	if (parse_number(seconds, &o->seconds)) return "Invalid seconds";
	if (parse_number(command, &c)) return "Invalid command";
	if (parse_number(volume, &o->volume)) return "Invalid volume";
	if (o->seconds < 1.0 / RATE || o->seconds > 3600) return "Seconds must be at least one sample and at most 3600";
	if (c < 0 || c > 15 || c != floor(c)) return "Command must be an integer in [0,15]";
	o->command = (long)c;
	if (o->volume < 0 || o->volume > 1) return "Volume must be in [0,1]";
	if (o->mode == MODE_RENDER && !o->output) return "render requires --output PATH";
	return NULL;
}

static int is_stdin(const char *p) { return !strcmp(p, "-") || !strcmp(p, "@stdin"); }
static int is_stdout(const char *p) { return !strcmp(p, "-") || !strcmp(p, "@stdout"); }

/* Read a whole stream up to MAX_ZIP_BYTES. */
static uint8_t *read_stream(FILE *f, const char *what, size_t *len) {
	uint8_t *buf = malloc(MAX_ZIP_BYTES + 1);
	if (!buf) die("Out of memory");
	size_t n = fread(buf, 1, MAX_ZIP_BYTES + 1, f);
	if (ferror(f)) die("Cannot read %s", what);
	if (n > MAX_ZIP_BYTES) die("%s exceeds the 16 MiB ZIP limit", what);
	*len = n;
	return buf;
}

/* Find the ROM archive: SPY_HUNTER_ROM, the project-local copy, Peter's NAS,
 * then ~/ROMs. An explicit --rom is never replaced. */
static const char *default_rom(void) {
	static char paths[3][4096];
	const char *home = getenv("HOME");
	if (!home) home = ".";
	const char *env = getenv("SPY_HUNTER_ROM");
	snprintf(paths[0], sizeof paths[0], "%s/Code/spy_hunter_music/local/spyhunt.zip", home);
	snprintf(paths[1], sizeof paths[1], "%s", "/mnt/Fileserver/Emulation/ROMs/MAME/ROMs/spyhunt.zip");
	snprintf(paths[2], sizeof paths[2], "%s/ROMs/spyhunt.zip", home);
	if (env && *env && access(env, R_OK) == 0) return env;
	for (int i = 0; i < 3; i++) if (access(paths[i], R_OK) == 0) return paths[i];
	die("No spyhunt.zip found. Set SPY_HUNTER_ROM or pass --rom PATH. ROMs are never downloaded.");
	return NULL;
}

static const char *reason_text(int reason) {
	switch (reason) {
	case SH_REASON_MALFORMED_ZIP: return "Not a readable ZIP archive";
	case SH_REASON_UNSUPPORTED_ZIP: return "Unsupported ZIP feature (ZIP64, encryption or compression method) at";
	case SH_REASON_DUPLICATE: return "Duplicate ROM member";
	case SH_REASON_MISSING: return "Missing ROM";
	case SH_REASON_WRONG_SIZE: return "Wrong size";
	case SH_REASON_DIGEST_MISMATCH: return "ROM SHA-1 mismatch";
	case SH_REASON_CORRUPT: return "Corrupt ZIP member";
	default: return "ROM admission failed";
	}
}

static void admit(const char *path) {
	size_t len;
	uint8_t *zip;
	if (is_stdin(path)) zip = read_stream(stdin, "stdin ZIP", &len);
	else {
		FILE *f = fopen(path, "rb");
		if (!f) die("Cannot open ROM archive %s: %s", path, strerror(errno));
		zip = read_stream(f, path, &len);
		fclose(f);
	}
	sh_admission result;
	int status = sh_admit_zip(zip, len, &result);
	free(zip);
	if (status != SH_OK) {
		if (result.reason == SH_REASON_MALFORMED_ZIP) die("%s: %s", reason_text(result.reason), path);
		die("%s: %.*s", reason_text(result.reason), (int)result.member_len, result.member);
	}
}

static void json_string(FILE *f, const char *s) {
	fputc('"', f);
	for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
		if (*p == '"' || *p == '\\') fprintf(f, "\\%c", *p);
		else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
		else fputc(*p, f);
	}
	fputc('"', f);
}

static void inspect(const options *o, const char *rom) {
	if (o->json) {
		printf("{\"version\":\"" VERSION "\",\"rom\":");
		json_string(stdout, rom);
		printf(",\"verified\":true,\"music\":{\"cpu\":\"68000\",\"clock_hz\":8000000,\"rom_bytes\":32768,\"pc\":%u,\"dac_writes\":%llu},"
			"\"effects\":{\"cpu\":\"Z80\",\"clock_hz\":2000000,\"rom_bytes\":8192,\"pc\":%u,\"chips\":\"2 x AY-3-8910\"}}\n",
			sh_pc(), (unsigned long long)sh_dac_writes(), sh_zpc());
	} else {
		puts("ROM SHA-1 checks passed. Music: 68000, 8 MHz, 32 KiB ROM. Effects: Z80, 2 MHz, dual AY-3-8910.");
		puts("Original sound programs booted successfully.");
	}
}

static void write_all(int fd, const void *data, size_t n) {
	const uint8_t *p = data;
	while (n) {
		ssize_t w = write(fd, p, n);
		if (w < 0 && errno == EINTR) continue;
		if (w <= 0) die("WAV write failed: %s", strerror(errno));
		p += w;
		n -= (size_t)w;
	}
}

static void render(const options *o) {
	int stream = is_stdout(o->output);
	int fd = stream ? STDOUT_FILENO : open(o->output, O_WRONLY | O_CREAT | O_EXCL, 0644);
	if (fd < 0) die("Cannot create output (already exists or unavailable): %s", o->output);
	uint64_t count = (uint64_t)floor(o->seconds * RATE);
	uint8_t header[44];
	if (count < 1 || sh_wav_header(header, sizeof header, RATE, count) != SH_OK) die("Duration must contain at least one sample");
	write_all(fd, header, sizeof header);
	static float samples[RENDER_CHUNK];
	static uint8_t pcm[2 * RENDER_CHUNK];
	double energy = 0, peak = 0;
	for (uint64_t done = 0; done < count;) {
		size_t n = count - done < RENDER_CHUNK ? (size_t)(count - done) : RENDER_CHUNK;
		if (sh_render(samples, n, RATE) != SH_OK) die("Sound render failed");
		sh_pcm16(samples, n, o->volume, pcm, &energy, &peak);
		write_all(fd, pcm, 2 * n);
		done += n;
	}
	if (!stream && close(fd) != 0) die("WAV close failed");
	double rms = sqrt(energy / (double)count);
	if (o->json) {
		fprintf(stderr, "{\"samples\":%llu,\"seconds\":%.17g,\"rate\":%d,\"peak\":%.17g,\"rms\":%.17g,\"output\":",
			(unsigned long long)count, (double)count / RATE, RATE, peak, rms);
		json_string(stderr, o->output);
		fputs("}\n", stderr);
	} else fprintf(stderr, "Rendered %.2fs, %llu samples, peak %.3f, RMS %.3f -> %s\n", (double)count / RATE,
		(unsigned long long)count, peak, rms, o->output);
}

static void status_line(const char *message) { fprintf(stderr, "%s\r\n", message); }

extern char **environ;

/* The process environment as NUL-separated KEY=VALUE entries for the core. */
static size_t environment_block(uint8_t *out, size_t cap) {
	size_t n = 0;
	for (char **e = environ; e && *e; e++) {
		size_t len = strlen(*e);
		if (n + len + 1 > cap) break;
		memcpy(out + n, *e, len);
		out[n + len] = 0;
		n += len + 1;
	}
	return n;
}

static const char no_release_warning[] =
	"Hold-to-fire is unavailable here: this terminal setup sends no key releases, so each space press fires two shots. "
	"Run spy-hunter-music --tips for how to fix it.";

static void warn(int color, const char *message) {
	fprintf(stderr, "%s%s%s\r\n", color ? "\033[33m" : "", message, color ? "\033[0m" : "");
}

static void play(const options *o) {
	if (!isatty(STDIN_FILENO)) die("Interactive input requires a terminal. Use render for noninteractive output.");
	if (SDL_Init(SDL_INIT_AUDIO) != 0) die("SDL audio: %s", SDL_GetError());
	SDL_AudioSpec want = {0};
	want.freq = RATE;
	want.format = AUDIO_F32SYS;
	want.channels = 1;
	want.samples = 1024;
	SDL_AudioDeviceID device = SDL_OpenAudioDevice(NULL, 0, &want, NULL, 0);
	if (!device) {
		const char *e = SDL_GetError();
		SDL_Quit();
		die("Audio device: %s", e);
	}
	SDL_PauseAudioDevice(device, 0);
	int tty = isatty(STDERR_FILENO) && !o->simple;
	fprintf(stderr, "%sPeter Gunn | original arcade sound code%s\nSpace: machine guns  d: death cue  p: pause  q/Ctrl-C: quit\n",
		tty ? "\033[1;36m" : "", tty ? "\033[0m" : "");
	if (terminal_start() != 0) {
		SDL_CloseAudioDevice(device);
		SDL_Quit();
		die("Interactive input requires a terminal. Use render for noninteractive output.");
	}
	sh_session_reset();
	/* Warn up front when the probe or environment rules out key releases;
	 * the first real space press confirms either way. */
	static uint8_t env[MAX_ENV_BYTES];
	static unsigned char reply[256];
	size_t env_len = environment_block(env, sizeof env);
	size_t reply_len = terminal_probe(reply, sizeof reply, PROBE_TIMEOUT_MS);
	int warned = sh_key_release_verdict(env, env_len, reply, reply_len, 1) == SH_KEYS_NO_RELEASES;
	if (warned) warn(tty, no_release_warning);
	static float samples[PLAY_CHUNK];
	int mode_reported = 0, was_paused = 0, failed = 0;
	for (;;) {
		double now = SDL_GetTicks64() / 1000.0;
		int key = terminal_key();
		unsigned flags = key >= 0 ? sh_key_byte((uint8_t)key, now) : 0;
		flags |= sh_tick(now);
		if (flags & SH_FLAG_QUIT) break;
		/* The first real space press shows what the terminal actually sends. */
		if (!mode_reported && (flags & (SH_FLAG_KITTY | SH_FLAG_LEGACY))) {
			if (flags & SH_FLAG_KITTY) status_line("Hold-to-fire: on (this terminal sends key releases)");
			else if (!warned) warn(tty, no_release_warning);
			mode_reported = 1;
		}
		int is_paused = (flags & SH_FLAG_PAUSED) != 0;
		if (is_paused != was_paused) status_line(is_paused ? "Paused" : "Playing");
		was_paused = is_paused;
		if (SDL_GetQueuedAudioSize(device) / sizeof(float) < QUEUE_TARGET) {
			if (sh_render(samples, PLAY_CHUNK, RATE) != SH_OK) { failed = 1; break; }
			sh_apply_gain(samples, PLAY_CHUNK, o->volume);
			if (SDL_QueueAudio(device, samples, sizeof samples) != 0) { failed = 1; break; }
		} else SDL_Delay(2);
	}
	terminal_stop();
	SDL_CloseAudioDevice(device);
	SDL_Quit();
	if (failed) die("Playback failed");
	fputs("Stopped. Terminal restored.\n", stderr);
}

/* --tips: probe this terminal (when there is one) and print advice. */
static int tips(const options *o) {
	static uint8_t env[MAX_ENV_BYTES];
	static unsigned char reply[256];
	size_t env_len = environment_block(env, sizeof env), reply_len = 0;
	int probed = isatty(STDIN_FILENO) && isatty(STDOUT_FILENO) && terminal_start() == 0;
	if (probed) {
		reply_len = terminal_probe(reply, sizeof reply, PROBE_TIMEOUT_MS);
		terminal_stop();
	}
	unsigned options = (o->json ? SH_TIPS_JSON : 0) | (!o->simple && isatty(STDOUT_FILENO) ? SH_TIPS_COLOR : 0);
	size_t n = sh_terminal_tips(env, env_len, reply, reply_len, probed, options, NULL, 0);
	uint8_t *text = malloc(n ? n : 1);
	if (!text) die("Out of memory");
	sh_terminal_tips(env, env_len, reply, reply_len, probed, options, text, n);
	fwrite(text, 1, n, stdout);
	free(text);
	return 0;
}

int main(int argc, char **argv) {
#ifdef SH_DEBUG_BUILD
	if (!getenv("MUTE_DEBUG_STATUS")) fputs("\033[33mDEBUG BUILD\033[0m\n", stderr);
#endif
	options o;
	const char *error = parse(argc, argv, &o);
	if (error) {
		fprintf(stderr, "%s\n", error);
		return 1;
	}
	if (o.mode == MODE_HELP) {
		fputs(help_text, stdout);
		return 0;
	}
	if (o.mode == MODE_TIPS) return tips(&o);
	if (o.mode == MODE_ABOUT) {
		puts("spy-hunter-music " VERSION ": original arcade sound-ROM player; " PLATFORM " " ARCH);
		return 0;
	}
	const char *rom = o.rom ? o.rom : default_rom();
	if (o.mode == MODE_PLAY) fputs("Booting original sound ROMs...\n", stderr);
	admit(rom);
	if (sh_boot(RATE, (unsigned)o.command) != SH_OK) die("Sound-board boot failed");
	if (o.mode == MODE_INSPECT) inspect(&o, rom);
	else if (o.mode == MODE_RENDER) render(&o);
	else play(&o);
	return 0;
}
