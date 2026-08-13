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
 * LOCK-FREE ARCHITECTURE:
 * - All OS-level mutexes and condition variables have been removed from hot paths.
 * - Cross-thread state is communicated via atomic variables and lock-free triple buffers.
 * - The audio callback is 100% wait-free and lock-free.
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
#include <deque>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
#include <iostream>
#include <cmath> // Required for std::fma
#include <chrono>
#include <memory>
#include <mutex>

#ifdef __SSE__
#include <emmintrin.h>
#include <xmmintrin.h>
#endif

std::atomic<double> MUSIC_MASTER_VOLUME_099{1.0f};

// ---- Windows audio-device helpers with change detection (LOCK-FREE) -----

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

// Lock-free triple buffer for device state to avoid std::mutex
static struct AudioDeviceState {
    struct DeviceInfo {
        std::string deviceName;
        std::string deviceId;
        bool isPnP = false;
        bool isHeadphones = false;
    };
    
    DeviceInfo infoBuffers[3];
    std::atomic<int> infoReaderIndex{0};
    std::atomic<int> infoNewestIndex{1};
    
    std::atomic<int64_t> lastCheckTime{0};
    std::atomic<bool> deviceChanged{false};
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

    // Lock-free triple buffer update
    int n = g_currentDeviceState.infoNewestIndex.load(std::memory_order_acquire);
    int r = g_currentDeviceState.infoReaderIndex.load(std::memory_order_acquire);

    // The free buffer is the one that is neither the reader's nor the newest.
    // If the reader has caught up to the newest (r == n), we have two free buffers.
    int next;
    if (r == n) {
        next = (r + 1) % 3;
    } else {
        next = 3 - r - n;
    }

    int slot = next;
    AudioDeviceState::DeviceInfo& newInfo = g_currentDeviceState.infoBuffers[slot];

    // Re-validate the slot selection right before publication.  If the reader
    // advanced while we were assembling, the slot we picked might be one the
    // reader is about to consume; fall back to the other free slot instead so a
    // writer never tears data a reader is reading.
    int rAfter = g_currentDeviceState.infoReaderIndex.load(std::memory_order_acquire);
    int nAfter = g_currentDeviceState.infoNewestIndex.load(std::memory_order_acquire);
    if (rAfter != r || nAfter != n) {
        int fallback = (rAfter == nAfter) ? ((rAfter + 1) % 3) : (3 - rAfter - nAfter);
        if (fallback != next) {
            g_currentDeviceState.infoBuffers[fallback] = newInfo;
            slot = fallback;
        }
    }
    AudioDeviceState::DeviceInfo& publishedInfo = g_currentDeviceState.infoBuffers[slot];
    publishedInfo.isPnP = newIsPnP;
    publishedInfo.isHeadphones = newIsHeadphones;
    publishedInfo.deviceName = newDeviceName;
    publishedInfo.deviceId = newDeviceId;

    // Compare against the LAST PUBLISHED state (n), not the reader's state (r)
    AudioDeviceState::DeviceInfo& oldInfo = g_currentDeviceState.infoBuffers[n];
    bool deviceChanged = (publishedInfo.isPnP != oldInfo.isPnP) ||
                         (publishedInfo.isHeadphones != oldInfo.isHeadphones) ||
                         (publishedInfo.deviceName != oldInfo.deviceName) ||
                         (publishedInfo.deviceId != oldInfo.deviceId);

    if (deviceChanged) {
        printf("[Audio] Device changed: %s (PnP: %s, Headphones: %s)\n",
               newDeviceName.c_str(),
               newIsPnP ? "Yes" : "No",
               newIsHeadphones ? "Yes" : "No");
        g_currentDeviceState.deviceChanged.store(true, std::memory_order_release);
    }

    g_currentDeviceState.infoNewestIndex.store(slot, std::memory_order_release);

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

inline int getDeviceInfoIndex() {
    int r = g_currentDeviceState.infoReaderIndex.load(std::memory_order_relaxed);
    int n = g_currentDeviceState.infoNewestIndex.load(std::memory_order_acquire);
    if (r != n) {
        g_currentDeviceState.infoReaderIndex.store(n, std::memory_order_release);
        return n;
    }
    return r;
}

inline bool checkIfPnPDevice() {
    return g_currentDeviceState.infoBuffers[getDeviceInfoIndex()].isPnP;
}

inline bool checkWindowsHeadphoneStatus() {
    return g_currentDeviceState.infoBuffers[getDeviceInfoIndex()].isHeadphones;
}

inline std::string getCurrentAudioDeviceName() {
    return g_currentDeviceState.infoBuffers[getDeviceInfoIndex()].deviceName;
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

// ---- SIMD mix helpers -------------------------

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

    // Tail loop: std::fma works perfectly here on SSE2
    for (; i < samples; i++) {
        dst[i] = std::fma(src[i], volume, dst[i]);
    }
}
static inline void mix_simd_stereo(float* dst, const float* src, int frames, float volume) {
    mix_simd(dst, src, frames * 2, volume);
}
#else
static inline void mix_scalar(float* dst, const float* src, int samples, float volume) {
    if (volume == 1.0f) {
        for (int i = 0; i < samples; i++) dst[i] += src[i];
    } else {
        for (int i = 0; i < samples; i++) {
            // std::fma ensures (src[i] * volume) + dst[i] is rounded only once
            dst[i] = std::fma(src[i], volume, dst[i]); 
        }
    }
}
#endif

// ==========================================================================
//  Runtime AVX2 Detection & Dispatch (Injected on top of existing code)
// ==========================================================================
#if defined(_MSC_VER)
    #include <intrin.h>
#elif defined(__GNUC__) || defined(__clang__)
    #include <cpuid.h>
#endif

// AVX2 requires the OS to have actually enabled XMM/YMM state saving
// (CR4.OSXSAVE + XCR0 bits 1|2), otherwise executing _mm256_* instructions
// traps.  CPUID leaf 7 alone is not enough.
static inline bool os_has_avx_support() {
#if defined(_MSC_VER)
    int regs[4];
    __cpuid(regs, 1);
    if (!(regs[2] & (1 << 27))) return false;              // no OSXSAVE
    unsigned long long xcr0 = _xgetbv(0);
    return (xcr0 & 0x6) == 0x6;                            // XMM + YMM state
#elif defined(__GNUC__) || defined(__clang__)
    unsigned int eax, ebx, ecx, edx;
    if (!__get_cpuid(1, &eax, &ebx, &ecx, &edx)) return false;
    if (!(ecx & (1 << 27))) return false;
    unsigned int xcr0lo = 0, xcr0hi = 0;
    __asm__ __volatile__("xgetbv" : "=a"(xcr0lo), "=d"(xcr0hi) : "c"(0));
    unsigned long long xcr0 = ((unsigned long long)xcr0hi << 32) | xcr0lo;
    return (xcr0 & 0x6) == 0x6;
#else
    return false;
#endif
}

static inline bool has_avx2_runtime() {
#if defined(_MSC_VER)
    int regs[4];
    __cpuidex(regs, 7, 0);
    return ((regs[1] & (1 << 5)) != 0) && os_has_avx_support(); // EBX bit 5 = AVX2
#elif defined(__GNUC__) || defined(__clang__)
    unsigned int eax, ebx, ecx, edx;
    return __get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx) &&
           ((ebx >> 5) & 1) && os_has_avx_support();
#else
    return false;
#endif
}

