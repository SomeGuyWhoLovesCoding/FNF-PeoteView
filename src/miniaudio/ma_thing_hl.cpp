#define HL_NAME(n) ma_thing_##n

#include <hl.h>
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
HL_PRIM int HL_NAME(detectLatency)(_NO_ARG) {
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
HL_PRIM void HL_NAME(deactivate_decoder_hl)(int index) { 
    if (index >= 0 && (ma_uint32)index < g_decoderCount) g_pDecodersActive[index] = MA_FALSE; 
}

HL_PRIM void HL_NAME(amplify_decoder_hl)(int index, double volume) { 
    if (index >= 0 && (ma_uint32)index < g_decoderCount) g_pDecodersVolume[index] = static_cast<float>(volume); 
}

HL_PRIM void HL_NAME(setPlaybackRate)(float value) {
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

// -------------------- PLAYBACK HANDLING --------------------
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
            target = len;
        } else {
            target = pos;
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

HL_PRIM double HL_NAME(get_duration)(_NO_ARG) {
    ma_uint64 length = g_pDecoderLengths[g_pLongestDecoderIndex];
    return (double)length / (SAMPLE_RATE * 0.001);
}

HL_PRIM double HL_NAME(get_playback_position)(_NO_ARG) {
    ma_uint64 pos = 0;
    ensure_mutex();
    ma_mutex_lock(&decoderMutex);
    if (g_pDecodersActive[g_pLongestDecoderIndex] == MA_TRUE) {
        ma_decoder_get_cursor_in_pcm_frames(&g_pDecoders[g_pLongestDecoderIndex], &pos);
    } else {
        pos = g_pDecoderLengths[g_pLongestDecoderIndex];
    }
    ma_mutex_unlock(&decoderMutex);
    return ((double)pos / (SAMPLE_RATE * 0.001));
}

// -------------------- PLAYBACK CONTROL --------------------
HL_PRIM void HL_NAME(start)(_NO_ARG) { 
    if (!exists) return; 
    if (MIXER_STATE == 3) HL_NAME(seek_to_pcm_frame)(0); 
    ma_device_start(&device); 
}

HL_PRIM void HL_NAME(stop)(_NO_ARG) { 
    if (!exists) return; 
    ma_device_stop(&device); 
    MIXER_STATE = 2; 
}

HL_PRIM bool HL_NAME(stopped)(_NO_ARG) { 
    return MIXER_STATE == 3; 
}

// -------------------- CLEANUP --------------------
void freeThingies() {
    if (g_pDecodersVolume) { free(g_pDecodersVolume); g_pDecodersVolume = nullptr; }
    if (g_pDecoders) { free(g_pDecoders); g_pDecoders = nullptr; }
    if (g_pDecodersActive) { free(g_pDecodersActive); g_pDecodersActive = nullptr; }
    if (g_pDecoderLengths) { free(g_pDecoderLengths); g_pDecoderLengths = nullptr; }
}

HL_PRIM void HL_NAME(destroy)(_NO_ARG) {
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
HL_PRIM void HL_NAME(loadFiles)(varray* argv) {
    if (argv->size == 0) { printf("No input files.\n"); return; }

    g_decoderCount = static_cast<ma_uint32>(argv->size);

    g_pDecoders = (ma_decoder*)malloc(sizeof(*g_pDecoders) * g_decoderCount);
    g_pDecodersActive = (ma_bool32*)malloc(sizeof(ma_bool32) * g_decoderCount);
    g_pDecoderLengths = (ma_uint64*)malloc(sizeof(ma_uint64) * g_decoderCount);
    g_pDecodersVolume = (float*)malloc(sizeof(*g_pDecodersVolume) * g_decoderCount);

    ma_uint64 maxLength = 0;
    g_pLongestDecoderIndex = 0;

    decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

    for (ma_uint32 i = 0; i < g_decoderCount; ++i) {
        const char* path = hl_aptr(argv, const char*)[i];
        g_pDecodersVolume[i] = 1.0f;

        ma_result result = ma_decoder_init_file(path, &decoderConfig, &g_pDecoders[i]);
        if (result != MA_SUCCESS) {
            for (ma_uint32 j = 0; j < i; ++j) ma_decoder_uninit(&g_pDecoders[j]);
            freeThingies();
            printf("Failed to load %s.\n", path); 
            exists = 0; 
            return;
        }
        
        ma_data_source_set_looping(&g_pDecoders[i], MA_FALSE);
        g_pDecodersActive[i] = MA_TRUE;
        ma_decoder_get_length_in_pcm_frames(&g_pDecoders[i], &g_pDecoderLengths[i]);
        
        if (g_pDecoderLengths[i] > maxLength) { 
            maxLength = g_pDecoderLengths[i]; 
            g_pLongestDecoderIndex = i; 
        }
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
    updateCurrentDeviceInfo();
}

// -------------------- GLOBAL VOLUME --------------------
HL_PRIM double HL_NAME(getGlobalVolume)(_NO_ARG) { 
    return masterVolume; 
}

HL_PRIM double HL_NAME(setGlobalVolume)(double value) { 
    masterVolume = value; 
    return masterVolume; 
}

// -------------------- MIXER STATE --------------------
HL_PRIM int HL_NAME(get_mixer_state)(_NO_ARG) {
    return MIXER_STATE;
}

// -------------------- DEFINE HASHLINK BINDINGS --------------------
DEFINE_PRIM(_I32, detectLatency, _NO_ARG);
DEFINE_PRIM(_VOID, deactivate_decoder_hl, _I32);
DEFINE_PRIM(_VOID, amplify_decoder_hl, _I32 _F64);
DEFINE_PRIM(_VOID, setPlaybackRate, _F32);
DEFINE_PRIM(_VOID, start, _NO_ARG);
DEFINE_PRIM(_VOID, stop, _NO_ARG);
DEFINE_PRIM(_BOOL, stopped, _NO_ARG);
DEFINE_PRIM(_VOID, seek_to_pcm_frame, _I64);
DEFINE_PRIM(_F64, get_duration, _NO_ARG);
DEFINE_PRIM(_F64, get_playback_position, _NO_ARG);
DEFINE_PRIM(_VOID, destroy, _NO_ARG);
DEFINE_PRIM(_VOID, loadFiles, _ARR);
DEFINE_PRIM(_F64, getGlobalVolume, _NO_ARG);
DEFINE_PRIM(_F64, setGlobalVolume, _F64);
DEFINE_PRIM(_I32, get_mixer_state, _NO_ARG);