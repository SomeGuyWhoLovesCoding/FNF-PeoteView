/*
	* If it weren't for ChatGPT's and Estrol's help the time-stretching shit wouldn't have been possible.
	* Honestly thank fucking god cuz I'm ready to put this all together nicely.

	Oh and Estrol has his own fork of signalsmith-stretch if you want to go check it out: https://github.com/Estrol/signalsmith-stretch
	(It was updated recently as of the time when developing the time stretching implementation for fun)

	* Note: Fuck hxcpp's externing shit I don't wanna deal with it for any longer
*/
#include "include/ma_thing.h"

#include "signalsmith-stretch/signalsmith-stretch.h"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdio.h>
#include <vector>

/*
For simplicity, this example requires the device to use floating point samples.
*/
#define SAMPLE_FORMAT   ma_format_f32
#define CHANNEL_COUNT   2
#define SAMPLE_RATE     44100

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

ma_uint32   g_decoderCount;
ma_decoder* g_pDecoders;
ma_bool32* g_pDecodersActive;
ma_uint64* g_pDecoderLengths;
int g_pLongestDecoderIndex;
float*  g_pDecodersVolume;
float playbackRate = 1;

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
ma_device_config deviceConfig;
ma_device device;
ma_uint32 iDecoder;

/*
* IMPORTANT!
* When I decoded an mp3 and a flac at the same time and seeked the app crashes so running with mutexes fixes this.
*/
ma_mutex decoderMutex;

int getMixerState() {
	return MIXER_STATE;
}

double getPlaybackPosition() {
	ma_uint64 pos = 0;
	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		if (decoderMutex == NULL) {
			ma_mutex_init(&decoderMutex);
		}
		ma_mutex_lock(&decoderMutex);
		ma_decoder_get_cursor_in_pcm_frames(&g_pDecoders[g_pLongestDecoderIndex], &pos);
		ma_mutex_unlock(&decoderMutex);
	}
	return (double)pos / (SAMPLE_RATE * 0.001);
}

double getDuration() {
	ma_uint64 length = 0;
	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		length = g_pDecoderLengths[g_pLongestDecoderIndex];
	}
	return (double)length / (SAMPLE_RATE * 0.001);
}

void seekToPCMFrame(int64_t pos) {
	if (exists == 0) return;

	if (decoderMutex == NULL) {
		ma_mutex_init(&decoderMutex);
	}
	ma_mutex_lock(&decoderMutex);
	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		ma_decoder_seek_to_pcm_frame(&g_pDecoders[iDecoder], pos > 0 ? pos : 0);

		// If we seek to before EOF, reactivate
		if (pos < g_pDecoderLengths[iDecoder]) {
			g_pDecodersActive[iDecoder] = MA_TRUE;
		}
	}
	ma_mutex_unlock(&decoderMutex);
}

void freeThingies() {
	free(g_pDecoders);
	free(g_pDecodersActive);
	free(g_pDecoderLengths);
	free(g_pDecodersVolume);
}

ma_uint32 read_pcm_frames_f32(ma_uint32 index, float* pBuffer, ma_uint32 frameCount)
{
	ma_decoder* pDecoder = &g_pDecoders[index];
	float temp[4096];
	ma_uint32 tempCapInFrames = 4096 / CHANNEL_COUNT;
	ma_uint32 totalFramesRead = 0;
	memset(temp, 0, sizeof(temp));

	while (totalFramesRead < frameCount) {
		ma_uint64 framesReadThisIteration;
		ma_uint32 totalFramesRemaining = frameCount - totalFramesRead;
		ma_uint32 framesToReadThisIteration = (totalFramesRemaining < tempCapInFrames) ? totalFramesRemaining : tempCapInFrames;

		ma_result result = ma_decoder_read_pcm_frames(pDecoder, temp, framesToReadThisIteration, &framesReadThisIteration);

		if (result != MA_SUCCESS || framesReadThisIteration == 0) break;

		for (ma_uint64 i = 0; i < framesReadThisIteration * CHANNEL_COUNT; ++i) {
			pBuffer[totalFramesRead * CHANNEL_COUNT + i] += temp[i] * g_pDecodersVolume[index];
		}

		totalFramesRead += (ma_uint32)framesReadThisIteration;

		if (framesReadThisIteration < framesToReadThisIteration) break; // EOF
	}

	return totalFramesRead;
}

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount)
{
	float* pOutputF32 = (float*)pOutput;

	MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);

	if (playbackRate == 1.0f) {
		memset(pOutputF32, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

		for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
			if (!g_pDecodersActive[i]) continue;

			if (decoderMutex == NULL) {
				ma_mutex_init(&decoderMutex);
			}
			ma_mutex_lock(&decoderMutex);
			ma_uint32 framesRead = read_pcm_frames_f32(i, pOutputF32, frameCount);
			ma_mutex_unlock(&decoderMutex);
			if (framesRead == 0) {
				g_pDecodersActive[i] = MA_FALSE;
			}
		}
	} else {
		// Temp buffers
		float inputMix[4096 * CHANNEL_COUNT] = {0};
		float stretchedOutput[4096 * CHANNEL_COUNT] = {0};

		ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * playbackRate); // pre-stretch input size
		if (maxFramesToRead > 4096) maxFramesToRead = 4096;

		for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
			if (!g_pDecodersActive[i]) continue;

			if (decoderMutex == NULL) {
				ma_mutex_init(&decoderMutex);
			}
			ma_mutex_lock(&decoderMutex);
			ma_uint32 framesRead = read_pcm_frames_f32(i, inputMix, maxFramesToRead);
			ma_mutex_unlock(&decoderMutex);
			if (framesRead == 0) {
				g_pDecodersActive[i] = MA_FALSE;
			}
		}

		if (g_pDecodersActive[g_pLongestDecoderIndex]) {
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

	if (!g_pDecodersActive[g_pLongestDecoderIndex]) {
		// If you're reached this point, that means the song has been finished.
		MIXER_STATE = 3;
	}

	(void)pInput;
}

