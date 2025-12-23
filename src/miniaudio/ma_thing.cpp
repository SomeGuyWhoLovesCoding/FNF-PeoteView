#include "include/ma_thing.h"
#include "signalsmith-stretch/signalsmith-stretch.h"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdio.h>
#include <vector>
#include <stdint.h>
#include <string>
#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <mutex>
#include <chrono>
#include <unordered_set>

#ifdef HX_WINDOWS
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <locale>
#include <codecvt>
#pragma comment(lib, "ole32.lib")

static std::string wstring_to_string(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(),
                                          nullptr, 0, nullptr, nullptr);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(),
                       &strTo[0], size_needed, nullptr, nullptr);
    return strTo;
}

bool checkWindowsHeadphoneStatus() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return false;

    bool isHeadphones = false;
    IMMDeviceEnumerator* pEnumerator = nullptr;
    IMMDevice* pDevice = nullptr;
    IPropertyStore* pProps = nullptr;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator);
    if (SUCCEEDED(hr) && pEnumerator) {
        if (SUCCEEDED(pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice)) && pDevice) {
            if (SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps)) && pProps) {
                PROPVARIANT varName;
                PropVariantInit(&varName);
                const PROPERTYKEY* propertyKeys[] = {&PKEY_Device_DeviceDesc, &PKEY_Device_FriendlyName};

                for (int i = 0; i < 2 && !isHeadphones; ++i) {
                    if (SUCCEEDED(pProps->GetValue(*propertyKeys[i], &varName)) && varName.vt == VT_LPWSTR && varName.pwszVal) {
                        std::string name = wstring_to_string(varName.pwszVal);
                        std::transform(name.begin(), name.end(), name.begin(), ::tolower);

                        const char* keywords[] = {"headphone", "headset", "earphone", "earbud",
                                                 "airpod", "bluetooth", "bt", "wireless", "ear piece"};
                        for (const char* kw : keywords) {
                            if (name.find(kw) != std::string::npos) { isHeadphones = true; break; }
                        }
                    }
                    PropVariantClear(&varName);
                }
                pProps->Release();
            }
            pDevice->Release();
        }
        pEnumerator->Release();
    }
    CoUninitialize();
    return isHeadphones;
}
#endif

// -------------------- CONFIG --------------------
#define SAMPLE_FORMAT   ma_format_f32
#define CHANNEL_COUNT   2
#define SAMPLE_RATE     44100

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

ma_uint32   g_decoderCount;
ma_decoder* g_pDecoders = nullptr;
ma_bool32*  g_pDecodersActive = nullptr;
ma_uint64*  g_pDecoderLengths = nullptr;
float*      g_pDecodersVolume = nullptr;
int         g_pLongestDecoderIndex;
float       playbackRate = 1;
double      masterVolume = 1;

int MIXER_STATE = 3; // 0=UNDEF, 1=PLAYING, 2=STOPPED, 3=FINISHED
int exists = 0;

ma_result result;
ma_decoder_config decoderConfig;
ma_device_config  deviceConfig;
ma_device         device;
ma_bool32 deviceExists = MA_FALSE;
ma_uint32 iDecoder;
ma_context gDevicesContext;
ma_bool32 gDevicesContextInitialized = MA_FALSE;

ma_mutex decoderMutex;
ma_bool32 decoderMutexInitialized = MA_FALSE;

// -------------------- HEADPHONE DETECTION --------------------
static const std::unordered_set<std::string> headphoneKeywords = {
    "headphone", "headset", "earphone", "earbud",
    "airpod", "bluetooth", "bt", "wireless", "ear piece"
};

static inline std::string toLower(const std::string& s) {
    std::string out = s;
    std::transform(out.begin(), out.end(), out.begin(), ::tolower);
    return out;
}

