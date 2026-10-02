/* SDL2 playback for Linux and macOS. Float32 matches the core's render
 * buffer, so the only conversion is the shared output gain. */
#include "audio.h"

#include <SDL.h>
#include <stdio.h>
#include <string.h>

#include "spy_hunter.h"

#define RATE 48000
#define CHUNK 480

static SDL_AudioDeviceID device;
static char error[160];

int audio_open(void) {
	if (SDL_Init(SDL_INIT_AUDIO) != 0) {
		snprintf(error, sizeof error, "SDL audio: %s", SDL_GetError());
		return -1;
	}
	SDL_AudioSpec want;
	memset(&want, 0, sizeof want);
	want.freq = RATE;
	want.format = AUDIO_F32SYS;
	want.channels = 1;
	want.samples = 1024;
	device = SDL_OpenAudioDevice(NULL, 0, &want, NULL, 0);
	if (!device) {
		snprintf(error, sizeof error, "Audio device: %s", SDL_GetError());
		SDL_Quit();
		return -1;
	}
	SDL_PauseAudioDevice(device, 0);
	return 0;
}

void audio_close(void) {
	if (!device) return;
	SDL_CloseAudioDevice(device);
	device = 0;
	SDL_Quit();
}

const char *audio_error(void) { return error[0] ? error : "Audio device failed"; }

int audio_write(const float *samples, size_t count, double volume) {
	float local[CHUNK];
	if (count > CHUNK) {
		snprintf(error, sizeof error, "Audio chunk exceeds %d frames", CHUNK);
		return -1;
	}
	memcpy(local, samples, count * sizeof(float));
	sh_apply_gain(local, count, volume);
	if (SDL_QueueAudio(device, local, (Uint32)(count * sizeof(float))) != 0) {
		snprintf(error, sizeof error, "Audio device: %s", SDL_GetError());
		return -1;
	}
	return 0;
}

size_t audio_queued(void) {
	return SDL_GetQueuedAudioSize(device) / sizeof(float);
}

double audio_now(void) { return (double)SDL_GetTicks64() / 1000.0; }

void audio_sleep(void) { SDL_Delay(2); }
