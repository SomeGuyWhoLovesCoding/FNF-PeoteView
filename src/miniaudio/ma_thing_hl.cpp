/*
	* If it weren't for ChatGPT's and Estrol's help the time-stretching shit wouldn't have been possible.
	* Honestly thank fucking god cuz I'm ready to put this all together nicely.

	Oh and Estrol has his own fork of signalsmith-stretch if you want to go check it out: https://github.com/Estrol/signalsmith-stretch
	(It was updated recently as of the time when developing the time stretching implementation for fun)

	* Note: Fuck hxcpp's externing shit I don't wanna deal with it for any longer


	* I will fucking kill whoever structured hl like this(not)
	* Yannaris did
*/

#define HL_NAME(n) ma_thing_##n

#include <hl.h>

#include "include/ma_thing.h"

#include "signalsmith-stretch/signalsmith-stretch.h"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdio.h>
#include <vector>
#include <stdint.h>
#include <string.h>

/*
For simplicity, this example requires the device to use floating point samples.
*/
#define SAMPLE_FORMAT   ma_format_f32
#define CHANNEL_COUNT   2
#define SAMPLE_RATE     44100

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

ma_uint32   g_decoderCount;
ma_decoder* g_pDecoders;
ma_bool32*  g_pDecodersActive;
ma_uint64*  g_pDecoderLengths;
int         g_pLongestDecoderIndex;
float*      g_pDecodersVolume;
float       playbackRate = 1;

/*
* 0 = UNDEFINED
* 1 = PLAYING
* 2 = STOPPED
* 3 = FINISHED
*/
int MIXER_STATE = 3;

/*
* 0 = false
* 1 = true
*/
int exists = 0;

ma_result result;
ma_decoder_config decoderConfig;
ma_device_config  deviceConfig;
ma_device         device;
ma_bool32 deviceExists = MA_FALSE;
ma_uint32         iDecoder;

// -------------------- LATENCY MEASUREMENT --------------------
HL_PRIM int HL_NAME(detectLatency)(_NO_ARG) {
	int osMs = 95;

	if (deviceExists == MA_TRUE) {
		osMs += (int)(device.playback.internalPeriodSizeInFrames / (SAMPLE_RATE * 0.001));
		//printf("%i\n", (int)(device.playback.internalPeriodSizeInFrames / (SAMPLE_RATE * 0.001)));
	}

	return osMs;
}

/*
* IMPORTANT!
* When decoding multiple formats concurrently, guard decoder ops with a mutex.
*/
ma_mutex  decoderMutex;
ma_bool32 decoderMutexInitialized = MA_FALSE;

static inline void ensure_mutex() {
	if (!decoderMutexInitialized) {
		ma_mutex_init(&decoderMutex);
		decoderMutexInitialized = MA_TRUE;
	}
}

static inline void freeThingies() {
	free(g_pDecoders);
	free(g_pDecodersActive);
	free(g_pDecoderLengths);
	free(g_pDecodersVolume);
}

static inline bool any_active() {
	for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
		if (g_pDecodersActive[i]) return true;
	}
	return false;
}

static ma_uint32 read_pcm_frames_f32(ma_uint32 index, float* pBuffer, ma_uint32 frameCount)
{
	ma_decoder* pDecoder = &g_pDecoders[index];
	float temp[4096];
	ma_uint32 tempCapInFrames = 4096 / CHANNEL_COUNT;
	ma_uint32 totalFramesRead = 0;
	memset(temp, 0, sizeof(temp));

	while (totalFramesRead < frameCount) {
		ma_uint64 framesReadThisIteration = 0;
		ma_uint32 totalFramesRemaining   = frameCount - totalFramesRead;
		ma_uint32 framesToReadThisIter   = (totalFramesRemaining < tempCapInFrames) ? totalFramesRemaining : tempCapInFrames;

		ma_result r = ma_decoder_read_pcm_frames(pDecoder, temp, framesToReadThisIter, &framesReadThisIteration);
		if (r != MA_SUCCESS || framesReadThisIteration == 0) break;

		// Mix into destination with gain
		const ma_uint64 samples = framesReadThisIteration * CHANNEL_COUNT;
		for (ma_uint64 i = 0; i < samples; ++i) {
			pBuffer[totalFramesRead * CHANNEL_COUNT + i] += temp[i] * g_pDecodersVolume[index];
		}

		totalFramesRead += (ma_uint32)framesReadThisIteration;

		if (framesReadThisIteration < framesToReadThisIter) break; // EOF
	}

	return totalFramesRead;
}