void deactivate_decoder(int index) {
	if (index < g_decoderCount) {
		g_pDecodersActive[index] = MA_FALSE;
	}
}

void amplify_decoder(int index, double volume) {
	g_pDecodersVolume[index] = volume;
}

void setPlaybackRate(float value) {
	if (exists == 0) return;
	if (value == playbackRate) return; // No change

	playbackRate = value;

	ma_decoder decoder = g_pDecoders[g_pLongestDecoderIndex];

	ma_uint64 cursor2 = 0;
	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		if (decoderMutex == NULL) {
			ma_mutex_init(&decoderMutex);
		}
		ma_mutex_lock(&decoderMutex);
		ma_decoder_get_cursor_in_pcm_frames(&decoder, &cursor2);
		ma_mutex_unlock(&decoderMutex);
	}

	// Reset stretch state with new rate
	if (stretch == nullptr) {
		stretch = new signalsmith::stretch::SignalsmithStretch();
		stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
	}
	int latencyFrames = stretch->inputLatency();
	std::vector<float> latencyData(latencyFrames * CHANNEL_COUNT);

	if (decoderMutex == NULL) {
		ma_mutex_init(&decoderMutex);
	}
	ma_mutex_lock(&decoderMutex);
	ma_decoder_read_pcm_frames(&decoder, latencyData.data(), latencyFrames, NULL);
	ma_decoder_seek_to_pcm_frame(&decoder, cursor2);
	ma_mutex_unlock(&decoderMutex);

	// only need to seek from one decoder

	stretch->seek(latencyData.data(), latencyFrames, playbackRate);
}

void start() {
	if (exists == 0) return;
	if (MIXER_STATE == 3) {
		seekToPCMFrame(0);
	}
	ma_device_start(&device);
	MIXER_STATE = 1;
}

void stop() {
	if (exists == 0) return;
	ma_device_stop(&device);
	MIXER_STATE = 2;
}

int stopped() {
	return MIXER_STATE == 3 ? 1 : 0;
}

void destroy() {
	if (exists == 0) return;
	exists = 0;
	ma_device_uninit(&device);

	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		ma_decoder_uninit(&g_pDecoders[iDecoder]);
	}
	freeThingies();
}

void loadFiles(std::vector<const char*> argv)
{
	if (argv.size() == 0) {
		printf("No input files.\n");
		return;
	}

	g_decoderCount   = argv.size();
	g_pDecoders      = (ma_decoder*)malloc(sizeof(*g_pDecoders)      * g_decoderCount);
	g_pDecodersActive = (ma_bool32*)malloc(sizeof(ma_bool32) * g_decoderCount);
	g_pDecoderLengths = (ma_uint64*)malloc(sizeof(ma_uint64) * g_decoderCount);
	//g_pDecoderConfigs      = (ma_decoder_config*)malloc(sizeof(*g_pDecoderConfigs)      * g_decoderCount);
	g_pDecodersVolume      = (float*)malloc(sizeof(*g_pDecodersVolume)      * g_decoderCount);
	//g_pDecodersPan      = (float*)malloc(sizeof(*g_pDecodersPan)      * g_decoderCount);

	ma_uint64 absoluteLengthOfSong = 0;
	decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		const char* path = argv[iDecoder];

		g_pDecodersVolume[iDecoder] = 1.0;

		result = ma_decoder_init_file(path, &decoderConfig, &g_pDecoders[iDecoder]);
		if (result != MA_SUCCESS) {
			ma_uint32 iDecoder2;
			for (iDecoder2 = 0; iDecoder2 < iDecoder; ++iDecoder2) {
				ma_decoder_uninit(&g_pDecoders[iDecoder2]);
			}
			freeThingies();

			printf("Failed to load %s.\n", argv[iDecoder]);
			exists = 0;
			return;
		}

		ma_data_source_set_looping(&g_pDecoders[iDecoder], MA_FALSE);

		g_pDecodersActive[iDecoder] = MA_TRUE;

		ma_decoder_get_length_in_pcm_frames(&g_pDecoders[iDecoder], &g_pDecoderLengths[iDecoder]);

		if (g_pDecoderLengths[iDecoder] > absoluteLengthOfSong) {
			absoluteLengthOfSong = g_pDecoderLengths[iDecoder];
			g_pLongestDecoderIndex = iDecoder;
		}

		exists = 1;
	}

	/* Create only a single device. The decoders will be mixed together in the callback. In this example the data format needs to be the same as the decoders. */
	deviceConfig = ma_device_config_init(ma_device_type_playback);
	deviceConfig.playback.format   = SAMPLE_FORMAT;
	deviceConfig.playback.channels = CHANNEL_COUNT;
	deviceConfig.sampleRate        = SAMPLE_RATE;
	deviceConfig.dataCallback      = data_callback;
	deviceConfig.pUserData         = NULL;

	if (ma_device_init(NULL, &deviceConfig, &device) != MA_SUCCESS) {
		for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
			ma_decoder_uninit(&g_pDecoders[iDecoder]);
		}
		freeThingies();

		printf("Failed to open playback device.\n");
		return;
	}
}