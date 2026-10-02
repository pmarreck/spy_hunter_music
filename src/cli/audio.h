/* Playback port: 48 kHz mono. SDL on Linux and macOS, waveOut on Windows.
 * The play loop stays free of either API. */
#ifndef SPY_HUNTER_AUDIO_H
#define SPY_HUNTER_AUDIO_H

#include <stddef.h>

/* Open the default output device. Returns 0, or -1 (see audio_error). */
int audio_open(void);
void audio_close(void);
const char *audio_error(void);
/* Queue `count` float frames at `volume`. Copies what the device needs.
 * Returns 0, or -1 when the device rejects the write. */
int audio_write(const float *samples, size_t count, double volume);
/* Frames still waiting to be played. */
size_t audio_queued(void);
/* Monotonic seconds, suitable for the session clock. */
double audio_now(void);
/* Brief wait when the device queue is already full. */
void audio_sleep(void);

#endif