static void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount)
{
	float* pOutputF32 = (float*)pOutput;

	MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);

	// Early out if nothing is active
	if (!any_active()) {
		memset(pOutputF32, 0, sizeof(float) * frameCount * CHANNEL_COUNT);
		MIXER_STATE = 3;
		(void)pInput;
		return;
	}

	if (playbackRate == 1.0f) {
		memset(pOutputF32, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

		for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
			if (!g_pDecodersActive[i]) continue;

			ensure_mutex();
			ma_mutex_lock(&decoderMutex);
			ma_uint32 framesRead = read_pcm_frames_f32(i, pOutputF32, frameCount);
			ma_mutex_unlock(&decoderMutex);

			if (framesRead == 0) {
				g_pDecodersActive[i] = MA_FALSE;
			}
		}
	} else {
		// Temp buffers
		float inputMix[4096 * CHANNEL_COUNT]        = {0};
		float stretchedOutput[4096 * CHANNEL_COUNT] = {0};

		ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * playbackRate); // pre-stretch input size
		if (maxFramesToRead > 4096) maxFramesToRead = 4096;

		// Reset mix buffer each callback to avoid residue across callbacks.
		memset(inputMix, 0, sizeof(inputMix));

		for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
			if (!g_pDecodersActive[i]) continue;

			ensure_mutex();
			ma_mutex_lock(&decoderMutex);
			ma_uint32 framesRead = read_pcm_frames_f32(i, inputMix, maxFramesToRead);
			ma_mutex_unlock(&decoderMutex);

			if (framesRead == 0) {
				g_pDecodersActive[i] = MA_FALSE;
			}
		}

		if (any_active()) {
			if (stretch == nullptr) {
				stretch = new signalsmith::stretch::SignalsmithStretch();
				stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
			}
			stretch->process(
				inputMix,
				maxFramesToRead,
				stretchedOutput,
				frameCount
			);

			memcpy(pOutputF32, stretchedOutput, sizeof(float) * frameCount * CHANNEL_COUNT);
		} else {
			memset(pOutputF32, 0, sizeof(float) * frameCount * CHANNEL_COUNT);
		}
	}

	if (!any_active()) {
		// Song finished.
		MIXER_STATE = 3;
	}

	(void)pInput;
}

HL_PRIM int HL_NAME(get_mixer_state)(_NO_ARG) {
	return MIXER_STATE;
}

HL_PRIM double HL_NAME(get_playback_position)(_NO_ARG) {
	ma_uint64 pos = 0;
	ensure_mutex();
	ma_mutex_lock(&decoderMutex);

	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		ma_decoder_get_cursor_in_pcm_frames(&g_pDecoders[g_pLongestDecoderIndex], &pos);
	} else {
		pos = g_pDecoderLengths[g_pLongestDecoderIndex]; // report EOF when inactive
	}

	ma_mutex_unlock(&decoderMutex);
	return (double)pos / (SAMPLE_RATE * 0.001);
}

HL_PRIM double HL_NAME(get_duration)(_NO_ARG) {
	ma_uint64 len = 0;
	// cached read, lock optional but harmless
	len = g_pDecoderLengths[g_pLongestDecoderIndex];
	return (double)len / (SAMPLE_RATE * 0.001);
}

HL_PRIM void HL_NAME(seek_to_pcm_frame)(ma_uint64 pos) {
	if (exists == 0) return;

	ensure_mutex();
	ma_mutex_lock(&decoderMutex);

	bool anyActive = false;

	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		ma_uint64 len = g_pDecoderLengths[iDecoder];
		ma_uint64 target = 0;

		if (pos == 0) {
			target = 0;
		} else if (pos >= len) {
			target = len; // snap to EOF
		} else {
			target = pos;
		}

		ma_decoder_seek_to_pcm_frame(&g_pDecoders[iDecoder], target);

		// Active only if strictly before EOF
		if (target < len) {
			g_pDecodersActive[iDecoder] = MA_TRUE;
			anyActive = true;
		} else {
			g_pDecodersActive[iDecoder] = MA_FALSE;
		}
	}

	ma_mutex_unlock(&decoderMutex);

	MIXER_STATE = anyActive ? 1 : 3;
}

HL_PRIM void HL_NAME(deactivate_decoder_hl)(int index) {
	if (index >= 0 && (ma_uint32)index < g_decoderCount) {
		g_pDecodersActive[index] = MA_FALSE;
	}
}

HL_PRIM void HL_NAME(amplify_decoder_hl)(int index, double volume) {
	if (index >= 0 && (ma_uint32)index < g_decoderCount) {
		g_pDecodersVolume[index] = (float)volume;
	}
}

HL_PRIM void HL_NAME(setPlaybackRate)(float value) {
	if (exists == 0) return;
	if (value == playbackRate) return; // No change

	playbackRate = value;

	ma_decoder* pDecoder = &g_pDecoders[g_pLongestDecoderIndex];

	ma_uint64 cursor2 = 0;
	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		ensure_mutex();
		ma_mutex_lock(&decoderMutex);
		ma_decoder_get_cursor_in_pcm_frames(pDecoder, &cursor2);
		ma_mutex_unlock(&decoderMutex);
	}

	// Reset stretch state with new rate
	if (stretch == nullptr) {
		stretch = new signalsmith::stretch::SignalsmithStretch();
		stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
	}
	int latencyFrames = stretch->inputLatency();
	if (latencyFrames < 0) latencyFrames = 0;
	std::vector<float> latencyData((size_t)latencyFrames * CHANNEL_COUNT, 0.0f);

	ensure_mutex();
	ma_mutex_lock(&decoderMutex);
	if (latencyFrames > 0) {
		ma_decoder_read_pcm_frames(pDecoder, latencyData.data(), (ma_uint64)latencyFrames, nullptr);
		ma_decoder_seek_to_pcm_frame(pDecoder, cursor2);
	}
	ma_mutex_unlock(&decoderMutex);

	// Only need to seek from one decoder
	stretch->seek(latencyData.data(), latencyFrames, playbackRate);
}