bool isHeadphoneDevice(const ma_device_info& deviceInfo) {
    if (!deviceInfo.name) return false;
    std::string nameLower = toLower(deviceInfo.name);
    for (const auto& kw : headphoneKeywords)
        if (nameLower.find(kw) != std::string::npos) return true;
    return false;
}

static std::string currentDeviceName;
static std::mutex deviceInfoMutex;
static std::atomic<int> deviceChangeCounter{0};

static void updateCurrentDeviceInfo() {
    std::lock_guard<std::mutex> lock(deviceInfoMutex);
    if (deviceExists) {
        currentDeviceName = device.playback.name[0] != '\0' ? device.playback.name : "Unknown Device";
    }
}

bool checkIfUsingHeadphones() {
    if (!deviceExists) return false;

    static auto lastCheckTime = std::chrono::steady_clock::now();
    static bool cachedResult = false;

    auto now = std::chrono::steady_clock::now();
    if (deviceChangeCounter.load() != 0 || now - lastCheckTime > std::chrono::seconds(2)) {
        lastCheckTime = now;
        updateCurrentDeviceInfo();

        bool result = false;
        {
            std::lock_guard<std::mutex> lock(deviceInfoMutex);
            std::string nameLower = toLower(currentDeviceName);
            for (const auto& kw : headphoneKeywords)
                if (nameLower.find(kw) != std::string::npos) { result = true; break; }
        }

#ifdef HX_WINDOWS
        if (!result) result = checkWindowsHeadphoneStatus();
#endif
        cachedResult = result;
    }

    return cachedResult;
}

// -------------------- LATENCY --------------------
int detectLatency() {
    int osMs = 95;
    if (deviceExists) {
        osMs += static_cast<int>(device.playback.internalPeriodSizeInFrames / (SAMPLE_RATE * 0.001));
        if (checkIfUsingHeadphones()) osMs += 20;
    }
    return osMs;
}

// -------------------- MUTEX --------------------
static inline void ensure_mutex() {
    if (!decoderMutexInitialized) {
        ma_mutex_init(&decoderMutex);
        decoderMutexInitialized = MA_TRUE;
    }
}

// -------------------- DECODER HELPERS --------------------
ma_uint32 read_pcm_frames_f32(ma_uint32 index, float* pBuffer, ma_uint32 frameCount) {
    ma_decoder* pDecoder = &g_pDecoders[index];
    constexpr ma_uint32 tempCapInFrames = 4096 / CHANNEL_COUNT;
    float temp[4096] = {};
    ma_uint32 totalFramesRead = 0;

    while (totalFramesRead < frameCount) {
        ma_uint32 framesToRead = std::min<ma_uint32>(frameCount - totalFramesRead, tempCapInFrames);
        ma_uint64 framesReadThisIteration = 0;
        if (ma_decoder_read_pcm_frames(pDecoder, temp, framesToRead, &framesReadThisIteration) != MA_SUCCESS || framesReadThisIteration == 0)
            break;

        float volume = g_pDecodersVolume[index] * static_cast<float>(masterVolume);
        for (ma_uint64 i = 0; i < framesReadThisIteration * CHANNEL_COUNT; ++i)
            pBuffer[totalFramesRead * CHANNEL_COUNT + i] += temp[i] * volume;

        totalFramesRead += static_cast<ma_uint32>(framesReadThisIteration);
        if (framesReadThisIteration < framesToRead) break;
    }
    return totalFramesRead;
}

static inline bool any_active() {
    for (ma_uint32 i = 0; i < g_decoderCount; ++i)
        if (g_pDecodersActive[i]) return true;
    return false;
}

