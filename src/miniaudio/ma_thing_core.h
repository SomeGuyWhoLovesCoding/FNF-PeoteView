#pragma once

/*
 * ma_thing_core.h
 * Shared audio engine core — included by both the standalone build and the
 * HashLink binding.  Nothing in here knows about HashLink or any other host
 * binding layer.
 *
 * Triple-buffered sliding window implementation with proper continuity.
 * RAII implementation - Resources manage their own lifetimes.
 *
 * stb_vorbis is optimized specifically for funkin' view's audio format needs
 * (OGG) whilst leaving WAV, MP3, and FLAC aside.  The modified version also
 * fixes waiting on seeking backwards due to new logic that optimizes it on
 * the fly.
 */

// ---- platform / library includes -----------------------------------------
#ifdef HX_WINDOWS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <locale>
#include <codecvt>
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#elif _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#if __SSE__
#include <immintrin.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif
#include "extras/stb_vorbis.c"   // included as C, must come before miniaudio
#ifdef __cplusplus
}
#endif

#include "miniaudio.h"

#include <stdio.h>
#include <stdint.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <iostream>

#ifdef __SSE__
#include <emmintrin.h>
#include <xmmintrin.h>
#endif

std::atomic<double> MUSIC_MASTER_VOLUME_099{1.0f};

// ---- Windows audio-device helpers with change detection -----------------

#ifdef HX_WINDOWS

#include <chrono>
#include <thread>

static std::string wstring_to_string(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(),
                                          nullptr, 0, nullptr, nullptr);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(),
                        &strTo[0], size_needed, nullptr, nullptr);
    return strTo;
}

static struct AudioDeviceState {
    bool isPnP = false;
    bool isHeadphones = false;
    std::string deviceName;
    std::string deviceId;
    std::atomic<int64_t> lastCheckTime{0};
    std::atomic<bool> deviceChanged{false};
    std::mutex mutex;
} g_currentDeviceState;

#define DEVICE_CHECK_COOLDOWN_MS 500

static bool refreshDeviceState() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    bool comInitialized = (hr == S_OK || hr == S_FALSE);

    IMMDeviceEnumerator* pEnumerator = nullptr;
    IMMDevice* pDevice = nullptr;
    IPropertyStore* pProps = nullptr;
    LPWSTR pwszDeviceId = nullptr;

    bool newIsPnP = false;
    bool newIsHeadphones = false;
    std::string newDeviceName = "Unknown";
    std::string newDeviceId = "";

    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                                   __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator))) {
        if (SUCCEEDED(pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice))) {

            if (SUCCEEDED(pDevice->GetId(&pwszDeviceId)) && pwszDeviceId) {
                newDeviceId = wstring_to_string(std::wstring(pwszDeviceId));
                CoTaskMemFree(pwszDeviceId);
            }

            if (SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
                PROPVARIANT varName;
                PropVariantInit(&varName);

                if (SUCCEEDED(pProps->GetValue(PKEY_Device_FriendlyName, &varName)) &&
                    varName.vt == VT_LPWSTR && varName.pwszVal) {
                    newDeviceName = wstring_to_string(varName.pwszVal);
                }
                PropVariantClear(&varName);

                if (!newDeviceId.empty()) {
                    std::string id = newDeviceId;
                    std::transform(id.begin(), id.end(), id.begin(), ::tolower);

                    const char* pnpPatterns[] = { "usb#", "hid#", "uefi" };

                    for (const char* pat : pnpPatterns) {
                        if (id.find(pat) != std::string::npos) {
                            newIsPnP = true;
                            break;
                        }
                    }
                }

                if (!newIsPnP) {
                    PROPVARIANT var;
                    PropVariantInit(&var);
                    const PROPERTYKEY* keys[] = { &PKEY_Device_FriendlyName,
                                                  &PKEY_Device_DeviceDesc };

                    for (int i = 0; i < 2 && !newIsPnP; i++) {
                        if (SUCCEEDED(pProps->GetValue(*keys[i], &var)) &&
                            var.vt == VT_LPWSTR && var.pwszVal) {
                            std::string s = wstring_to_string(var.pwszVal);
                            std::transform(s.begin(), s.end(), s.begin(), ::tolower);

                            const char* kws[] = { "usb", "wireless", "external",
                                                  "hdmi", "digital audio", "digital output" };

                            for (const char* k : kws) {
                                if (s.find(k) != std::string::npos) {
                                    newIsPnP = true;
                                    break;
                                }
                            }
                        }
                        PropVariantClear(&var);
                    }
                }

                std::string nameLower = newDeviceName;
                std::transform(nameLower.begin(), nameLower.end(), nameLower.begin(), ::tolower);
                const char* headphoneKws[] = { "headphone", "headset", "earphone", "earbud",
                                               "airpod", "wireless",
                                               "ear piece", "usb audio speakers" };
                for (const char* kw : headphoneKws) {
                    if (nameLower.find(kw) != std::string::npos) {
                        newIsHeadphones = true;
                        break;
                    }
                }

                pProps->Release();
            }
            pDevice->Release();
        }
        pEnumerator->Release();
    }

    std::lock_guard<std::mutex> lock(g_currentDeviceState.mutex);

    bool deviceChanged = (newIsPnP != g_currentDeviceState.isPnP) ||
                         (newIsHeadphones != g_currentDeviceState.isHeadphones) ||
                         (newDeviceName != g_currentDeviceState.deviceName) ||
                         (newDeviceId != g_currentDeviceState.deviceId);

    if (deviceChanged) {
        printf("[Audio] Device changed: %s (PnP: %s, Headphones: %s)\n",
               newDeviceName.c_str(),
               newIsPnP ? "Yes" : "No",
               newIsHeadphones ? "Yes" : "No");

        g_currentDeviceState.isPnP = newIsPnP;
        g_currentDeviceState.isHeadphones = newIsHeadphones;
        g_currentDeviceState.deviceName = newDeviceName;
        g_currentDeviceState.deviceId = newDeviceId;
        g_currentDeviceState.deviceChanged.store(true, std::memory_order_release);
    }

    if (comInitialized) CoUninitialize();

    return deviceChanged;
}

static std::thread g_monitorThread;
static std::atomic<bool> g_monitorRunning{false};
static std::atomic<int64_t> g_lastMonitorTime{0};

static void monitorThreadFunc() {
    while (g_monitorRunning.load(std::memory_order_acquire)) {
        refreshDeviceState();
        g_lastMonitorTime.store(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count(),
            std::memory_order_release);
        std::this_thread::sleep_for(std::chrono::milliseconds(DEVICE_CHECK_COOLDOWN_MS));
    }
}

static void updateDeviceStateIfNeeded() {
    auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();

    if (g_monitorRunning.load(std::memory_order_acquire)) {
        return;
    }

    if (now - g_currentDeviceState.lastCheckTime.load(std::memory_order_acquire) > DEVICE_CHECK_COOLDOWN_MS) {
        refreshDeviceState();
        g_currentDeviceState.lastCheckTime.store(now, std::memory_order_release);
    }
}

inline bool checkIfPnPDevice() {
    std::lock_guard<std::mutex> lock(g_currentDeviceState.mutex);
    return g_currentDeviceState.isPnP;
}

inline bool checkWindowsHeadphoneStatus() {
    std::lock_guard<std::mutex> lock(g_currentDeviceState.mutex);
    return g_currentDeviceState.isHeadphones;
}

inline std::string getCurrentAudioDeviceName() {
    std::lock_guard<std::mutex> lock(g_currentDeviceState.mutex);
    return g_currentDeviceState.deviceName;
}

inline bool didAudioDeviceChange() {
    bool changed = g_currentDeviceState.deviceChanged.load(std::memory_order_acquire);
    if (changed) {
        g_currentDeviceState.deviceChanged.store(false, std::memory_order_release);
    }
    return changed;
}

