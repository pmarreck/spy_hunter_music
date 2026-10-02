/* waveOut playback for Windows. Zig's mingw import library includes winmm,
 * so the cross build does not need a MinGW SDL. Six 10 ms buffers cover the
 * 50 ms queue the play loop keeps filled. */
#include "audio.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "spy_hunter.h"

#define RATE 48000
#define CHUNK 480
#define NBUF 6

static HWAVEOUT wave;
static WAVEHDR hdr[NBUF];
static int16_t pcm[NBUF][CHUNK];
static int submitted[NBUF];
static char error[160];

int audio_open(void) {
	WAVEFORMATEX fmt;
	memset(&fmt, 0, sizeof fmt);
	fmt.wFormatTag = WAVE_FORMAT_PCM;
	fmt.nChannels = 1;
	fmt.nSamplesPerSec = RATE;
	fmt.wBitsPerSample = 16;
	fmt.nBlockAlign = 2;
	fmt.nAvgBytesPerSec = RATE * 2;
	MMRESULT result = waveOutOpen(&wave, WAVE_MAPPER, &fmt, 0, 0, CALLBACK_NULL);
	if (result != MMSYSERR_NOERROR) {
		snprintf(error, sizeof error, "waveOutOpen failed (%u)", (unsigned)result);
		wave = NULL;
		return -1;
	}
	for (int i = 0; i < NBUF; i++) {
		memset(&hdr[i], 0, sizeof hdr[i]);
		hdr[i].lpData = (LPSTR)pcm[i];
		hdr[i].dwBufferLength = CHUNK * 2;
		result = waveOutPrepareHeader(wave, &hdr[i], sizeof hdr[i]);
		if (result != MMSYSERR_NOERROR) {
			snprintf(error, sizeof error, "waveOutPrepareHeader failed (%u)", (unsigned)result);
			audio_close();
			return -1;
		}
	}
	return 0;
}

void audio_close(void) {
	if (!wave) return;
	waveOutReset(wave);
	for (int i = 0; i < NBUF; i++) {
		if (hdr[i].dwFlags & WHDR_PREPARED) waveOutUnprepareHeader(wave, &hdr[i], sizeof hdr[i]);
		submitted[i] = 0;
	}
	waveOutClose(wave);
	wave = NULL;
}

const char *audio_error(void) { return error[0] ? error : "Audio device failed"; }

int audio_write(const float *samples, size_t count, double volume) {
	if (count == 0 || count > CHUNK) {
		snprintf(error, sizeof error, "Audio chunk exceeds %d frames", CHUNK);
		return -1;
	}
	int slot = -1;
	for (int i = 0; i < NBUF; i++) {
		if (!submitted[i] || (hdr[i].dwFlags & WHDR_DONE)) {
			slot = i;
			break;
		}
	}
	if (slot < 0) {
		snprintf(error, sizeof error, "waveOut queue is full");
		return -1;
	}
	double sum_squares = 0, peak = 0;
	sh_pcm16(samples, count, volume, (uint8_t *)pcm[slot], &sum_squares, &peak);
	hdr[slot].dwBufferLength = (DWORD)(count * 2);
	MMRESULT result = waveOutWrite(wave, &hdr[slot], sizeof hdr[slot]);
	if (result != MMSYSERR_NOERROR) {
		snprintf(error, sizeof error, "waveOutWrite failed (%u)", (unsigned)result);
		return -1;
	}
	submitted[slot] = 1;
	return 0;
}

size_t audio_queued(void) {
	size_t frames = 0;
	for (int i = 0; i < NBUF; i++) {
		if (submitted[i] && !(hdr[i].dwFlags & WHDR_DONE)) frames += CHUNK;
	}
	return frames;
}

double audio_now(void) { return (double)GetTickCount64() / 1000.0; }

void audio_sleep(void) { Sleep(2); }