// -------------------- AUDIO CALLBACK --------------------
void data_callback(ma_device* pDevice, void* pOutput, const void* /*pInput*/, ma_uint32 frameCount) {
    float* out = reinterpret_cast<float*>(pOutput);
    MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);

    if (!any_active()) { std::fill(out, out + frameCount * CHANNEL_COUNT, 0.0f); MIXER_STATE = 3; return; }

    if (playbackRate == 1.0f) {
        std::fill(out, out + frameCount * CHANNEL_COUNT, 0.0f);
        for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
            if (!g_pDecodersActive[i]) continue;
            ensure_mutex();
            ma_mutex_lock(&decoderMutex);
            ma_uint32 framesRead = read_pcm_frames_f32(i, out, frameCount);
            ma_mutex_unlock(&decoderMutex);
            if (framesRead == 0) g_pDecodersActive[i] = MA_FALSE;
        }
    } else {
        static thread_local std::vector<float> inputMix(4096 * CHANNEL_COUNT, 0.0f);
        static thread_local std::vector<float> stretchedOutput(4096 * CHANNEL_COUNT, 0.0f);

        ma_uint32 maxFramesToRead = std::min<ma_uint32>(static_cast<ma_uint32>(frameCount * playbackRate), 4096u);
        std::fill(inputMix.begin(), inputMix.begin() + maxFramesToRead * CHANNEL_COUNT, 0.0f);

        for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
            if (!g_pDecodersActive[i]) continue;
            ensure_mutex();
            ma_mutex_lock(&decoderMutex);
            ma_uint32 framesRead = read_pcm_frames_f32(i, inputMix.data(), maxFramesToRead);
            ma_mutex_unlock(&decoderMutex);
            if (framesRead == 0) g_pDecodersActive[i] = MA_FALSE;
        }

        if (any_active()) {
            if (!stretch) { stretch = new signalsmith::stretch::SignalsmithStretch(); stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE); }
            stretch->process(inputMix.data(), maxFramesToRead, stretchedOutput.data(), frameCount);
            std::memcpy(out, stretchedOutput.data(), frameCount * CHANNEL_COUNT * sizeof(float));
        } else std::fill(out, out + frameCount * CHANNEL_COUNT, 0.0f);
    }

    MIXER_STATE = any_active() ? 1 : 3;
}

// -------------------- DECODER CONTROL --------------------
void deactivate_decoder(int index) { if (index < g_decoderCount) g_pDecodersActive[index] = MA_FALSE; }
void amplify_decoder(int index, double volume) { g_pDecodersVolume[index] = static_cast<float>(volume); }

void setPlaybackRate(float value) {
    if (!exists || value == playbackRate) return;
    playbackRate = value;

    ma_decoder* pDecoder = &g_pDecoders[g_pLongestDecoderIndex];
    ma_uint64 cursor = 0;
    if (g_pDecodersActive[g_pLongestDecoderIndex]) {
        ensure_mutex();
        ma_mutex_lock(&decoderMutex);
        ma_decoder_get_cursor_in_pcm_frames(pDecoder, &cursor);
        ma_mutex_unlock(&decoderMutex);
    }

    if (!stretch) { stretch = new signalsmith::stretch::SignalsmithStretch(); stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE); }

    int latencyFrames = std::max<int>(stretch->inputLatency(), 0);
    std::vector<float> latencyData(latencyFrames * CHANNEL_COUNT, 0.0f);

    ensure_mutex();
    ma_mutex_lock(&decoderMutex);
    if (latencyFrames > 0) {
        ma_decoder_read_pcm_frames(pDecoder, latencyData.data(), latencyFrames, nullptr);
        ma_decoder_seek_to_pcm_frame(pDecoder, cursor);
    }
    ma_mutex_unlock(&decoderMutex);

    stretch->seek(latencyData.data(), latencyFrames, playbackRate);
}

// -------------------- PLAYBACK CONTROL --------------------
void start() { if (!exists) return; if (MIXER_STATE == 3) seekToPCMFrame(0); ma_device_start(&device); }
void stop() { if (!exists) return; ma_device_stop(&device); MIXER_STATE = 2; }
bool stopped() { return MIXER_STATE == 3; }