inline void refreshAudioDeviceState() {
    refreshDeviceState();
    g_currentDeviceState.lastCheckTime.store(
        std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count(),
        std::memory_order_release);
}

inline void startAudioDeviceMonitoring() {
    if (g_monitorRunning.load(std::memory_order_acquire)) return;

    g_monitorRunning.store(true, std::memory_order_release);
    g_monitorThread = std::thread(monitorThreadFunc);

    refreshDeviceState();
}

inline void stopAudioDeviceMonitoring() {
    if (!g_monitorRunning.load(std::memory_order_acquire)) return;

    g_monitorRunning.store(false, std::memory_order_release);
    if (g_monitorThread.joinable()) {
        g_monitorThread.join();
    }
}

#endif // HX_WINDOWS

// ---- audio constants ------------------------------------------------------

#define SAMPLE_FORMAT  ma_format_f32
#define CHANNEL_COUNT  2
#define SAMPLE_RATE    44100

#define PADDING_MS      150
#define BUFFER_MS       750
#define HALF_BUFFER_MS  400

#define PADDING_FRAMES      ((SAMPLE_RATE * PADDING_MS)     / 1000)
#define BUFFER_FRAMES       ((SAMPLE_RATE * BUFFER_MS)      / 1000)
#define HALF_BUFFER_FRAMES  ((SAMPLE_RATE * HALF_BUFFER_MS) / 1000)
#define TOTAL_BUFFER_FRAMES (PADDING_FRAMES + BUFFER_FRAMES + PADDING_FRAMES)

#define MAX_CALLBACK_FRAMES 4096

// ---- SIMD mix helpers (EXISTING CODE KEPT INTACT) -------------------------

#ifdef __SSE__
static inline void mix_simd(float* dst, const float* src, int samples, float volume) {
    int i = 0;
    if (volume == 1.0f) {
        for (; i < samples - 7; i += 8) {
            _mm_storeu_ps(dst + i,     _mm_add_ps(_mm_loadu_ps(dst + i),     _mm_loadu_ps(src + i)));
            _mm_storeu_ps(dst + i + 4, _mm_add_ps(_mm_loadu_ps(dst + i + 4), _mm_loadu_ps(src + i + 4)));
        }
        if (i < samples - 3) {
            _mm_storeu_ps(dst + i, _mm_add_ps(_mm_loadu_ps(dst + i), _mm_loadu_ps(src + i)));
            i += 4;
        }
    } else {
        __m128 vvol = _mm_set1_ps(volume);
        for (; i < samples - 7; i += 8) {
            _mm_storeu_ps(dst + i,     _mm_add_ps(_mm_loadu_ps(dst + i),     _mm_mul_ps(_mm_loadu_ps(src + i),     vvol)));
            _mm_storeu_ps(dst + i + 4, _mm_add_ps(_mm_loadu_ps(dst + i + 4), _mm_mul_ps(_mm_loadu_ps(src + i + 4), vvol)));
        }
        for (; i < samples - 3; i += 4)
            _mm_storeu_ps(dst + i, _mm_add_ps(_mm_loadu_ps(dst + i), _mm_mul_ps(_mm_loadu_ps(src + i), vvol)));
    }
    for (; i < samples; i++) dst[i] += src[i] * volume;
}
static inline void mix_simd_stereo(float* dst, const float* src, int frames, float volume) {
    mix_simd(dst, src, frames * 2, volume);
}
#else
static inline void mix_scalar(float* dst, const float* src, int samples, float volume) {
    if (volume == 1.0f)
        for (int i = 0; i < samples; i++) dst[i] += src[i];
    else
        for (int i = 0; i < samples; i++) dst[i] += src[i] * volume;
}
#endif

// ==========================================================================
//  NEW: Runtime AVX2 Detection & Dispatch (Injected on top of existing code)
// ==========================================================================
#if defined(_MSC_VER)
    #include <intrin.h>
#elif defined(__GNUC__) || defined(__clang__)
    #include <cpuid.h>
#endif

static inline bool has_avx2_runtime() {
#if defined(_MSC_VER)
    int regs[4];
    __cpuidex(regs, 7, 0);
    return (regs[1] & (1 << 5)) != 0; // EBX bit 5 = AVX2
#elif defined(__GNUC__) || defined(__clang__)
    unsigned int eax, ebx, ecx, edx;
    return __get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx) && ((ebx >> 5) & 1);
#else
    return false;
#endif
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2"))) // Allows compiling AVX2 without global -mavx2 flag
#endif
static inline void mix_avx2(float* dst, const float* src, int samples, float volume) {
    //printf("Hi AVX2 penis\n");
    int i = 0;
    if (volume == 1.0f) {
        for (; i + 8 <= samples; i += 8)
            _mm256_storeu_ps(dst + i, _mm256_add_ps(_mm256_loadu_ps(dst + i), _mm256_loadu_ps(src + i)));
    } else {
        __m256 vvol = _mm256_set1_ps(volume);
        for (; i + 8 <= samples; i += 8)
            _mm256_storeu_ps(dst + i, _mm256_add_ps(_mm256_loadu_ps(dst + i), _mm256_mul_ps(_mm256_loadu_ps(src + i), vvol)));
    }
    for (; i < samples; i++) dst[i] += src[i] * volume;
}

// Function pointer defaults to existing SSE if available, otherwise scalar
static void (*g_mix_func)(float*, const float*, int, float) =
#ifdef __SSE__
    mix_simd;
#else
    mix_scalar;
#endif

static void init_simd_dispatch() {
    if (has_avx2_runtime()) {
        g_mix_func = mix_avx2;
    }
}

// ==========================================================================
//  DecoderStream
// ==========================================================================

struct DecoderStream {
    float* pcmBufferA = nullptr;
    float* pcmBufferB = nullptr;
    float* pcmBufferC = nullptr;

    float* activeBuffer  = nullptr;
    float* nextBuffer    = nullptr;
    float* loadingBuffer = nullptr;

    ma_uint64 filePosition   = 0;
    ma_uint64 bufferStartPos = 0;
    ma_uint64 localReadPos   = 0;
    ma_uint64 validFrames    = 0;

    struct AsyncState {
        ma_uint64 nextBufferStartPos        = 0;
        ma_uint64 nextBufferValidFrames     = 0;
        ma_uint64 loadingBufferStartPos     = 0;
        ma_uint64 loadingBufferValidFrames  = 0;

        std::atomic<bool> nextBufferReady{false};
        std::atomic<bool> loadingBufferReady{false};
        std::atomic<bool> loadingInProgress{false};
        std::atomic<bool> needsLoad{false};
        std::atomic<bool> requestNextBuffer{false};
        std::atomic<bool> requestLoadingBuffer{false};

        float* asyncNextBuffer    = nullptr;
        float* asyncLoadingBuffer = nullptr;
    } asyncState;

    bool      active        = false;
    ma_decoder decoder;
    ma_uint64 decoderLength = 0;

    std::mutex decoderMutex;

    DecoderStream()  { memset(&decoder, 0, sizeof(ma_decoder)); }
    ~DecoderStream() { cleanup(); }

    DecoderStream(DecoderStream&& other) noexcept { moveFrom(std::move(other)); }
    DecoderStream& operator=(DecoderStream&& other) noexcept {
        if (this != &other) { cleanup(); moveFrom(std::move(other)); }
        return *this;
    }
    DecoderStream(const DecoderStream&)            = delete;
    DecoderStream& operator=(const DecoderStream&) = delete;

