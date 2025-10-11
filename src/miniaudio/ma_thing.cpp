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
#include <stdint.h>
#include <string.h>

// async
#include <thread>
#include <atomic>
#include <algorithm>

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

int MIXER_STATE = 3; // 0=undefined,1=playing,2=stopped,3=finished

std::atomic<int> g_measuredLatencyMs{0};
std::atomic<bool> g_calibrating{false};

int measureOnce() {
#ifdef _WIN32
    printf("Starting measurement...\n");
    const int PULSE_LEN = SAMPLE_RATE / 100;
    float pulse[PULSE_LEN], recorded[SAMPLE_RATE * 2];
    for (int i = 0; i < PULSE_LEN; i++) pulse[i] = 0.001f;
    
    ma_uint32 recFrames = 0;
    ma_bool32 played = MA_FALSE;
    
    struct LD { float* buf; ma_uint32* frames; ma_uint32 max; };
    LD loopData{recorded, &recFrames, SAMPLE_RATE * 2};
    
    auto outCb = [](ma_device* d, void* out, const void*, ma_uint32 fc) {
        memset(out, 0, fc * 8);
        if (!*(ma_bool32*)d->pUserData) {
            float* o = (float*)out;
            for (int i = 0; i < 441 && i < (int)fc; i++) o[i*2] = o[i*2+1] = 0.001f;
            *(ma_bool32*)d->pUserData = MA_TRUE;
        }
    };
    
    auto inCb = [](ma_device* d, void*, const void* in, ma_uint32 fc) {
        LD* ld = (LD*)d->pUserData;
        const float* f = (const float*)in;
        ma_uint32 n = fc;
        if (*ld->frames + n > ld->max) n = ld->max - *ld->frames;
        for (ma_uint32 i = 0; i < n; i++) 
            ld->buf[*ld->frames + i] = (f[i*2] + f[i*2+1]) * 0.5f;
        *ld->frames += n;
    };
    
    ma_device pb, lb;
    ma_device_config pCfg = ma_device_config_init(ma_device_type_playback);
    pCfg.playback.format = ma_format_f32;
    pCfg.playback.channels = CHANNEL_COUNT;
    pCfg.sampleRate = SAMPLE_RATE;
    pCfg.dataCallback = outCb;
    pCfg.pUserData = &played;
    if (ma_device_init(NULL, &pCfg, &pb) != MA_SUCCESS) {
        printf("Playback init failed\n");
        return -1;
    }
    
    ma_backend be[] = {ma_backend_wasapi};
    ma_device_config lCfg = ma_device_config_init(ma_device_type_loopback);
    lCfg.capture.format = ma_format_f32;
    lCfg.capture.channels = CHANNEL_COUNT;
    lCfg.sampleRate = SAMPLE_RATE;
    lCfg.dataCallback = inCb;
    lCfg.pUserData = &loopData;
    if (ma_device_init_ex(be, 1, NULL, &lCfg, &lb) != MA_SUCCESS) {
        printf("Loopback init failed\n");
        ma_device_uninit(&pb);
        return -1;
    }
    
    ma_device_start(&lb);
    ma_device_start(&pb);
    ma_sleep(2000);
    ma_device_uninit(&pb);
    ma_device_uninit(&lb);
    
    printf("Recorded %d frames\n", recFrames);
    
    int best = 0;
    float bestScore = -1.0f, pEnergy = 0.0f;
    for (int i = 0; i < PULSE_LEN; i++) pEnergy += pulse[i] * pulse[i];
    
    for (int o = 0; o <= (int)recFrames - PULSE_LEN; o++) {
        float s = 0.0f;
        for (int i = 0; i < PULSE_LEN; i++) s += recorded[o + i] * pulse[i];
        if (s > bestScore) { bestScore = s; best = o; }
    }
    
    int result = bestScore < pEnergy * 0.1f ? -1 : (best * 1000) / SAMPLE_RATE;
    printf("Best offset: %d frames, score: %f, result: %dms\n", best, bestScore, result);
    return result;
#else
    return 20;
#endif
}

void calibrateLatencyAsync(void(*cb)(int) = nullptr) {
    if (g_calibrating.exchange(true)) {
        printf("Calibration already running\n");
        return;
    }
    
    printf("Starting async calibration...\n");
    
    std::thread([cb]() {
        int valid[3], cnt = 0;
        for (int i = 0; i < 3; i++) {
            printf("Attempt %d/3\n", i+1);
            int m = measureOnce();
            if (m >= 0) valid[cnt++] = m;
            if (i < 2) ma_sleep(500);
        }
        
        int result = 20;
        if (cnt > 0) {
            std::sort(valid, valid + cnt);
            result = valid[cnt / 2];
        }
        
        printf("Calibration complete: %dms (%d valid measurements)\n", result, cnt);
        
        g_measuredLatencyMs.store(result);
        g_calibrating.store(false);
        if (cb) cb(result);
    }).detach();
}