HL_PRIM void HL_NAME(start)(_NO_ARG) {
	if (exists == 0) return;
	if (MIXER_STATE == 3) {
		// rewind when starting after finished
		HL_NAME(seek_to_pcm_frame)(0);
	}
	ma_device_start(&device);
	MIXER_STATE = 1;
}

HL_PRIM void HL_NAME(stop)(_NO_ARG) {
	if (exists == 0) return;
	ma_device_stop(&device);
	MIXER_STATE = 2;
}

HL_PRIM bool HL_NAME(stopped)(_NO_ARG) {
	return MIXER_STATE == 3;
}

HL_PRIM void HL_NAME(destroy)(_NO_ARG) {
	if (exists == 0) return;
	exists = 0;

	ma_device_uninit(&device);
	deviceExists = MA_FALSE;

	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		ma_decoder_uninit(&g_pDecoders[iDecoder]);
	}
	freeThingies();

	if (stretch) {
		delete stretch;
		stretch = nullptr;
	}

	if (decoderMutexInitialized) {
		ma_mutex_uninit(&decoderMutex);
		decoderMutexInitialized = MA_FALSE;
	}
}

HL_PRIM void HL_NAME(loadFiles)(varray* argv)
{
	if (argv->size == 0) {
		printf("No input files.\n");
		return;
	}

	g_decoderCount    = (ma_uint32)argv->size;
	g_pDecoders       = (ma_decoder*)malloc(sizeof(*g_pDecoders)      * g_decoderCount);
	g_pDecodersActive = (ma_bool32*)malloc(sizeof(ma_bool32)          * g_decoderCount);
	g_pDecoderLengths = (ma_uint64*)malloc(sizeof(ma_uint64)          * g_decoderCount);
	g_pDecodersVolume = (float*)    malloc(sizeof(*g_pDecodersVolume) * g_decoderCount);

	ma_uint64 absoluteLengthOfSong = 0;
	decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		const char* path = hl_aptr(argv, const char*)[iDecoder];

		g_pDecodersVolume[iDecoder] = 1.0f;

		result = ma_decoder_init_file(path, &decoderConfig, &g_pDecoders[iDecoder]);
		if (result != MA_SUCCESS) {
			ma_uint32 iDecoder2;
			for (iDecoder2 = 0; iDecoder2 < iDecoder; ++iDecoder2) {
				ma_decoder_uninit(&g_pDecoders[iDecoder2]);
			}
			freeThingies();

			printf("Failed to load %s.\n", path);
			exists = 0;
			return;
		}

		ma_data_source_set_looping(&g_pDecoders[iDecoder], MA_FALSE);
		g_pDecodersActive[iDecoder] = MA_TRUE;

		ma_decoder_get_length_in_pcm_frames(&g_pDecoders[iDecoder], &g_pDecoderLengths[iDecoder]);

		if (g_pDecoderLengths[iDecoder] > absoluteLengthOfSong) {
			absoluteLengthOfSong = g_pDecoderLengths[iDecoder];
			g_pLongestDecoderIndex = (int)iDecoder;
		}

		exists = 1;
	}

	/* Create only a single device. The decoders will be mixed together in the callback. In this example the data format needs to be the same as the decoders. */
	deviceConfig = ma_device_config_init(ma_device_type_playback);
	deviceConfig.playback.format   = SAMPLE_FORMAT;
	deviceConfig.playback.channels = CHANNEL_COUNT;
	deviceConfig.sampleRate        = SAMPLE_RATE;
	deviceConfig.dataCallback      = data_callback;
	deviceConfig.pUserData         = nullptr;

	if (ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS) {
		for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
			ma_decoder_uninit(&g_pDecoders[iDecoder]);
		}
		freeThingies();

		printf("Failed to open playback device.\n");
		return;
	}
	deviceExists = MA_TRUE;
}

DEFINE_PRIM(_I32, detectLatency, _NO_ARG)
DEFINE_PRIM(_I32, get_mixer_state, _NO_ARG)
DEFINE_PRIM(_F64, get_playback_position, _NO_ARG)
DEFINE_PRIM(_F64, get_duration, _NO_ARG)
DEFINE_PRIM(_VOID, seek_to_pcm_frame, _I64)
DEFINE_PRIM(_VOID, deactivate_decoder_hl, _I32)
DEFINE_PRIM(_VOID, amplify_decoder_hl, _I32 _F64)
DEFINE_PRIM(_VOID, setPlaybackRate, _F32)
DEFINE_PRIM(_VOID, start, _NO_ARG)
DEFINE_PRIM(_VOID, stop, _NO_ARG)
DEFINE_PRIM(_BOOL, stopped, _NO_ARG)
DEFINE_PRIM(_VOID, destroy, _NO_ARG)
DEFINE_PRIM(_VOID, loadFiles, _ARR)