    bool trySwapBuffers() {
        if (!asyncState.nextBufferReady.load(std::memory_order_acquire))
            return false;

        ma_uint64 currentGlobalPos = bufferStartPos + localReadPos;

        float* oldActive  = activeBuffer;
        float* oldNext    = nextBuffer;
        float* oldLoading = loadingBuffer;

        activeBuffer  = oldNext;
        nextBuffer    = oldLoading;
        loadingBuffer = oldActive;

        bufferStartPos = asyncState.nextBufferStartPos;
        validFrames    = asyncState.nextBufferValidFrames;

        asyncState.nextBufferStartPos       = asyncState.loadingBufferStartPos;
        asyncState.nextBufferValidFrames    = asyncState.loadingBufferValidFrames;
        asyncState.loadingBufferStartPos    = 0;
        asyncState.loadingBufferValidFrames = 0;

        asyncState.nextBufferReady.store(
            asyncState.loadingBufferReady.load(std::memory_order_relaxed),
            std::memory_order_release);
        asyncState.loadingBufferReady.store(false, std::memory_order_release);

        asyncState.asyncNextBuffer    = oldLoading;
        asyncState.asyncLoadingBuffer = oldActive;

        if (currentGlobalPos >= bufferStartPos &&
            currentGlobalPos <  bufferStartPos + validFrames)
            localReadPos = currentGlobalPos - bufferStartPos;
        else if (currentGlobalPos < bufferStartPos)
            localReadPos = 0;
        else
            localReadPos = std::min<ma_uint64>(validFrames, (ma_uint64)TOTAL_BUFFER_FRAMES);

        if (localReadPos >= TOTAL_BUFFER_FRAMES)
            localReadPos = TOTAL_BUFFER_FRAMES - 1;

        asyncState.requestLoadingBuffer.store(true, std::memory_order_release);
        return true;
    }