// -------------------- PLAYBACK HANDLING
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

	MIXER_STATE = anyActive ? 2 : 3;
}
double getDuration() {
	ma_uint64 length = g_pDecoderLengths[g_pLongestDecoderIndex];
	return (double)length / (SAMPLE_RATE * 0.001);
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

// -------------------- CLEANUP --------------------
void freeThingies() {
    g_pDecodersVolume ? delete[] g_pDecodersVolume : void();
    g_pDecoders ? delete[] g_pDecoders : void();
    g_pDecodersActive ? delete[] g_pDecodersActive : void();
    g_pDecoderLengths ? delete[] g_pDecoderLengths : void();
}

void destroy() {
    if (!exists) return;
    exists = 0;

    ma_device_uninit(&device);
    deviceExists = MA_FALSE;

    for (ma_uint32 i = 0; i < g_decoderCount; ++i) ma_decoder_uninit(&g_pDecoders[i]);
    freeThingies();

    delete stretch; stretch = nullptr;

    if (decoderMutexInitialized) { ma_mutex_uninit(&decoderMutex); decoderMutexInitialized = MA_FALSE; }
    if (gDevicesContextInitialized) { ma_context_uninit(&gDevicesContext); gDevicesContextInitialized = MA_FALSE; }
}

// -------------------- LOAD FILES --------------------
void loadFiles(std::vector<const char*> argv) {
    if (argv.empty()) { printf("No input files.\n"); return; }

    g_decoderCount = static_cast<ma_uint32>(argv.size());

    std::vector<ma_decoder> decoders(g_decoderCount);
    std::vector<ma_bool32> decodersActive(g_decoderCount, MA_TRUE);
    std::vector<ma_uint64> decoderLengths(g_decoderCount, 0);
    std::vector<float> decodersVolume(g_decoderCount, 1.0f);

    ma_uint64 maxLength = 0;
    g_pLongestDecoderIndex = 0;

    decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

    for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
        ma_result result = ma_decoder_init_file(argv[i], &decoderConfig, &decoders[i]);
        if (result != MA_SUCCESS) {
            for (ma_uint32 j = 0; j < i; ++j) ma_decoder_uninit(&decoders[j]);
            printf("Failed to load %s.\n", argv[i]); exists = 0; return;
        }
        ma_data_source_set_looping(&decoders[i], MA_FALSE);
        ma_decoder_get_length_in_pcm_frames(&decoders[i], &decoderLengths[i]);
        if (decoderLengths[i] > maxLength) { maxLength = decoderLengths[i]; g_pLongestDecoderIndex = i; }
    }

    g_pDecoders = new ma_decoder[g_decoderCount];
    g_pDecodersActive = new ma_bool32[g_decoderCount];
    g_pDecoderLengths = new ma_uint64[g_decoderCount];
    g_pDecodersVolume = new float[g_decoderCount];

    for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
        g_pDecoders[i] = decoders[i];
        g_pDecodersActive[i] = decodersActive[i];
        g_pDecoderLengths[i] = decoderLengths[i];
        g_pDecodersVolume[i] = decodersVolume[i];
    }

    exists = 1;

    deviceConfig = ma_device_config_init(ma_device_type_playback);
    deviceConfig.playback.format = SAMPLE_FORMAT;
    deviceConfig.playback.channels = CHANNEL_COUNT;
    deviceConfig.sampleRate = SAMPLE_RATE;
    deviceConfig.dataCallback = data_callback;
    deviceConfig.pUserData = nullptr;

    if (ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS) {
        for (ma_uint32 i = 0; i < g_decoderCount; ++i) ma_decoder_uninit(&g_pDecoders[i]);
        freeThingies();
        printf("Failed to open playback device.\n");
        return;
    }
    deviceExists = MA_TRUE;
}

// -------------------- GLOBAL VOLUME --------------------
double getGlobalVolume() { return masterVolume; }
double setGlobalVolume(double value) { masterVolume = value; return masterVolume; }

// -------------------- -MIXER STATE ---------------------
int getMixerState() {
	return MIXER_STATE;
}