int detectLatency() {
	int latency = g_measuredLatencyMs.load();
	if (latency == 0) {
		calibrateLatencyAsync();
		while (g_calibrating.load()) ma_sleep(50);
		latency = g_measuredLatencyMs.load();
		printf("Latency: %dms\n", latency);
		return latency;
	}
    return 110 + latency;
}

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
ma_bool32 decoderMutexInitialized = MA_FALSE;

static inline void ensure_mutex() {
	if (!decoderMutexInitialized) {
		ma_mutex_init(&decoderMutex);
		decoderMutexInitialized = MA_TRUE;
	}
}

int getMixerState() {
	return MIXER_STATE;
}

double getPlaybackPosition() {
	ma_uint64 pos = 0;
	ensure_mutex();
	ma_mutex_lock(&decoderMutex);

	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		ma_decoder_get_cursor_in_pcm_frames(&g_pDecoders[g_pLongestDecoderIndex], &pos);
	} else {
		pos = g_pDecoderLengths[g_pLongestDecoderIndex]; // report EOF
	}

	ma_mutex_unlock(&decoderMutex);
	return ((double)pos / (SAMPLE_RATE * 0.001));
}

double getDuration() {
	ma_uint64 length = g_pDecoderLengths[g_pLongestDecoderIndex];
	return (double)length / (SAMPLE_RATE * 0.001);
}

void seekToPCMFrame(int64_t pos) {
	if (exists == 0) return;

	ensure_mutex();
	ma_mutex_lock(&decoderMutex);

	bool anyActive = false;

	for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
		ma_uint64 len = g_pDecoderLengths[iDecoder];
		ma_uint64 target = 0;

		if (pos <= 0) {
			target = 0;
		} else if ((ma_uint64)pos >= len) {
			target = len; // snap to EOF
		} else {
			target = (ma_uint64)pos;
		}

		ma_decoder_seek_to_pcm_frame(&g_pDecoders[iDecoder], target);

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

static inline bool any_active() {
	for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
		if (g_pDecodersActive[i]) return true;
	}
	return false;
}

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount)
{
	float* pOutputF32 = (float*)pOutput;
	MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);

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
		float inputMix[4096 * CHANNEL_COUNT] = {0};
		float stretchedOutput[4096 * CHANNEL_COUNT] = {0};

		ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * playbackRate);
		if (maxFramesToRead > 4096) maxFramesToRead = 4096;

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
			stretch->process(inputMix, maxFramesToRead, stretchedOutput, frameCount);
			memcpy(pOutputF32, stretchedOutput, sizeof(float) * frameCount * CHANNEL_COUNT);
		} else {
			memset(pOutputF32, 0, sizeof(float) * frameCount * CHANNEL_COUNT);
		}
	}

	if (!any_active()) {
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
	if (value == playbackRate) return;

	playbackRate = value;

	ma_decoder* pDecoder = &g_pDecoders[g_pLongestDecoderIndex];

	ma_uint64 cursor2 = 0;
	if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
		ensure_mutex();
		ma_mutex_lock(&decoderMutex);
		ma_decoder_get_cursor_in_pcm_frames(pDecoder, &cursor2);
		ma_mutex_unlock(&decoderMutex);
	}

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
		ma_decoder_read_pcm_frames(pDecoder, latencyData.data(), (ma_uint64)latencyFrames, NULL);
		ma_decoder_seek_to_pcm_frame(pDecoder, cursor2);
	}
	ma_mutex_unlock(&decoderMutex);

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

bool stopped() {
	return MIXER_STATE == 3;
}

void destroy() {
	if (exists == 0) return;
	exists = 0;
	ma_device_uninit(&device);

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

void loadFiles(std::vector<const char*> argv)
{
	if (argv.empty()) {
		printf("No input files.\n");
		return;
	}

	g_decoderCount   = argv.size();
	g_pDecoders      = (ma_decoder*)malloc(sizeof(*g_pDecoders)      * g_decoderCount);
	g_pDecodersActive = (ma_bool32*)malloc(sizeof(ma_bool32) * g_decoderCount);
	g_pDecoderLengths = (ma_uint64*)malloc(sizeof(ma_uint64) * g_decoderCount);
	g_pDecodersVolume = (float*)malloc(sizeof(*g_pDecodersVolume)      * g_decoderCount);

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