    void resetState() {
        asyncState.nextBufferReady.store(false,       std::memory_order_release);
        asyncState.loadingBufferReady.store(false,    std::memory_order_release);
        asyncState.loadingInProgress.store(false,     std::memory_order_release);
        asyncState.needsLoad.store(false,             std::memory_order_release);
        asyncState.requestNextBuffer.store(false,     std::memory_order_release);
        asyncState.requestLoadingBuffer.store(false,  std::memory_order_release);

        asyncState.nextBufferValidFrames    = 0;
        asyncState.loadingBufferValidFrames = 0;
        asyncState.nextBufferStartPos       = 0;
        asyncState.loadingBufferStartPos    = 0;

        filePosition = bufferStartPos = localReadPos = validFrames = 0;

        if (pcmBufferA) memset(pcmBufferA, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
        if (pcmBufferB) memset(pcmBufferB, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
        if (pcmBufferC) memset(pcmBufferC, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
    }

    bool shouldSwapBuffers() const {
        if (localReadPos >= validFrames) return true;
        if (localReadPos >= (PADDING_FRAMES + HALF_BUFFER_FRAMES) &&
            asyncState.nextBufferReady.load(std::memory_order_acquire))
            return true;
        return false;
    }

    bool isBufferLow() const {
        ma_uint64 available = (localReadPos < validFrames) ? (validFrames - localReadPos) : 0;
        return available < (HALF_BUFFER_FRAMES / 2);
    }

    void requestBufferLoad() {
        if (!asyncState.nextBufferReady.load(std::memory_order_relaxed) &&
            !asyncState.loadingInProgress.load(std::memory_order_relaxed))
            asyncState.requestNextBuffer.store(true, std::memory_order_release);
    }

    void fillBuffer(float* buffer, ma_uint64 decodeStart, ma_uint64* framesRead) {
        ma_uint64 maxFrames = TOTAL_BUFFER_FRAMES;
        if (decodeStart + TOTAL_BUFFER_FRAMES > decoderLength)
            maxFrames = decoderLength - decodeStart;

        memset(buffer, 0, maxFrames * CHANNEL_COUNT * sizeof(float));

        if (maxFrames > 0) {
            ma_decoder_seek_to_pcm_frame(&decoder, decodeStart);
            ma_decoder_read_pcm_frames(&decoder, buffer, maxFrames, framesRead);
        } else {
            *framesRead = 0;
        }
    }

    void fillBufferAsync(ma_uint64 decodeStart, float* buffer, ma_uint64* framesRead) {
        ma_uint64 maxFrames = TOTAL_BUFFER_FRAMES;
        if (decodeStart + TOTAL_BUFFER_FRAMES > decoderLength)
            maxFrames = decoderLength - decodeStart;

        memset(buffer, 0, maxFrames * CHANNEL_COUNT * sizeof(float));

        if (maxFrames > 0) {
            std::lock_guard<std::mutex> lock(decoderMutex);
            ma_decoder_seek_to_pcm_frame(&decoder, decodeStart);
            ma_decoder_read_pcm_frames(&decoder, buffer, maxFrames, framesRead);
        } else {
            *framesRead = 0;
        }
    }

private:
    void cleanup() {
        if (decoder.onRead != nullptr || decoder.onSeek != nullptr)
            ma_decoder_uninit(&decoder);

        if (pcmBufferA) { free(pcmBufferA); pcmBufferA = nullptr; }
        if (pcmBufferB) { free(pcmBufferB); pcmBufferB = nullptr; }
        if (pcmBufferC) { free(pcmBufferC); pcmBufferC = nullptr; }

        activeBuffer = nextBuffer = loadingBuffer = nullptr;
        asyncState.asyncNextBuffer = asyncState.asyncLoadingBuffer = nullptr;
    }

    void moveFrom(DecoderStream&& other) noexcept {
        pcmBufferA    = other.pcmBufferA;
        pcmBufferB    = other.pcmBufferB;
        pcmBufferC    = other.pcmBufferC;
        activeBuffer  = other.activeBuffer;
        nextBuffer    = other.nextBuffer;
        loadingBuffer = other.loadingBuffer;

        memcpy(&decoder, &other.decoder, sizeof(ma_decoder));

        filePosition   = other.filePosition;
        bufferStartPos = other.bufferStartPos;
        localReadPos   = other.localReadPos;
        validFrames    = other.validFrames;
        active         = other.active;
        decoderLength  = other.decoderLength;

        asyncState.nextBufferStartPos       = other.asyncState.nextBufferStartPos;
        asyncState.nextBufferValidFrames    = other.asyncState.nextBufferValidFrames;
        asyncState.loadingBufferStartPos    = other.asyncState.loadingBufferStartPos;
        asyncState.loadingBufferValidFrames = other.asyncState.loadingBufferValidFrames;
        asyncState.asyncNextBuffer          = other.asyncState.asyncNextBuffer;
        asyncState.asyncLoadingBuffer       = other.asyncState.asyncLoadingBuffer;

        other.pcmBufferA = other.pcmBufferB = other.pcmBufferC = nullptr;
        other.activeBuffer = other.nextBuffer = other.loadingBuffer = nullptr;
        other.asyncState.asyncNextBuffer = other.asyncState.asyncLoadingBuffer = nullptr;
        memset(&other.decoder, 0, sizeof(ma_decoder));
    }
};

// ==========================================================================
//  AsyncLoader
// ==========================================================================

class AsyncLoader {
public:
    explicit AsyncLoader(std::vector<DecoderStream*>& streamRefs)
        : streams(streamRefs) { 
        start(); 
    }

    ~AsyncLoader() { 
        stop(); 
    }

    void pauseLoading() { 
        pause.store(true, std::memory_order_release);
        signal();  
    }

    void resumeLoading() {
        pause.store(false, std::memory_order_release);
        signal();
    }

    void signal() {
        workPending.store(true, std::memory_order_release);
        wakeCV.notify_one();
    }

    void waitUntilIdle() {
        if (!running.load(std::memory_order_acquire)) return;
        
        signal();
        
        auto startTime = std::chrono::steady_clock::now();
        const auto timeout = std::chrono::milliseconds(100);
        
        while (!workerIdle.load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() - startTime > timeout) {
                break;
            }
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
        
        std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
    
    bool isRunning() const {
        return running.load(std::memory_order_acquire);
    }

private:
    std::vector<DecoderStream*>& streams;
    std::thread       workerThread;
    std::atomic<bool> running{false};
    std::atomic<bool> pause{false};
    std::atomic<bool> workerIdle{false};
    std::atomic<bool> stopRequested{false};  
    std::mutex        wakeMutex;
    std::condition_variable wakeCV;
    std::atomic<bool> workPending{false};

    void start() {
        if (running.load(std::memory_order_acquire)) return;
        
        running.store(true, std::memory_order_release);
        stopRequested.store(false, std::memory_order_release);
        
        try {
            workerThread = std::thread([this]() { worker(); });
        } catch (const std::exception& e) {
            running.store(false, std::memory_order_release);
        }
    }

    void stop() {
        if (!running.load(std::memory_order_acquire)) return;
        
        stopRequested.store(true, std::memory_order_release);
        running.store(false, std::memory_order_release);
        
        signal();
        std::this_thread::sleep_for(std::chrono::microseconds(100));
        signal();
        
        if (workerThread.joinable()) {
            workerThread.join();
        }
        
        {
            std::lock_guard<std::mutex> lock(wakeMutex);
            workPending.store(false, std::memory_order_release);
        }
    }

    void worker() {
        constexpr int MAX_PER_CYCLE = 2;
        int currentStream = 0;

        while (running.load(std::memory_order_acquire)) {
            if (stopRequested.load(std::memory_order_acquire)) {
                break;
            }
            
            if (pause.load(std::memory_order_acquire) && !stopRequested.load(std::memory_order_acquire)) {
                workerIdle.store(true, std::memory_order_release);
                std::unique_lock<std::mutex> lk(wakeMutex);
                wakeCV.wait_for(lk, std::chrono::milliseconds(10), [this] {
                    return !pause.load(std::memory_order_acquire) ||
                           stopRequested.load(std::memory_order_acquire) ||
                           !running.load(std::memory_order_acquire);
                });
                workerIdle.store(false, std::memory_order_release);
                continue;
            }

            if (streams.empty()) {
                workerIdle.store(true, std::memory_order_release);
                std::unique_lock<std::mutex> lk(wakeMutex);
                wakeCV.wait_for(lk, std::chrono::milliseconds(10), [this] {
                    return !streams.empty() || 
                           stopRequested.load(std::memory_order_acquire) ||
                           !running.load(std::memory_order_acquire);
                });
                workerIdle.store(false, std::memory_order_release);
                continue;
            }

            workPending.store(false, std::memory_order_release);

            int processed = 0;
            size_t streamCount = streams.size();
            
            for (int i = 0; i < (int)streamCount && processed < MAX_PER_CYCLE; i++) {
                if (stopRequested.load(std::memory_order_acquire) || !running.load(std::memory_order_acquire)) {
                    break;
                }
                
                int idx = (currentStream + i) % (int)streamCount;
                DecoderStream* s = nullptr;
                
                if (idx >= 0 && idx < (int)streams.size()) {
                    s = streams[idx];
                }
                
                if (s && s->active) {
                    if (processStreamLoad(s)) {
                        processed++;
                    }
                }
            }

            if (processed > 0) {
                currentStream = (currentStream + 1) % (int)streamCount;
            }

            if (processed == 0 && !stopRequested.load(std::memory_order_acquire)) {
                workerIdle.store(true, std::memory_order_release);
                std::unique_lock<std::mutex> lk(wakeMutex);
                wakeCV.wait_for(lk, std::chrono::milliseconds(5), [this] {
                    return workPending.load(std::memory_order_acquire) ||
                           stopRequested.load(std::memory_order_acquire) ||
                           !running.load(std::memory_order_acquire) ||
                           pause.load(std::memory_order_acquire);
                });
                workerIdle.store(false, std::memory_order_release);
            }
        }
    }

    bool processStreamLoad(DecoderStream* s) {
        if (!s) return false;
        
        bool didWork = false;

        if (s->asyncState.requestNextBuffer.load(std::memory_order_acquire)) {
            if (!s->asyncState.loadingInProgress.load(std::memory_order_relaxed)) {
                if (tryLoadNextBuffer(s)) {
                    didWork = true;
                }
            }
            s->asyncState.requestNextBuffer.store(false, std::memory_order_release);
        }

        if (s->asyncState.requestLoadingBuffer.load(std::memory_order_acquire)) {
            if (!s->asyncState.loadingInProgress.load(std::memory_order_relaxed) &&
                s->asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
                if (tryLoadLoadingBuffer(s)) {
                    didWork = true;
                }
            }
            s->asyncState.requestLoadingBuffer.store(false, std::memory_order_release);
        }

        return didWork;
    }

    bool tryLoadNextBuffer(DecoderStream* s) {
        if (!s) return false;
        if (stopRequested.load(std::memory_order_acquire)) return false;
        
        bool expected = false;
        if (!s->asyncState.loadingInProgress.compare_exchange_strong(
                expected, true, std::memory_order_acq_rel)) {
            return false;
        }

        if (stopRequested.load(std::memory_order_acquire)) {
            s->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 start = s->bufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;

        if (start >= s->decoderLength || !s->asyncState.asyncNextBuffer) {
            s->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 framesRead = 0;
        s->fillBufferAsync(start, s->asyncState.asyncNextBuffer, &framesRead);

        if (!stopRequested.load(std::memory_order_acquire) && running.load(std::memory_order_acquire)) {
            s->asyncState.nextBufferStartPos    = start;
            s->asyncState.nextBufferValidFrames = framesRead;
            s->asyncState.nextBufferReady.store(true, std::memory_order_release);
        }
        
        s->asyncState.loadingInProgress.store(false, std::memory_order_release);
        return true;
    }

    bool tryLoadLoadingBuffer(DecoderStream* s) {
        if (!s) return false;
        if (stopRequested.load(std::memory_order_acquire)) return false;
        
        bool expected = false;
        if (!s->asyncState.loadingInProgress.compare_exchange_strong(
                expected, true, std::memory_order_acq_rel)) {
            return false;
        }

        if (stopRequested.load(std::memory_order_acquire)) {
            s->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 start = s->asyncState.nextBufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;

        if (start >= s->decoderLength || !s->asyncState.asyncLoadingBuffer) {
            s->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 framesRead = 0;
        s->fillBufferAsync(start, s->asyncState.asyncLoadingBuffer, &framesRead);

        if (!stopRequested.load(std::memory_order_acquire) && running.load(std::memory_order_acquire)) {
            s->asyncState.loadingBufferStartPos    = start;
            s->asyncState.loadingBufferValidFrames = framesRead;
            s->asyncState.loadingBufferReady.store(true, std::memory_order_release);
        }
        
        s->asyncState.loadingInProgress.store(false, std::memory_order_release);
        return true;
    }
};

// ==========================================================================
//  AudioSystem
// ==========================================================================

class AudioSystem {
public:
    std::vector<DecoderStream> streams;
    std::vector<float>         decoderVolumes;
    std::vector<std::string>   filePaths;

    ma_device device;
    signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

    int   longestDecoderIndex = 0;
    float playbackRate        = 1.0f;
    int   mixerState          = 3;
    bool  exists              = false;

    float pitchInputMix[MAX_CALLBACK_FRAMES * CHANNEL_COUNT]      = {};
    float pitchStretchedOut[MAX_CALLBACK_FRAMES * CHANNEL_COUNT]  = {};

    static constexpr int BG_LOAD_CHECK_INTERVAL = 8;
    int bgLoadCounter = 0;

    AudioSystem()  {
        memset(&device, 0, sizeof(ma_device));
        
        // NEW: Initialize SIMD dispatch on startup
        init_simd_dispatch(); 
        
        #if HX_WINDOWS
        startAudioDeviceMonitoring();
        #endif
    }
    ~AudioSystem() {
        #if HX_WINDOWS
        stopAudioDeviceMonitoring();
        #endif
        destroy();
    }

    AudioSystem(AudioSystem&& other) noexcept { moveFrom(std::move(other)); }
    AudioSystem& operator=(AudioSystem&& other) noexcept {
        if (this != &other) { destroy(); moveFrom(std::move(other)); }
        return *this;
    }
    AudioSystem(const AudioSystem&)            = delete;
    AudioSystem& operator=(const AudioSystem&) = delete;

    void loadFiles(std::vector<const char*> argv) {
        if (argv.empty()) { printf("No input files.\n"); return; }

        destroy();

        filePaths.clear();
        for (auto p : argv) filePaths.push_back(p);

        streams.resize(argv.size());
        decoderVolumes.resize(argv.size(), 1.0f);

        ma_uint64 longestLength = 0;
        ma_decoder_config decoderConfig =
            ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

        for (size_t i = 0; i < argv.size(); i++) {
            DecoderStream& s = streams[i];

            if (ma_decoder_init_file(argv[i], &decoderConfig, &s.decoder) != MA_SUCCESS) {
                for (size_t j = 0; j < i; j++) ma_decoder_uninit(&streams[j].decoder);
                streams.clear(); decoderVolumes.clear(); filePaths.clear();
                printf("Failed to load %s.\n", argv[i]);
                exists = false;
                return;
            }

            ma_data_source_set_looping(&s.decoder, MA_FALSE);
            ma_decoder_get_length_in_pcm_frames(&s.decoder, &s.decoderLength);

            s.pcmBufferA = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
            s.pcmBufferB = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
            s.pcmBufferC = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
            memset(s.pcmBufferA, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
            memset(s.pcmBufferB, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
            memset(s.pcmBufferC, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);

            s.activeBuffer  = s.pcmBufferA;
            s.nextBuffer    = s.pcmBufferB;
            s.loadingBuffer = s.pcmBufferC;
            s.asyncState.asyncNextBuffer    = s.pcmBufferB;
            s.asyncState.asyncLoadingBuffer = s.pcmBufferC;

            fillInitialBuffer(i, 0);

            if (s.active) {
                loadNextBufferSync(i);
                if (s.asyncState.nextBufferReady.load(std::memory_order_relaxed))
                    loadLoadingBufferSync(i);
            }

            if (s.decoderLength > longestLength) {
                longestLength = s.decoderLength;
                longestDecoderIndex = (int)i;
            }
        }

        streamPtrs.clear();
        for (auto& s : streams) streamPtrs.push_back(&s);
        if (asyncLoader) delete asyncLoader;
        asyncLoader = new AsyncLoader(streamPtrs);

        ma_device_config deviceConfig = ma_device_config_init(ma_device_type_playback);
        deviceConfig.playback.format   = SAMPLE_FORMAT;
        deviceConfig.playback.channels = CHANNEL_COUNT;
        deviceConfig.sampleRate        = SAMPLE_RATE;
        deviceConfig.dataCallback      = data_callback;
        deviceConfig.pUserData         = this;

        if (ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS) {
            streams.clear(); decoderVolumes.clear(); filePaths.clear();
            printf("Failed to open playback device.\n");
            return;
        }

        exists    = true;
        mixerState = 3;
    }

    void destroy() {
        if (!exists) return;
        
        exists = false;
        ma_device_stop(&device);
        
        if (asyncLoader) {
            delete asyncLoader;
            asyncLoader = nullptr;
        }
        
        ma_device_uninit(&device);
        
        streams.clear();
        decoderVolumes.clear();
        filePaths.clear();
        streamPtrs.clear();
        
        if (stretch) {
            delete stretch;
            stretch = nullptr;
        }
        
        longestDecoderIndex = 0;
        playbackRate = 1.0f;
        mixerState = 3;
        
        memset(&device, 0, sizeof(ma_device));
    }

    void start() {
        if (!exists) return;
        if (mixerState == 3) seekToPCMFrame(0);
        if (asyncLoader) asyncLoader->resumeLoading();
        ma_device_start(&device);
        mixerState = 1;
    }

    void stop() {
        if (!exists) return;
        if (asyncLoader) asyncLoader->pauseLoading();
        ma_device_stop(&device);
        mixerState = 2;
    }

    bool stopped() const { return mixerState == 3; }

    void seekToPCMFrame(int64_t pos) {
        if (!exists) return;

        if (asyncLoader) asyncLoader->pauseLoading();
        if (asyncLoader) asyncLoader->waitUntilIdle();

        bool wasPlaying = (mixerState == 1);
        if (wasPlaying) ma_device_stop(&device);

        for (size_t i = 0; i < streams.size(); i++) {
            DecoderStream& s = streams[i];
            ma_uint64 target = std::min<ma_uint64>(
                (ma_uint64)std::max<int64_t>(pos, 0), s.decoderLength);

            s.resetState();
            fillInitialBuffer(i, target);
            if (s.active && target < s.decoderLength) s.filePosition = target;

            if (s.active) {
                loadNextBufferSync(i);
                if (s.asyncState.nextBufferReady.load(std::memory_order_relaxed))
                    loadLoadingBufferSync(i);
            }
        }

        mixerState = (pos < (int64_t)streams[longestDecoderIndex].decoderLength) ? 2 : 3;

        if (wasPlaying && mixerState == 2) {
            if (asyncLoader) asyncLoader->resumeLoading();
            ma_device_start(&device);
            mixerState = 1;
        }
    }

    void deactivate_decoder(int index) {
        if (index >= 0 && index < (int)streams.size())
            streams[index].active = false;
    }

    void amplify_decoder(int index, double volume) {
        if (index >= 0 && index < (int)decoderVolumes.size())
            decoderVolumes[index] = (float)volume;
    }

    void   setPlaybackRate(float value) { playbackRate = value; }
    double getGlobalVolume() const      { return MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed); }
    double setGlobalVolume(double v)    { MUSIC_MASTER_VOLUME_099.store(v, std::memory_order_relaxed); return v; }
    int    getMixerState() const        { return mixerState; }

    double getPlaybackPosition() const {
        ma_uint64 pos = 0;
        if (!streams.empty() && streams[longestDecoderIndex].active)
            pos = streams[longestDecoderIndex].filePosition;
        else if (!streams.empty())
            pos = streams[longestDecoderIndex].decoderLength;
        return (double)pos / (SAMPLE_RATE * 0.001);
    }

    double getDuration() const {
        if (streams.empty()) return 0.0;
        return (double)streams[longestDecoderIndex].decoderLength / (SAMPLE_RATE * 0.001);
    }

private:
    AsyncLoader* asyncLoader = nullptr;
    std::vector<DecoderStream*> streamPtrs;

    void fillInitialBuffer(size_t index, ma_uint64 startFrame) {
        DecoderStream& s = streams[index];
        ma_uint64 decodeStart = (startFrame > PADDING_FRAMES) ? startFrame - PADDING_FRAMES : 0;

        ma_uint64 framesRead = 0;
        {
            std::lock_guard<std::mutex> lock(s.decoderMutex);
            s.fillBuffer(s.activeBuffer, decodeStart, &framesRead);
        }

        s.bufferStartPos = decodeStart;
        s.validFrames    = framesRead;
        s.localReadPos   = (startFrame >= decodeStart) ? startFrame - decodeStart : 0;

        if (s.localReadPos >= TOTAL_BUFFER_FRAMES)
            s.localReadPos = TOTAL_BUFFER_FRAMES - 1;

        s.filePosition = startFrame;
        s.active       = (startFrame < s.decoderLength && framesRead > 0);
        s.asyncState.needsLoad.store(false, std::memory_order_release);
    }

    void loadNextBufferSync(size_t index) {
        DecoderStream& s = streams[index];
        if (!s.active || s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) return;

        ma_uint64 start = s.bufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;
        if (start >= s.decoderLength) return;

        ma_uint64 framesRead = 0;
        s.fillBuffer(s.nextBuffer, start, &framesRead);
        s.asyncState.nextBufferStartPos    = start;
        s.asyncState.nextBufferValidFrames = framesRead;
        s.asyncState.nextBufferReady.store(true, std::memory_order_release);
    }

    void loadLoadingBufferSync(size_t index) {
        DecoderStream& s = streams[index];
        if (!s.active ||
             s.asyncState.loadingBufferReady.load(std::memory_order_relaxed) ||
            !s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) return;

        ma_uint64 start = s.asyncState.nextBufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;
        if (start >= s.decoderLength) return;

        ma_uint64 framesRead = 0;
        s.fillBuffer(s.loadingBuffer, start, &framesRead);
        s.asyncState.loadingBufferStartPos    = start;
        s.asyncState.loadingBufferValidFrames = framesRead;
        s.asyncState.loadingBufferReady.store(true, std::memory_order_release);
    }

    void doBackgroundLoading() {
        bool anyRequested = false;
        for (size_t i = 0; i < streams.size(); i++) {
            DecoderStream& s = streams[i];
            if (!s.active) continue;

            if (!s.asyncState.nextBufferReady.load(std::memory_order_acquire) &&
                !s.asyncState.loadingInProgress.load(std::memory_order_acquire)) {
                ma_uint64 available = (s.localReadPos < s.validFrames)
                                    ? s.validFrames - s.localReadPos : 0;
                if (available < (HALF_BUFFER_FRAMES * 2)) {
                    s.requestBufferLoad();
                    anyRequested = true;
                }
            }

            if (s.asyncState.needsLoad.load(std::memory_order_acquire) &&
                !s.asyncState.nextBufferReady.load(std::memory_order_acquire) &&
                !s.asyncState.loadingInProgress.load(std::memory_order_acquire)) {
                s.requestBufferLoad();
                s.asyncState.needsLoad.store(false, std::memory_order_release);
                anyRequested = true;
            }
        }

        if (anyRequested && asyncLoader) asyncLoader->signal();
    }

    ma_uint32 readFromBuffer(size_t index, float* output, ma_uint32 requestedFrames) {
        DecoderStream& s = streams[index];
        if (!s.active) return 0;

        if (s.shouldSwapBuffers() || s.isBufferLow()) s.trySwapBuffers();

        ma_uint32 framesRead = 0;
        float vol = decoderVolumes[index] * MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);

        while (framesRead < requestedFrames && s.active) {
            ma_uint64 available = (s.localReadPos < s.validFrames)
                                ? s.validFrames - s.localReadPos : 0;

            if (available == 0) {
                if (s.filePosition < s.decoderLength) {
                    if (s.asyncState.nextBufferReady.load(std::memory_order_acquire)) {
                        s.trySwapBuffers();
                        continue;
                    }
                    s.asyncState.needsLoad.store(true, std::memory_order_release);
                    break;
                }
                s.active = false;
                break;
            }

            ma_uint32 toRead = std::min<ma_uint32>((ma_uint32)available,
                                                    requestedFrames - framesRead);
            float* src     = s.activeBuffer + (s.localReadPos * CHANNEL_COUNT);
            float* dst     = output + (framesRead * CHANNEL_COUNT);
            int    samples = (int)(toRead * CHANNEL_COUNT);

            // UPDATED CALL SITE: Uses the runtime dispatcher instead of hardcoded #ifdefs
            if (vol != 0.0f) g_mix_func(dst, src, samples, vol);

            s.localReadPos  += toRead;
            s.filePosition  += toRead;
            framesRead      += toRead;

            if (s.filePosition >= s.decoderLength) { s.active = false; break; }
        }
        return framesRead;
    }

    static void data_callback(ma_device* pDevice, void* pOutput,
                              const void* pInput, ma_uint32 frameCount) {
        AudioSystem* sys = static_cast<AudioSystem*>(pDevice->pUserData);
        if (!sys || !sys->exists) return;

        float* out = (float*)pOutput;
        memset(out, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

        sys->bgLoadCounter++;
        if (sys->bgLoadCounter >= BG_LOAD_CHECK_INTERVAL) {
            sys->bgLoadCounter = 0;
            sys->doBackgroundLoading();
        }

        bool anyActive = false;

        if (sys->playbackRate == 1.0f) {
            for (size_t i = 0; i < sys->streams.size(); i++) {
                if (!sys->streams[i].active) continue;
                ma_uint32 read = sys->readFromBuffer(i, out, frameCount);
                if (read > 0) anyActive = true;
                if (read < frameCount && sys->streams[i].active)
                    sys->streams[i].asyncState.needsLoad.store(true, std::memory_order_release);
            }
        } else {
            static_assert(MAX_CALLBACK_FRAMES >= 4096,
                          "MAX_CALLBACK_FRAMES too small for pitched playback buffers");

            if (frameCount > MAX_CALLBACK_FRAMES) {
                sys->mixerState = anyActive ? 1 : 3;
                (void)pInput;
                return;
            }

            float* inputMix       = sys->pitchInputMix;
            float* stretchedOutput = sys->pitchStretchedOut;
            memset(inputMix,        0, sizeof(float) * frameCount * CHANNEL_COUNT);
            memset(stretchedOutput, 0, sizeof(float) * frameCount * CHANNEL_COUNT);
            ma_uint32 maxToRead = (ma_uint32)(frameCount * sys->playbackRate);

            for (size_t i = 0; i < sys->streams.size(); i++) {
                if (!sys->streams[i].active) continue;
                ma_uint32 read = sys->readFromBuffer(i, inputMix, maxToRead);
                if (read > 0) anyActive = true;
                if (read < maxToRead && sys->streams[i].active)
                    sys->streams[i].asyncState.needsLoad.store(true, std::memory_order_release);
            }

            if (anyActive) {
                if (!sys->stretch) {
                    sys->stretch = new signalsmith::stretch::SignalsmithStretch();
                    sys->stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
                }
                sys->stretch->process(inputMix, maxToRead, stretchedOutput, frameCount);
                memcpy(out, stretchedOutput, sizeof(float) * frameCount * CHANNEL_COUNT);
            }
        }

        sys->mixerState = anyActive ? 1 : 3;
        (void)pInput;
    }

    void moveFrom(AudioSystem&& other) noexcept {
        streams        = std::move(other.streams);
        decoderVolumes = std::move(other.decoderVolumes);
        filePaths      = std::move(other.filePaths);
        streamPtrs     = std::move(other.streamPtrs);
        stretch        = other.stretch;
        asyncLoader    = other.asyncLoader;

        memcpy(&device, &other.device, sizeof(ma_device));
        memset(&other.device, 0, sizeof(ma_device));

        longestDecoderIndex = other.longestDecoderIndex;
        playbackRate        = other.playbackRate;
        mixerState          = other.mixerState;
        exists              = other.exists;

        other.stretch = nullptr;  other.asyncLoader    = nullptr;
        other.longestDecoderIndex = 0;  other.playbackRate   = 1.0f;
        other.mixerState     = 3;
        other.exists = false;
    }
};

// ==========================================================================
//  BackgroundTrack
// ==========================================================================

struct BackgroundTrack {
    float*     pcmData    = nullptr;
    ma_uint64  frameCount = 0;
    ma_uint64  readPos    = 0;
    float      volume     = 1.0f;
    bool       active     = false;
    bool       looping    = true;
    std::string filePath;

    BackgroundTrack()  = default;
    ~BackgroundTrack() { cleanup(); }

    BackgroundTrack(BackgroundTrack&& other) noexcept { moveFrom(std::move(other)); }
    BackgroundTrack& operator=(BackgroundTrack&& other) noexcept {
        if (this != &other) { cleanup(); moveFrom(std::move(other)); }
        return *this;
    }
    BackgroundTrack(const BackgroundTrack&)            = delete;
    BackgroundTrack& operator=(const BackgroundTrack&) = delete;

    void cleanup() {
        if (pcmData) { free(pcmData); pcmData = nullptr; }
        frameCount = 0; readPos = 0; volume = 1.0f;
        active = false; looping = true; filePath.clear();
    }

    bool load(const char* path) {
        cleanup();
        ma_decoder decoder;
        ma_decoder_config cfg = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
        if (ma_decoder_init_file(path, &cfg, &decoder) != MA_SUCCESS) {
            printf("Failed to load background track: %s\n", path);
            return false;
        }
        ma_uint64 length = 0;
        ma_decoder_get_length_in_pcm_frames(&decoder, &length);
        if (length == 0) {
            ma_decoder_uninit(&decoder);
            printf("Background track has zero length: %s\n", path);
            return false;
        }
        pcmData = (float*)malloc(sizeof(float) * length * CHANNEL_COUNT);
        if (!pcmData) {
            ma_decoder_uninit(&decoder);
            printf("Failed to allocate memory for background track: %s\n", path);
            return false;
        }
        ma_uint64 framesRead = 0;
        ma_decoder_read_pcm_frames(&decoder, pcmData, length, &framesRead);
        ma_decoder_uninit(&decoder);
        if (framesRead == 0) {
            cleanup();
            printf("Failed to read background track: %s\n", path);
            return false;
        }
        frameCount = framesRead;
        filePath   = path;
        active     = false;
        looping    = true;
        readPos    = 0;
        return true;
    }

    void play()  { if (pcmData) { readPos = 0; active = true; } }
    void stop()  { active = false; readPos = 0; }
    void setVolume(float v)  { volume = v; }
    void setLooping(bool lp) { looping = lp; }

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames) {
        if (!active || !pcmData || frameCount == 0) return 0;

        float vol = volume * MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);;
        ma_uint32 filled = 0;

        while (filled < requestedFrames) {
            ma_uint64 remaining = frameCount - readPos;
            if (remaining == 0) {
                if (looping) { readPos = 0; remaining = frameCount; }
                else         { active = false; break; }
            }

            ma_uint32 toRead = (ma_uint32)std::min<ma_uint64>(remaining,
                                                               requestedFrames - filled);
            float* src = pcmData + (readPos * CHANNEL_COUNT);
            float* dst = output  + (filled  * CHANNEL_COUNT);
            int samples = (int)(toRead * CHANNEL_COUNT);

            // UPDATED CALL SITE: Uses the runtime dispatcher
            g_mix_func(dst, src, samples, vol);

            readPos += toRead;
            filled  += toRead;
        }
        return filled;
    }

private:
    void moveFrom(BackgroundTrack&& other) noexcept {
        pcmData    = other.pcmData;    frameCount = other.frameCount;
        readPos    = other.readPos;    volume     = other.volume;
        active     = other.active;     looping    = other.looping;
        filePath   = std::move(other.filePath);
        other.pcmData = nullptr; other.frameCount = 0; other.readPos = 0;
        other.active = false;
    }
};

// ==========================================================================
//  SoundEffectInstance / SoundEffectPool
// ==========================================================================

struct SoundEffectInstance {
    float*    pcmData         = nullptr;
    ma_uint64 frameCount      = 0;
    ma_uint64 playbackPosition = 0;
    double     volume          = 1.0f;
    bool      playing         = false;

    SoundEffectInstance() = default;

    SoundEffectInstance(float* data, ma_uint64 frames, double vol = 1.0f)
        : pcmData(data), frameCount(frames), playbackPosition(0),
          volume(vol), playing(true) {}

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames) {
        if (!playing || !pcmData) return 0;

        ma_uint64 remaining = frameCount - playbackPosition;
        if (remaining == 0) { playing = false; return 0; }

        ma_uint32 toRead = (ma_uint32)std::min<ma_uint64>(remaining, requestedFrames);
        float* src = pcmData + (playbackPosition * CHANNEL_COUNT);
        float  vol = volume * MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);

        // UPDATED CALL SITE: Uses the runtime dispatcher
        g_mix_func(output, src, (int)(toRead * CHANNEL_COUNT), vol);

        playbackPosition += toRead;
        if (playbackPosition >= frameCount) playing = false;
        return toRead;
    }

    bool isPlaying() const { return playing; }
};

class SoundEffectPool {
public:
    SoundEffectPool() = default;
    ~SoundEffectPool() { cleanup(); }

    SoundEffectPool(const SoundEffectPool&)            = delete;
    SoundEffectPool& operator=(const SoundEffectPool&) = delete;

    SoundEffectPool(SoundEffectPool&& other) noexcept { moveFrom(std::move(other)); }
    SoundEffectPool& operator=(SoundEffectPool&& other) noexcept {
        if (this != &other) { cleanup(); moveFrom(std::move(other)); }
        return *this;
    }

    void cleanup() {
        if (pcmData) { free(pcmData); pcmData = nullptr; }
        frameCount = 0; name.clear(); instances.clear();
    }

    bool load(const char* path) {
        cleanup();
        ma_decoder decoder;
        ma_decoder_config cfg = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
        if (ma_decoder_init_file(path, &cfg, &decoder) != MA_SUCCESS) {
            printf("Failed to load sound effect: %s\n", path); return false;
        }
        ma_uint64 length = 0;
        ma_decoder_get_length_in_pcm_frames(&decoder, &length);
        if (length == 0) {
            ma_decoder_uninit(&decoder);
            printf("Sound effect has zero length: %s\n", path); return false;
        }
        pcmData = (float*)malloc(sizeof(float) * length * CHANNEL_COUNT);
        if (!pcmData) {
            ma_decoder_uninit(&decoder);
            printf("Failed to allocate memory for sound effect: %s\n", path); return false;
        }
        ma_uint64 framesRead = 0;
        ma_decoder_read_pcm_frames(&decoder, pcmData, length, &framesRead);
        ma_decoder_uninit(&decoder);
        if (framesRead == 0) {
            cleanup();
            printf("Failed to read sound effect: %s\n", path); return false;
        }
        frameCount = framesRead;
        name = path;
        instances.reserve(MAX_INSTANCES);
        return true;
    }

    void play(double volume = 1.0f) {
        if (!pcmData || frameCount == 0) return;
        for (auto& inst : instances) {
            if (!inst.isPlaying()) {
                inst.playbackPosition = 0; inst.volume = volume; inst.playing = true;
                ++playingCount;
                return;
            }
        }
        if (instances.size() < MAX_INSTANCES) {
            instances.emplace_back(pcmData, frameCount, volume);
            ++playingCount;
        }
    }

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames) {
        if (playingCount == 0) return 0;
        ma_uint64 maxRead = 0;
        int stillPlaying = 0;
        for (auto& inst : instances) {
            if (inst.isPlaying()) {
                ma_uint64 r = inst.readFrames(output, requestedFrames);
                if (r > maxRead) maxRead = r;
                if (inst.isPlaying()) ++stillPlaying;
            }
        }
        playingCount = stillPlaying;
        return maxRead;
    }

    bool  isAnyPlaying()  const { return playingCount > 0; }
    void  stopAll()             { for (auto& i : instances) { i.playing = false; i.playbackPosition = 0; } playingCount = 0; }
    int   getPlayingCount() const { return playingCount; }

private:
    static const int MAX_INSTANCES = 32;
    float*     pcmData      = nullptr;
    ma_uint64  frameCount   = 0;
    int        playingCount = 0;
    std::string name;
    std::vector<SoundEffectInstance> instances;

    void moveFrom(SoundEffectPool&& other) noexcept {
        pcmData = other.pcmData; frameCount = other.frameCount;
        playingCount = other.playingCount;
        name = std::move(other.name); instances = std::move(other.instances);
        other.pcmData = nullptr; other.frameCount = 0; other.playingCount = 0;
    }
};

// ==========================================================================
//  AudioMixerManager
// ==========================================================================

class AudioMixerManager {
public:
    AudioMixerManager() { memset(&device, 0, sizeof(ma_device)); }
    ~AudioMixerManager() { destroy(); }

    bool initialize() {
        if (deviceInitialized) return true;
        ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
        cfg.playback.format   = SAMPLE_FORMAT;
        cfg.playback.channels = CHANNEL_COUNT;
        cfg.sampleRate        = SAMPLE_RATE;
        cfg.dataCallback      = audioCallback;
        cfg.pUserData         = this;
        if (ma_device_init(nullptr, &cfg, &device) != MA_SUCCESS) {
            printf("Failed to initialize audio mixer device\n"); return false;
        }
        deviceInitialized = true;
        ma_device_start(&device);
        return true;
    }

    void destroy() {
        if (deviceInitialized) { ma_device_uninit(&device); deviceInitialized = false; }
        std::lock_guard<std::mutex> lk(mixerMutex);
        backgroundTracks.clear(); soundEffectPools.clear();
        backgroundTrackMap.clear(); soundEffectMap.clear();
        for (int b = 0; b < 2; b++) {
            bgSnapshot[b].clear();
            sfxSnapshot[b].clear();
        }
    }

    int loadBackgroundTrack(const char* path) {
        if (!deviceInitialized && !initialize()) return -1;
        std::lock_guard<std::mutex> lk(mixerMutex);
        std::string key = path;
        auto it = backgroundTrackMap.find(key);
        if (it != backgroundTrackMap.end()) return it->second;
        BackgroundTrack track;
        if (!track.load(path)) return -1;
        int idx = (int)backgroundTracks.size();
        backgroundTracks.push_back(std::move(track));
        backgroundTrackMap[key] = idx;
        publishSnapshot();
        return idx;
    }

    int  findBackgroundTrack(const char* path) {
        std::lock_guard<std::mutex> lk(mixerMutex);
        auto it = backgroundTrackMap.find(std::string(path));
        return (it != backgroundTrackMap.end()) ? it->second : -1;
    }
    bool isBackgroundTrackLoaded(const char* path) { return findBackgroundTrack(path) >= 0; }

    void playBackgroundTrack(int idx)  { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].play(); }
    void stopBackgroundTrack(int idx)  { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].stop(); }
    void setBackgroundTrackVolume(int idx, float v)  { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].setVolume(v); }
    void setBackgroundTrackLooping(int idx, bool lp) { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].setLooping(lp); }
    bool isBackgroundTrackPlaying(int idx) { return inRange(idx, backgroundTracks) && backgroundTracks[idx].active; }