#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2,fma")))
#endif
static inline void mix_avx2(float* dst, const float* src, int samples, float volume) {
    int i = 0;
    if (volume == 1.0f) {
        // No multiplication here, so FMA doesn't apply
        for (; i + 8 <= samples; i += 8)
            _mm256_storeu_ps(dst + i, _mm256_add_ps(_mm256_loadu_ps(dst + i), _mm256_loadu_ps(src + i)));
    } else {
        __m256 vvol = _mm256_set1_ps(volume);
        for (; i + 8 <= samples; i += 8) {
            __m256 vdst = _mm256_loadu_ps(dst + i);
            __m256 vsrc = _mm256_loadu_ps(src + i);
            
            // REPLACED: _mm256_add_ps + _mm256_mul_ps
            // WITH: _mm256_fmadd_ps (computes a * b + c)
            _mm256_storeu_ps(dst + i, _mm256_fmadd_ps(vsrc, vvol, vdst));
        }
    }
    
    // Tail loop: Use std::fma for precision and potential auto-vectorization
    for (; i < samples; i++) dst[i] = std::fma(src[i], volume, dst[i]);
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
//  DecoderStream (LOCK-FREE)
// ==========================================================================

struct DecoderStream {
    float* pcmBufferA = nullptr;
    float* pcmBufferB = nullptr;
    float* pcmBufferC = nullptr;

    float* activeBuffer  = nullptr;
    float* nextBuffer    = nullptr;
    float* loadingBuffer = nullptr;

    std::atomic<ma_uint64> filePosition{0};
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

    std::atomic<bool> active{false};
    ma_uint64 decoderLength = 0;
    std::string decoderPath;

    // The seekable ma_decoder used for async prefetch.  It is R/W owned by the
    // AsyncLoader worker thread ONLY.  Neither the audio callback nor the
    // game/main thread may touch it, so its internal read/seek position can
    // never be corrupted by a second thread.  Any synchronous decode performed
    // during loadFiles()/seekToPCMFrame() uses a short-lived temporary decoder
    // instead (see fillBufferTemp) so the two never share a handle.
    ma_decoder workerDecoder;
    bool workerDecoderInitialized = false;

    DecoderStream()  { memset(&workerDecoder, 0, sizeof(ma_decoder)); }
    ~DecoderStream() { cleanup(); }

    DecoderStream(DecoderStream&& other) noexcept { moveFrom(std::move(other)); }
    DecoderStream& operator=(DecoderStream&& other) noexcept {
        if (this != &other) { cleanup(); moveFrom(std::move(other)); }
        return *this;
    }
    DecoderStream(const DecoderStream&)            = delete;
    DecoderStream& operator=(const DecoderStream&) = delete;

    // Open a throw-away decoder for MAIN-thread synchronous decode.  Creates a
    // fresh handle every time, so it never shares state with workerDecoder.
    bool openTempDecoder(ma_decoder* out) const {
        if (decoderPath.empty()) return false;
        ma_decoder_config cfg = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
        if (ma_decoder_init_file(decoderPath.c_str(), &cfg, out) != MA_SUCCESS) return false;
        ma_data_source_set_looping(out, MA_FALSE);
        return true;
    }

    void fillBufferTemp(ma_uint64 decodeStart, float* buffer, ma_uint64* framesRead) {
        *framesRead = 0;
        ma_decoder dec;
        if (!openTempDecoder(&dec)) {
            memset(buffer, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
            return;
        }

        ma_uint64 maxFrames = TOTAL_BUFFER_FRAMES;
        if (decodeStart + TOTAL_BUFFER_FRAMES > decoderLength)
            maxFrames = decoderLength - decodeStart;

        memset(buffer, 0, maxFrames * CHANNEL_COUNT * sizeof(float));

        if (maxFrames > 0 && decodeStart < decoderLength) {
            if (ma_decoder_seek_to_pcm_frame(&dec, decodeStart) == MA_SUCCESS)
                ma_decoder_read_pcm_frames(&dec, buffer, maxFrames, framesRead);
        }

        ma_decoder_uninit(&dec);
    }

    // R/W worker-owned decoder.  Called from the AsyncLoader worker thread only.
    void fillBufferWorker(ma_uint64 decodeStart, float* buffer, ma_uint64* framesRead) {
        *framesRead = 0;
        if (!workerDecoderInitialized) {
            memset(buffer, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
            return;
        }

        ma_uint64 maxFrames = TOTAL_BUFFER_FRAMES;
        if (decodeStart + TOTAL_BUFFER_FRAMES > decoderLength)
            maxFrames = decoderLength - decodeStart;

        memset(buffer, 0, maxFrames * CHANNEL_COUNT * sizeof(float));

        if (maxFrames > 0 && decodeStart < decoderLength) {
            if (ma_decoder_seek_to_pcm_frame(&workerDecoder, decodeStart) == MA_SUCCESS)
                ma_decoder_read_pcm_frames(&workerDecoder, buffer, maxFrames, framesRead);
        }
    }

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

        filePosition.store(0, std::memory_order_release);
        bufferStartPos = localReadPos = validFrames = 0;

        if (pcmBufferA) memset(pcmBufferA, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
        if (pcmBufferB) memset(pcmBufferB, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
        if (pcmBufferC) memset(pcmBufferC, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
    }

    bool shouldSwapBuffers() const {
        if (localReadPos >= validFrames) return true;
        if (localReadPos >= (PADDING_FRAMES + HALF_BUFFER_FRAMES))
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

private:
    void cleanup() {
        if (workerDecoderInitialized) {
            ma_decoder_uninit(&workerDecoder);
            workerDecoderInitialized = false;
        }
        memset(&workerDecoder, 0, sizeof(ma_decoder));
        decoderPath.clear();

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

        memcpy(&workerDecoder, &other.workerDecoder, sizeof(ma_decoder));
        workerDecoderInitialized = other.workerDecoderInitialized;
        decoderPath = std::move(other.decoderPath);

        filePosition.store(other.filePosition.load(std::memory_order_relaxed), std::memory_order_relaxed);
        bufferStartPos = other.bufferStartPos;
        localReadPos   = other.localReadPos;
        validFrames    = other.validFrames;
        active.store(other.active.load(std::memory_order_relaxed), std::memory_order_relaxed);
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
        other.workerDecoderInitialized = false;
        memset(&other.workerDecoder, 0, sizeof(ma_decoder));
        other.decoderPath.clear();
    }
};

// ==========================================================================
//  AsyncLoader (LOCK-FREE)
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
    }

    void waitUntilIdle() {
        if (!running.load(std::memory_order_acquire)) return;
        
        signal();
        
        // Wait until the worker is BOTH idle AND no stream has an in-flight
        // buffer fill. A full 46305-frame decode (TOTAL_BUFFER_FRAMES) from a
        // freshly-opened decoder (as happens right after a song restart, when
        // start()'s internal seek is immediately followed by the real forward
        // seek) can legitimately take longer than the old 100ms timeout. If
        // that timeout fired while the worker was still writing, the seek's
        // resetState() would clear the worker's loadingInProgress flag and
        // reset buffers mid-write, corrupting the next buffer and leaving the
        // stream inactive -> the song silently restarts from 0.
        auto startTime = std::chrono::steady_clock::now();
        const auto timeout = std::chrono::milliseconds(1000);
        
        for (;;) {
            bool anyLoading = false;
            for (DecoderStream* s : streams) {
                if (s && s->asyncState.loadingInProgress.load(std::memory_order_acquire)) {
                    anyLoading = true;
                    break;
                }
            }
            if (!anyLoading && workerIdle.load(std::memory_order_acquire)) break;
            if (std::chrono::steady_clock::now() - startTime > timeout) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
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
        
        workPending.store(false, std::memory_order_release);
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
                
                auto start = std::chrono::steady_clock::now();
                int yieldCount = 0;
                while (pause.load(std::memory_order_acquire) &&
                       !stopRequested.load(std::memory_order_acquire) &&
                       running.load(std::memory_order_acquire)) {
                    
                    if (std::chrono::steady_clock::now() - start > std::chrono::milliseconds(10)) break;
                    
                    if (yieldCount++ < 100) {
                        std::this_thread::yield();
                    } else {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                }
                workerIdle.store(false, std::memory_order_release);
                continue;
            }

            if (streams.empty()) {
                workerIdle.store(true, std::memory_order_release);
                
                auto start = std::chrono::steady_clock::now();
                int yieldCount = 0;
                while (streams.empty() && 
                       !stopRequested.load(std::memory_order_acquire) &&
                       running.load(std::memory_order_acquire)) {
                    
                    if (std::chrono::steady_clock::now() - start > std::chrono::milliseconds(10)) break;
                    
                    if (yieldCount++ < 100) {
                        std::this_thread::yield();
                    } else {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                }
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
                
                if (s && s->active.load(std::memory_order_acquire)) {
                    if (processStreamLoad(s)) {
                        processed++;
                    }
                }
            }

            if (processed > 0) {
                currentStream = (currentStream + 1) % (int)streamCount;
            }

            // FIX: Removed `&& pause` from this condition to prevent infinite tight loop
            if (processed == 0 && !stopRequested.load(std::memory_order_acquire)) {
                workerIdle.store(true, std::memory_order_release);
                
                auto start = std::chrono::steady_clock::now();
                int yieldCount = 0;
                while (!workPending.load(std::memory_order_acquire) &&
                       !stopRequested.load(std::memory_order_acquire) &&
                       running.load(std::memory_order_acquire)) {
                    
                    if (std::chrono::steady_clock::now() - start > std::chrono::milliseconds(5)) break;
                    
                    if (yieldCount++ < 100) {
                        std::this_thread::yield();
                    } else {
                        std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    }
                }
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
        s->fillBufferWorker(start, s->asyncState.asyncNextBuffer, &framesRead);

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
        s->fillBufferWorker(start, s->asyncState.asyncLoadingBuffer, &framesRead);

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
//  AudioSystem (LOCK-FREE)
// ==========================================================================

class AudioSystem {
public:
    std::vector<DecoderStream> streams;
    std::vector<float>         decoderVolumes;
    std::vector<std::string>   filePaths;

    ma_device device;
    signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

    int   longestDecoderIndex = 0;
    std::atomic<float> playbackRate{1.0f};
    std::atomic<int> mixerState{3};
    std::atomic<bool> exists{false};
    std::atomic<bool> stretchEnabled{true}; //BOTTLENECK: high改善 [opt-in] FFT time-stretch toggle; when false, pitched playback uses linear resample instead of SignalsmithStretch

    float pitchInputMix[MAX_CALLBACK_FRAMES * CHANNEL_COUNT]      = {};
    float pitchStretchedOut[MAX_CALLBACK_FRAMES * CHANNEL_COUNT]  = {};

    static constexpr int BG_LOAD_CHECK_INTERVAL = 8;
    std::atomic<ma_uint64> totalFramesProcessed{0};  // Track total frames for time-based loading (thread-safe)
    ma_uint64 lastLoadFrame = 0;         // Last frame when background load was triggered
    int bgLoadCounter = 0;

    // Prediction state for smooth 0.1ms audio time between callback updates
    mutable std::atomic<ma_uint64> lastQueriedFrames{0};
    mutable std::atomic<long long> lastQuerySystemTime{0};  // steady_clock ns
    mutable std::atomic<double> lastQueryPlaybackRate{1.0};

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

        for (size_t i = 0; i < argv.size(); i++) {
            DecoderStream& s = streams[i];
            s.decoderPath = argv[i];

            // Probe with a throw-away decoder to validate the file and learn its
            // length.  The stream's own worker decode handle isn't opened yet, so
            // a failure here never leaves a half-initialized decoder behind and
            // the streams.clear() below can uninit cleanly (no double-uninit).
            ma_decoder probe;
            if (!s.openTempDecoder(&probe)) {
                streams.clear(); decoderVolumes.clear(); filePaths.clear();
                printf("Failed to load %s.\n", argv[i]);
                exists.store(false, std::memory_order_release);
                return;
            }
            ma_decoder_get_length_in_pcm_frames(&probe, &s.decoderLength);
            ma_decoder_uninit(&probe);

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

            // Open the persistent decode handle that only the AsyncLoader worker
            // thread will ever touch.  No other thread accesses it afterwards.
            bool workerOpened = false;
            {
                ma_decoder_config workerConfig =
                    ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
                if (ma_decoder_init_file(argv[i], &workerConfig, &s.workerDecoder) == MA_SUCCESS) {
                    ma_data_source_set_looping(&s.workerDecoder, MA_FALSE);
                    s.workerDecoderInitialized = true;
                    workerOpened = true;
                }
            }
            if (!workerOpened) {
                streams.clear(); decoderVolumes.clear(); filePaths.clear();
                printf("Failed to load %s.\n", argv[i]);
                exists.store(false, std::memory_order_release);
                return;
            }

            //BOTTLENECK: mid synchronous decode of ~3 full buffers (initial + 2 prefetch) per stream on the main thread during loadFiles; multi-stem songs stall playback start for seconds | FIX: fill initial/prefetch buffers via the AsyncLoader worker and wait on it instead of inline decode
            fillInitialBuffer(i, 0);

            if (s.active.load(std::memory_order_acquire)) {
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

        exists.store(true, std::memory_order_release);
        mixerState.store(3, std::memory_order_release);
    }

    void destroy() {
        if (!exists.load(std::memory_order_acquire)) return;
        
        exists.store(false, std::memory_order_release);
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
        playbackRate.store(1.0f, std::memory_order_release);
        mixerState.store(3, std::memory_order_release);
        
        // Reset prediction state
        lastQueriedFrames.store(0, std::memory_order_relaxed);
        lastQuerySystemTime.store(0, std::memory_order_relaxed);
        lastQueryPlaybackRate.store(1.0, std::memory_order_relaxed);
        totalFramesProcessed.store(0, std::memory_order_relaxed);  // <-- Critical: reset frame counter
        lastLoadFrame = 0;                                         // <-- must reset: otherwise newTotalFrames - lastLoadFrame underflows after restart
        
        memset(&device, 0, sizeof(ma_device));
    }

        void start() {
        if (!exists.load(std::memory_order_acquire)) return;
        if (mixerState.load(std::memory_order_acquire) == 3) seekToPCMFrame(0);
        if (asyncLoader) asyncLoader->resumeLoading();
        
        // FIX: Set to playing BEFORE starting the device so the callback immediately knows the state
        mixerState.store(1, std::memory_order_release); 
        
        // Initialize prediction anchor at current position (frame 0 or seek position)
        ma_uint64 startFrame = 0;
        if (!streams.empty()) {
            startFrame = streams[longestDecoderIndex].filePosition.load(std::memory_order_relaxed);
        }
        lastQueriedFrames.store(startFrame, std::memory_order_relaxed);
        lastQuerySystemTime.store(std::chrono::steady_clock::now().time_since_epoch().count(), std::memory_order_relaxed);
        lastQueryPlaybackRate.store(playbackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        
        ma_device_start(&device);
    }

    void stop() {
        if (!exists.load(std::memory_order_acquire)) return;
        
        // FIX: Set to paused BEFORE stopping the device to prevent the callback from overwriting it
        mixerState.store(2, std::memory_order_release); 
        if (asyncLoader) asyncLoader->pauseLoading();
        ma_device_stop(&device);
    }

    bool stopped() const { return mixerState.load(std::memory_order_acquire) == 3; }

    void seekToPCMFrame(int64_t pos) {
        if (!exists.load(std::memory_order_acquire)) return;

        // The device's actual running state can diverge from mixerState: the audio
        // callback sets mixerState to 3 (stopped) on underrun while the device keeps
        // running, which happens when the main thread is stalled and the worker can't
        // refill buffers in time. If we gated stop/restart on mixerState==1, a seek in
        // that state would reset the PCM buffers while the callback is still reading
        // them (data race). Always gate on the device's real state instead.
        bool deviceRunning = ma_device_is_started(&device);
        
        // FIX: Pause immediately to lock the state before touching the decoder/device
        if (deviceRunning) {
            mixerState.store(2, std::memory_order_release); 
        }

        if (asyncLoader) asyncLoader->pauseLoading();
        if (asyncLoader) asyncLoader->waitUntilIdle();

        if (deviceRunning) ma_device_stop(&device);

        for (size_t i = 0; i < streams.size(); i++) {
            DecoderStream& s = streams[i];
            ma_uint64 target = std::min<ma_uint64>(
                (ma_uint64)std::max<int64_t>(pos, 0), s.decoderLength);

            s.resetState();
            fillInitialBuffer(i, target);
            if (s.active.load(std::memory_order_acquire) && target < s.decoderLength) 
                s.filePosition.store(target, std::memory_order_release);

            if (s.active.load(std::memory_order_acquire)) {
                loadNextBufferSync(i);
                if (s.asyncState.nextBufferReady.load(std::memory_order_relaxed))
                    loadLoadingBufferSync(i);
            }

            // Reposition the worker-owned decoder to the seek target.  After a
            // song restart (destroy+init) the worker decoder is freshly opened at
            // frame 0, so without this the worker's next fill would perform a huge
            // forward seek (0 -> target+4410) whose stb_vorbis coarse seek can fail,
            // producing an empty next buffer and stalling/restarting the stream.
            // The worker is paused and idle here (waitUntilIdle above), so touching
            // workerDecoder from the main thread is safe.
            if (s.workerDecoderInitialized)
                ma_decoder_seek_to_pcm_frame(&s.workerDecoder, target);
        }

        mixerState.store((pos < (int64_t)streams[longestDecoderIndex].decoderLength) ? 2 : 3, std::memory_order_release);

        // Always reset prediction anchor on seek (regardless of device state)
        lastQueriedFrames.store((ma_uint64)pos, std::memory_order_relaxed);
        lastQuerySystemTime.store(std::chrono::steady_clock::now().time_since_epoch().count(), std::memory_order_relaxed);
        lastQueryPlaybackRate.store(playbackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);

        if (deviceRunning && mixerState.load(std::memory_order_acquire) == 2) {
            if (asyncLoader) asyncLoader->resumeLoading();
            mixerState.store(1, std::memory_order_release); // Set state before starting device
            ma_device_start(&device);
        }
    }

    void deactivate_decoder(int index) {
        if (index >= 0 && index < (int)streams.size())
            streams[index].active.store(false, std::memory_order_release);
    }

    void amplify_decoder(int index, double volume) {
        if (index >= 0 && index < (int)decoderVolumes.size())
            decoderVolumes[index] = (float)volume;
    }

    void   setPlaybackRate(float value) { playbackRate.store(value, std::memory_order_release); }
    void   setStretchEnabled(bool value) { stretchEnabled.store(value, std::memory_order_release); }
    double getGlobalVolume() const      { return MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed); }
    double setGlobalVolume(double v)    { MUSIC_MASTER_VOLUME_099.store(v, std::memory_order_relaxed); return v; }
    int    getMixerState() const        { return mixerState.load(std::memory_order_acquire); }

    // Returns smooth predicted playback position in milliseconds (0.1ms resolution)
    // Automatically interpolates between audio callback updates using system clock
    double getPlaybackPosition() const {
        if (!exists.load(std::memory_order_acquire)) return 0.0;
        if (streams.empty()) return 0.0;
        
        const DecoderStream& s = streams[longestDecoderIndex];
        if (!s.active.load(std::memory_order_acquire))
            return (double)s.decoderLength / (SAMPLE_RATE * 0.001);
        
        // Use callback frame counter (updated every ~10ms) as anchor + system clock interpolation
        ma_uint64 baseFrames = lastQueriedFrames.load(std::memory_order_relaxed);
        long long baseTimeNs = lastQuerySystemTime.load(std::memory_order_relaxed);
        double rate = lastQueryPlaybackRate.load(std::memory_order_relaxed);
        
        if (baseFrames == 0 && baseTimeNs == 0) {
            // First call - initialize anchor from the real consumed position.
            // (totalFramesProcessed is wall-clock only and cumulative since
            // load, so it is the wrong anchor after rate changes or seeks.)
            ma_uint64 frames = streams[longestDecoderIndex].filePosition.load(std::memory_order_relaxed);
            lastQueriedFrames.store(frames, std::memory_order_relaxed);
            lastQuerySystemTime.store(
                std::chrono::steady_clock::now().time_since_epoch().count(),
                std::memory_order_relaxed
            );
            lastQueryPlaybackRate.store(playbackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
            baseFrames = frames;
            baseTimeNs = lastQuerySystemTime.load(std::memory_order_relaxed);
            rate = lastQueryPlaybackRate.load(std::memory_order_relaxed);
        }
        
        // Interpolate: baseFrames + elapsedTime * sampleRate * rate
        long long nowNs = std::chrono::steady_clock::now().time_since_epoch().count();
        double elapsedSeconds = (nowNs - baseTimeNs) * 1e-9;
        double predictedFramesD = baseFrames + elapsedSeconds * SAMPLE_RATE * rate;
        ma_uint64 predictedFrames = (ma_uint64)predictedFramesD;
        
        if (predictedFrames >= s.decoderLength) predictedFrames = s.decoderLength;
        
        // Round to 0.1ms (5 frames @ 48kHz) for consistent smooth stepping
        predictedFrames = (predictedFrames / 5) * 5;
        
        return (double)predictedFrames / (SAMPLE_RATE * 0.001);
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
        s.fillBufferTemp(decodeStart, s.activeBuffer, &framesRead);

        s.bufferStartPos = decodeStart;
        s.validFrames    = framesRead;
        s.localReadPos   = (startFrame >= decodeStart) ? startFrame - decodeStart : 0;

        if (s.localReadPos >= TOTAL_BUFFER_FRAMES)
            s.localReadPos = TOTAL_BUFFER_FRAMES - 1;

        s.filePosition.store(startFrame, std::memory_order_release);
        s.active.store((startFrame < s.decoderLength && framesRead > 0), std::memory_order_release);
        s.asyncState.needsLoad.store(false, std::memory_order_release);
    }

    void loadNextBufferSync(size_t index) {
        DecoderStream& s = streams[index];
        if (!s.active.load(std::memory_order_acquire) || s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) return;

        ma_uint64 start = s.bufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;
        if (start >= s.decoderLength) return;

        ma_uint64 framesRead = 0;
        s.fillBufferTemp(start, s.nextBuffer, &framesRead);
        s.asyncState.nextBufferStartPos    = start;
        s.asyncState.nextBufferValidFrames = framesRead;
        s.asyncState.nextBufferReady.store(true, std::memory_order_release);
    }

    void loadLoadingBufferSync(size_t index) {
        DecoderStream& s = streams[index];
        if (!s.active.load(std::memory_order_acquire) ||
             s.asyncState.loadingBufferReady.load(std::memory_order_relaxed) ||
            !s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) return;

        ma_uint64 start = s.asyncState.nextBufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;
        if (start >= s.decoderLength) return;

        ma_uint64 framesRead = 0;
        s.fillBufferTemp(start, s.loadingBuffer, &framesRead);
        s.asyncState.loadingBufferStartPos    = start;
        s.asyncState.loadingBufferValidFrames = framesRead;
        s.asyncState.loadingBufferReady.store(true, std::memory_order_release);
    }

    void doBackgroundLoading() {
        bool anyRequested = false;
        for (size_t i = 0; i < streams.size(); i++) {
            DecoderStream& s = streams[i];
            if (!s.active.load(std::memory_order_acquire)) continue;

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
        if (!s.active.load(std::memory_order_acquire)) return 0;

        // Cache volume calculation to avoid repeated atomic loads and multiplications
        static thread_local double cachedMasterVolume = -1.0;
        static thread_local std::vector<float> precomputedVolumes;

        if (precomputedVolumes.size() != decoderVolumes.size()) {
            precomputedVolumes.resize(decoderVolumes.size(), 0.0f);
            cachedMasterVolume = -1.0;  // Force recalculation on size change
        }

        double currentMasterVolume = MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);
        bool volumesChanged = (currentMasterVolume != cachedMasterVolume);

        if (volumesChanged) {
            cachedMasterVolume = currentMasterVolume;
            for (size_t i = 0; i < decoderVolumes.size(); i++) {
                precomputedVolumes[i] = decoderVolumes[i] * (float)cachedMasterVolume;
            }
        }

        float vol = precomputedVolumes[index];

        // Cache async state flags to reduce atomic loads in the hot loop
        bool nextBufferReady = s.asyncState.nextBufferReady.load(std::memory_order_acquire);
        bool isActive = s.active.load(std::memory_order_acquire);

        if (nextBufferReady && s.shouldSwapBuffers() || s.isBufferLow()) s.trySwapBuffers();

        ma_uint32 framesRead = 0;

        while (framesRead < requestedFrames && isActive) {
            ma_uint64 available = (s.localReadPos < s.validFrames)
                                ? s.validFrames - s.localReadPos : 0;

            if (available == 0) {
                if (s.filePosition.load(std::memory_order_acquire) < s.decoderLength) {
                    if (s.asyncState.nextBufferReady.load(std::memory_order_acquire)) {
                        s.trySwapBuffers();
                        continue;
                    }
                    s.asyncState.needsLoad.store(true, std::memory_order_release);
                    break;
                }
                s.active.store(false, std::memory_order_release);
                isActive = false;
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
            //BOTTLENECK: low atomic RMW (fetch_add) on the audio thread for every read chunk of every stream | FIX: accumulate locally and do a single store to filePosition at the end of readFromBuffer
            s.filePosition.fetch_add(toRead, std::memory_order_relaxed);
            framesRead      += toRead;

            if (s.filePosition.load(std::memory_order_relaxed) >= s.decoderLength) { 
                s.active.store(false, std::memory_order_release); 
                isActive = false;
                break; 
            }
        }
        return framesRead;
    }

    static void data_callback(ma_device* pDevice, void* pOutput,
                              const void* pInput, ma_uint32 frameCount) {
        AudioSystem* sys = static_cast<AudioSystem*>(pDevice->pUserData);
        if (!sys || !sys->exists.load(std::memory_order_acquire)) return;

        float* out = (float*)pOutput;
        memset(out, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

        ma_uint64 newTotalFrames = sys->totalFramesProcessed.fetch_add(frameCount, std::memory_order_relaxed) + frameCount;
        
        // Update prediction anchor every callback (~10ms) to prevent drift.
        // Anchor to the REAL consumed source position (longest stream's
        // filePosition) instead of the wall-clock output counter
        // (totalFramesProcessed). filePosition advances at `playbackRate`
        // (a 2x rate consumes 2x source frames per callback) and is re-based
        // to the target on every seek, so the smoothed time stays correct
        // under BOTH rate changes and seeks. The old code anchored to
        // totalFramesProcessed, which is always 1x (rate bug) and cumulative
        // since load (seek bug, up to seconds of drift).
        ma_uint64 anchorFrames = 0;
        if (!sys->streams.empty())
            anchorFrames = sys->streams[sys->longestDecoderIndex].filePosition.load(std::memory_order_relaxed);
        sys->lastQueriedFrames.store(anchorFrames, std::memory_order_relaxed);
        sys->lastQuerySystemTime.store(
            std::chrono::steady_clock::now().time_since_epoch().count(),
            std::memory_order_relaxed
        );
        sys->lastQueryPlaybackRate.store(sys->playbackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        ma_uint64 framesSinceLastLoad = newTotalFrames - sys->lastLoadFrame;
        ma_uint64 loadIntervalFrames = (SAMPLE_RATE * BG_LOAD_CHECK_INTERVAL) / 1000;

        //BOTTLENECK: low full scan of every stream (multiple acquire atomics each) on the audio thread every ~8ms inside the realtime callback | FIX: move the request loop into the AsyncLoader worker; audio thread only sets one dirty flag
        if (framesSinceLastLoad >= loadIntervalFrames) {
            sys->lastLoadFrame = newTotalFrames;
            sys->doBackgroundLoading();
        }

        bool anyActive = false;
        float rate = sys->playbackRate.load(std::memory_order_acquire);

        if (rate == 1.0f) {
            for (size_t i = 0; i < sys->streams.size(); i++) {
                if (!sys->streams[i].active.load(std::memory_order_acquire)) continue;
                ma_uint32 read = sys->readFromBuffer(i, out, frameCount);
                if (read > 0) anyActive = true;
                if (read < frameCount && sys->streams[i].active.load(std::memory_order_acquire))
                    sys->streams[i].asyncState.needsLoad.store(true, std::memory_order_release);
            }
        } else {
            static_assert(MAX_CALLBACK_FRAMES >= 4096,
                          "MAX_CALLBACK_FRAMES too small for pitched playback buffers");

            if (frameCount > MAX_CALLBACK_FRAMES) {
                // FIX: Check state before overwriting
                int currentState = sys->mixerState.load(std::memory_order_acquire);
                if (currentState != 2) sys->mixerState.store(anyActive ? 1 : 3, std::memory_order_release);
                (void)pInput;
                return;
            }

            float* inputMix       = sys->pitchInputMix;
            float* stretchedOutput = sys->pitchStretchedOut;

            static double positionError = 0;
            double exactRead = frameCount * rate + positionError;
            ma_uint32 maxToRead = (ma_uint32)exactRead;

            memset(inputMix,        0, sizeof(float) * maxToRead * CHANNEL_COUNT);
            memset(stretchedOutput, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

            positionError = exactRead - maxToRead;

            for (size_t i = 0; i < sys->streams.size(); i++) {
                if (!sys->streams[i].active.load(std::memory_order_acquire)) continue;
                ma_uint32 read = sys->readFromBuffer(i, inputMix, maxToRead);
                if (read > 0) anyActive = true;
                if (read < maxToRead && sys->streams[i].active.load(std::memory_order_acquire))
                    sys->streams[i].asyncState.needsLoad.store(true, std::memory_order_release);
            }

            if (anyActive) {
                if (sys->stretchEnabled.load(std::memory_order_acquire)) {
                    if (!sys->stretch) {
                        sys->stretch = new signalsmith::stretch::SignalsmithStretch();
                        sys->stretch->configure(CHANNEL_COUNT, int(SAMPLE_RATE * 0.1), int(SAMPLE_RATE * 0.05)); // ratio = 2.0
                    }
                    //BOTTLENECK: high FFT time-stretch of the entire mix synchronously in the realtime audio callback on every buffer (SignalsmithStretch) -> dropout source whenever playback rate != 1.0 | FIX: use the fastest preset / larger block, or run stretch on a dedicated thread with double buffering
                    sys->stretch->process(inputMix, maxToRead, stretchedOutput, frameCount);
                    memcpy(out, stretchedOutput, sizeof(float) * frameCount * CHANNEL_COUNT);
                } else if (maxToRead > 0) {
                    // Toggle OFF: cheap linear resample (pitch-shift style) instead of FFT stretch.
                    double step = (frameCount > 1) ? (double)(maxToRead - 1) / (frameCount - 1) : 0.0;
                    for (ma_uint32 o = 0; o < frameCount; o++) {
                        double srcPos = o * step;
                        ma_uint32 i0 = (ma_uint32)srcPos;
                        if (i0 >= maxToRead) i0 = maxToRead - 1;
                        ma_uint32 i1 = (i0 + 1 < maxToRead) ? i0 + 1 : i0;
                        double frac = srcPos - (double)i0;
                        for (int c = 0; c < CHANNEL_COUNT; c++) {
                            float s0 = inputMix[i0 * CHANNEL_COUNT + c];
                            float s1 = inputMix[i1 * CHANNEL_COUNT + c];
                            out[o * CHANNEL_COUNT + c] = (float)(s0 + frac * (s1 - s0));
                        }
                    }
                }
            }
        }

        // FIX: Only update mixerState if we are not paused.
        // This prevents the callback from accidentally "un-pausing" the engine while ma_device_stop is finishing.
        int currentState = sys->mixerState.load(std::memory_order_acquire);
        if (currentState != 2) {
            sys->mixerState.store(anyActive ? 1 : 3, std::memory_order_release);
        }
        
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
        playbackRate.store(other.playbackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        mixerState.store(other.mixerState.load(std::memory_order_relaxed), std::memory_order_relaxed);
        exists.store(other.exists.load(std::memory_order_relaxed), std::memory_order_relaxed);
        stretchEnabled.store(other.stretchEnabled.load(std::memory_order_relaxed), std::memory_order_relaxed);

        other.stretch = nullptr;  other.asyncLoader    = nullptr;
        other.longestDecoderIndex = 0;  other.playbackRate.store(1.0f, std::memory_order_relaxed);
        other.mixerState.store(3, std::memory_order_relaxed);
        other.exists.store(false, std::memory_order_relaxed);

        // Move frame tracking state for background loading
        totalFramesProcessed.store(other.totalFramesProcessed.load(std::memory_order_relaxed), std::memory_order_relaxed);
        lastLoadFrame        = other.lastLoadFrame;
        other.totalFramesProcessed.store(0, std::memory_order_relaxed);
        other.lastLoadFrame        = 0;

        // Move prediction state for smooth audio time
        lastQueriedFrames.store(other.lastQueriedFrames.load(std::memory_order_relaxed), std::memory_order_relaxed);
        lastQuerySystemTime.store(other.lastQuerySystemTime.load(std::memory_order_relaxed), std::memory_order_relaxed);
        lastQueryPlaybackRate.store(other.lastQueryPlaybackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        other.lastQueriedFrames.store(0, std::memory_order_relaxed);
        other.lastQuerySystemTime.store(0, std::memory_order_relaxed);
        other.lastQueryPlaybackRate.store(1.0, std::memory_order_relaxed);
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
    std::atomic<bool> active{false};
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
        active.store(false, std::memory_order_release);
        looping = true; filePath.clear();
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
        //BOTTLENECK: mid blocking full-track decode + multi-MB PCM allocation on the calling (main) thread at load time | FIX: decode on a worker thread and swap the buffer in when ready
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
        active.store(false, std::memory_order_release);
        looping    = true;
        readPos    = 0;
        return true;
    }

    void play()  { if (pcmData) { readPos = 0; active.store(true, std::memory_order_release); } }
    void stop()  { active.store(false, std::memory_order_release); readPos = 0; }
    void setVolume(float v)  { volume = v; }
    void setLooping(bool lp) { looping = lp; }

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames) {
        if (!active.load(std::memory_order_acquire) || !pcmData || frameCount == 0) return 0;

        float vol = volume * MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);
        ma_uint32 filled = 0;

        while (filled < requestedFrames) {
            ma_uint64 remaining = frameCount - readPos;
            if (remaining == 0) {
                if (looping) { readPos = 0; remaining = frameCount; }
                else         { active.store(false, std::memory_order_release); break; }
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
        active.store(other.active.load(std::memory_order_relaxed), std::memory_order_relaxed);
        looping    = other.looping;
        filePath   = std::move(other.filePath);
        other.pcmData = nullptr; other.frameCount = 0; other.readPos = 0;
        other.active.store(false, std::memory_order_relaxed);
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
    std::atomic<bool> playing{false};

    SoundEffectInstance() = default;

    SoundEffectInstance(float* data, ma_uint64 frames, double vol = 1.0f)
        : pcmData(data), frameCount(frames), playbackPosition(0),
          volume(vol), playing(true) {}

    // FIX: Explicit move constructor to handle std::atomic<bool>
    SoundEffectInstance(SoundEffectInstance&& other) noexcept
        : pcmData(other.pcmData),
          frameCount(other.frameCount),
          playbackPosition(other.playbackPosition),
          volume(other.volume),
          playing(other.playing.load(std::memory_order_relaxed))
    {
        other.pcmData = nullptr;
        other.frameCount = 0;
        other.playbackPosition = 0;
        other.volume = 1.0f;
        other.playing.store(false, std::memory_order_relaxed);
    }

    // FIX: Explicit move assignment operator
    SoundEffectInstance& operator=(SoundEffectInstance&& other) noexcept {
        if (this != &other) {
            pcmData = other.pcmData;
            frameCount = other.frameCount;
            playbackPosition = other.playbackPosition;
            volume = other.volume;
            playing.store(other.playing.load(std::memory_order_relaxed), std::memory_order_relaxed);

            other.pcmData = nullptr;
            other.frameCount = 0;
            other.playbackPosition = 0;
            other.volume = 1.0f;
            other.playing.store(false, std::memory_order_relaxed);
        }
        return *this;
    }

    SoundEffectInstance(const SoundEffectInstance&) = delete;
    SoundEffectInstance& operator=(const SoundEffectInstance&) = delete;

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames) {
        if (!playing.load(std::memory_order_acquire) || !pcmData) return 0;

        ma_uint64 remaining = frameCount - playbackPosition;
        if (remaining == 0) { playing.store(false, std::memory_order_release); return 0; }

        ma_uint32 toRead = (ma_uint32)std::min<ma_uint64>(remaining, requestedFrames);
        float* src = pcmData + (playbackPosition * CHANNEL_COUNT);
        float  vol = volume * MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);

        // UPDATED CALL SITE: Uses the runtime dispatcher
        g_mix_func(output, src, (int)(toRead * CHANNEL_COUNT), vol);

        playbackPosition += toRead;
        if (playbackPosition >= frameCount) playing.store(false, std::memory_order_release);
        return toRead;
    }

    bool isPlaying() const { return playing.load(std::memory_order_acquire); }
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
                inst.playbackPosition = 0; inst.volume = volume; inst.playing.store(true, std::memory_order_release);
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
    void  stopAll()             { for (auto& i : instances) { i.playing.store(false, std::memory_order_release); i.playbackPosition = 0; } playingCount = 0; }
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
//  AudioMixerManager (LOCK-FREE)
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
        if (deviceInitialized) { 
            ma_device_uninit(&device); 
            deviceInitialized = false; 
        }
        backgroundTracks.clear(); soundEffectPools.clear();
        backgroundTrackMap.clear(); soundEffectMap.clear();
        for (int b = 0; b < 3; b++) {
            bgSnapshot[b].clear();
            sfxSnapshot[b].clear();
        }
    }

    int loadBackgroundTrack(const char* path) {
        if (!deviceInitialized && !initialize()) return -1;
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
        auto it = backgroundTrackMap.find(std::string(path));
        return (it != backgroundTrackMap.end()) ? it->second : -1;
    }
    bool isBackgroundTrackLoaded(const char* path) { return findBackgroundTrack(path) >= 0; }

    void playBackgroundTrack(int idx)  { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].play(); }
    void stopBackgroundTrack(int idx)  { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].stop(); }
    void setBackgroundTrackVolume(int idx, float v)  { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].setVolume(v); }
    void setBackgroundTrackLooping(int idx, bool lp) { if (inRange(idx, backgroundTracks)) backgroundTracks[idx].setLooping(lp); }
    bool isBackgroundTrackPlaying(int idx) { return inRange(idx, backgroundTracks) && backgroundTracks[idx].active.load(std::memory_order_acquire); }

    int loadSoundEffect(const char* path) {
        if (!deviceInitialized && !initialize()) return -1;
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
        if (!inRange(idx, backgroundTracks)) return;

        eraseAndFixup(backgroundTrackMap, idx);
        backgroundTracks.erase(backgroundTracks.begin() + idx);
        publishSnapshot();
    }

    void unloadSoundEffect(int idx) {
        if (!inRange(idx, soundEffectPools)) return;

        eraseAndFixup(soundEffectMap, idx);
        soundEffectPools.erase(soundEffectPools.begin() + idx);
        publishSnapshot();
    }

    double setMasterVolume(double v) { MUSIC_MASTER_VOLUME_099.store(v, std::memory_order_relaxed); return v; }
    double getMasterVolume() const  { return MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed); }

private:
    std::deque<BackgroundTrack>  backgroundTracks;
    std::deque<SoundEffectPool>  soundEffectPools;

    std::unordered_map<std::string, int> backgroundTrackMap;
    std::unordered_map<std::string, int> soundEffectMap;

    ma_device device;
    bool  deviceInitialized = false;

    // Lock-free triple buffer for snapshots
    std::vector<BackgroundTrack*> bgSnapshot[3];
    std::vector<SoundEffectPool*> sfxSnapshot[3];
    
    std::atomic<int> readerIndex{0};
    std::atomic<int> newestIndex{1};

    void publishSnapshot() {
        int r = readerIndex.load(std::memory_order_acquire);
        int n = newestIndex.load(std::memory_order_acquire);
        
        // FIX: Robust triple buffer index calculation
        int next;
        if (r == n) {
            next = (r + 1) % 3;
        } else {
            next = 3 - r - n;
        }
        
        bgSnapshot[next].clear();
        for (auto& t : backgroundTracks) bgSnapshot[next].push_back(&t);
        sfxSnapshot[next].clear();
        for (auto& p : soundEffectPools)  sfxSnapshot[next].push_back(&p);
        
        newestIndex.store(next, std::memory_order_release);
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

        // Lock-free snapshot read
        int r = mixer->readerIndex.load(std::memory_order_relaxed);
        int n = mixer->newestIndex.load(std::memory_order_acquire);
        if (r != n) {
            mixer->readerIndex.store(n, std::memory_order_release);
            r = n;
        }

        for (BackgroundTrack* track : mixer->bgSnapshot[r])
            if (track->active.load(std::memory_order_acquire)) track->readFrames(out, frameCount);

        for (SoundEffectPool* pool : mixer->sfxSnapshot[r])
            pool->readFrames(out, frameCount);

        (void)pInput;
    }
};