    int loadSoundEffect(const char* path) {
        if (!deviceInitialized && !initialize()) return -1;
        std::lock_guard<std::mutex> lk(mixerMutex);
        std::string key = path;
        auto it = soundEffectMap.find(key);
        if (it != soundEffectMap.end()) return it->second;
        SoundEffectPool pool;
        if (!pool.load(path)) return -1;
        int idx = (int)soundEffectPools.size();
        soundEffectPools.push_back(std::move(pool));
        soundEffectMap[key] = idx;
        publishSnapshot();
        return idx;
    }

    int  findSoundEffect(const char* path) {
        std::lock_guard<std::mutex> lk(mixerMutex);
        auto it = soundEffectMap.find(std::string(path));
        return (it != soundEffectMap.end()) ? it->second : -1;
    }
    bool isSoundEffectLoaded(const char* path) { return findSoundEffect(path) >= 0; }

    void playSoundEffect(int idx, double volume = 1.0f) {
        if (inRange(idx, soundEffectPools)) soundEffectPools[idx].play(volume);
    }
    void playSoundEffect(const char* path, double volume = 1.0f) {
        int idx = findSoundEffect(path);
        if (idx < 0) idx = loadSoundEffect(path);
        if (idx >= 0) playSoundEffect(idx, volume);
    }
    void stopSoundEffect(int idx)           { if (inRange(idx, soundEffectPools)) soundEffectPools[idx].stopAll(); }
    bool isSoundEffectPlaying(int idx)      { return inRange(idx, soundEffectPools) && soundEffectPools[idx].isAnyPlaying(); }
    int  getSoundEffectPlayingCount(int idx){ return inRange(idx, soundEffectPools) ? soundEffectPools[idx].getPlayingCount() : 0; }

    void unloadBackgroundTrack(int idx) {
        std::lock_guard<std::mutex> lk(mixerMutex);
        if (!inRange(idx, backgroundTracks)) return;

        bgSnapshot[0].clear();
        bgSnapshot[1].clear();
        std::atomic_thread_fence(std::memory_order_seq_cst);

        eraseAndFixup(backgroundTrackMap, idx);
        backgroundTracks.erase(backgroundTracks.begin() + idx);
        publishSnapshot();
    }

    void unloadSoundEffect(int idx) {
        std::lock_guard<std::mutex> lk(mixerMutex);
        if (!inRange(idx, soundEffectPools)) return;

        sfxSnapshot[0].clear();
        sfxSnapshot[1].clear();
        std::atomic_thread_fence(std::memory_order_seq_cst);

        eraseAndFixup(soundEffectMap, idx);
        soundEffectPools.erase(soundEffectPools.begin() + idx);
        publishSnapshot();
    }

    double setMasterVolume(double v) { MUSIC_MASTER_VOLUME_099.store(v, std::memory_order_relaxed); return v; }
    double getMasterVolume() const  { return MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed); }

private:
    std::deque<BackgroundTrack>  backgroundTracks;
    std::deque<SoundEffectPool>  soundEffectPools;
    std::mutex mixerMutex;

    std::unordered_map<std::string, int> backgroundTrackMap;
    std::unordered_map<std::string, int> soundEffectMap;

    ma_device device;
    bool  deviceInitialized = false;

    std::vector<BackgroundTrack*> bgSnapshot[2];
    std::vector<SoundEffectPool*> sfxSnapshot[2];
    std::atomic<int> snapshotIndex{0};

    void publishSnapshot() {
        int next = 1 - snapshotIndex.load(std::memory_order_relaxed);
        bgSnapshot[next].clear();
        for (auto& t : backgroundTracks) bgSnapshot[next].push_back(&t);
        sfxSnapshot[next].clear();
        for (auto& p : soundEffectPools)  sfxSnapshot[next].push_back(&p);
        snapshotIndex.store(next, std::memory_order_release);
    }

    template<typename Vec>
    static bool inRange(int idx, const Vec& v) {
        return idx >= 0 && idx < (int)v.size();
    }

    static void eraseAndFixup(std::unordered_map<std::string, int>& map, int removed) {
        for (auto it = map.begin(); it != map.end(); ) {
            if (it->second == removed)        it = map.erase(it);
            else { if (it->second > removed) --it->second; ++it; }
        }
    }

    static void audioCallback(ma_device* pDevice, void* pOutput,
                               const void* pInput, ma_uint32 frameCount) {
        AudioMixerManager* mixer = static_cast<AudioMixerManager*>(pDevice->pUserData);
        if (!mixer) return;

        float* out = (float*)pOutput;
        memset(out, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

        int snap = mixer->snapshotIndex.load(std::memory_order_acquire);

        for (BackgroundTrack* track : mixer->bgSnapshot[snap])
            if (track->active) track->readFrames(out, frameCount);

        for (SoundEffectPool* pool : mixer->sfxSnapshot[snap])
            pool->readFrames(out, frameCount);

        (void)pInput;
    }
};