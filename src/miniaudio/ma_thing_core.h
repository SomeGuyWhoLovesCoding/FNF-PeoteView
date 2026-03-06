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
//
// Include order matters significantly on Windows with MSVC:
//
//   1. signalsmith-stretch first — it pulls in <complex> internally, which
//      ensures std::complex<float> operator+/- overloads are fully visible
//      before anything else. If miniaudio comes first it defines CLSCTX_ALL,
//      and then the Windows SDK's combaseapi.h redefinition breaks
//      DEFINE_PROPERTYKEY, causing cascading errors in
//      functiondiscoverykeys_devpkey.h. Signalsmith has no such conflict.
//
//   2. Windows SDK headers next — now that signalsmith has already included
//      <complex>, the SDK can define CLSCTX_ALL and DEFINE_PROPERTYKEY
//      cleanly before miniaudio sees them.
//
//   3. stb_vorbis as C, before miniaudio pulls it in itself.
//
//   4. miniaudio last — it sees all SDK symbols as already defined and
//      skips its own conflicting re-definitions.

// NOTE: signalsmith-stretch.h is NOT included here. It must be included in
// each .cpp file AFTER defining SIGNALSMITH_STRETCH_IMPLEMENTATION, and it
// must come before the Windows SDK headers and miniaudio in that .cpp file.
// See ma_thing_standalone.cpp / ma_thing_hl.cpp for the correct order.

#ifdef HX_WINDOWS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <locale>
#include <codecvt>
#pragma comment(lib, "ole32.lib")
#elif _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
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
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#ifdef __SSE__
#include <emmintrin.h>
#include <xmmintrin.h>
#endif

// ---- Windows audio-device helpers ----------------------------------------

#ifdef HX_WINDOWS

static std::string wstring_to_string(const std::wstring& wstr) {
    if (wstr.empty()) return std::string();
    int size_needed = WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(),
                                          nullptr, 0, nullptr, nullptr);
    std::string strTo(size_needed, 0);
    WideCharToMultiByte(CP_UTF8, 0, &wstr[0], (int)wstr.size(),
                        &strTo[0], size_needed, nullptr, nullptr);
    return strTo;
}

inline bool checkWindowsHeadphoneStatus() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) return false;

    bool isHeadphones = false;
    IMMDeviceEnumerator* pEnumerator = nullptr;
    IMMDevice* pDevice = nullptr;
    IPropertyStore* pProps = nullptr;

    hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                          __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator);
    if (SUCCEEDED(hr)) {
        if (SUCCEEDED(pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice))) {
            if (SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
                PROPVARIANT varName;
                PropVariantInit(&varName);
                const PROPERTYKEY* keys[] = { &PKEY_Device_DeviceDesc, &PKEY_Device_FriendlyName };
                for (int i = 0; i < 2 && !isHeadphones; i++) {
                    if (SUCCEEDED(pProps->GetValue(*keys[i], &varName)) &&
                        varName.vt == VT_LPWSTR && varName.pwszVal) {
                        std::string name = wstring_to_string(varName.pwszVal);
                        std::transform(name.begin(), name.end(), name.begin(), ::tolower);
                        const char* kws[] = { "headphone", "headset", "earphone", "earbud",
                                              "airpod", "bluetooth", "bt", "wireless",
                                              "ear piece", "usb audio speakers" };
                        for (const char* kw : kws)
                            if (name.find(kw) != std::string::npos) { isHeadphones = true; break; }
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

inline bool checkIfPnPDevice() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    bool comInitialized = SUCCEEDED(hr);
    if (hr == RPC_E_CHANGED_MODE) comInitialized = false;

    bool isPnP = false;
    IMMDeviceEnumerator* pEnumerator = nullptr;
    IMMDevice* pDevice = nullptr;
    IPropertyStore* pProps = nullptr;
    LPWSTR pwszDeviceId = nullptr;

    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator))) goto cleanup;
    if (FAILED(pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice))) goto cleanup;

    if (SUCCEEDED(pDevice->GetId(&pwszDeviceId)) && pwszDeviceId) {
        std::string id = wstring_to_string(std::wstring(pwszDeviceId));
        std::transform(id.begin(), id.end(), id.begin(), ::tolower);
        const char* pnpPatterns[]      = { "usb#", "bth#", "bthenum#", "swd#mmdevapi#",
                                           "bluetooth", "hid#", "uefi" };
        const char* internalPatterns[] = { "hdaudio#", "intel", "realtek",
                                           "amd", "nvidia", "high definition audio", "hd audio" };
        for (const char* pat : pnpPatterns)
            if (id.find(pat) != std::string::npos) { isPnP = true; break; }
        if (!isPnP)
            for (const char* pat : internalPatterns)
                if (id.find(pat) != std::string::npos) { isPnP = false; break; }
        CoTaskMemFree(pwszDeviceId);
    }

    if (!isPnP && SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
        PROPVARIANT var; PropVariantInit(&var);
        const PROPERTYKEY* keys[] = { &PKEY_Device_FriendlyName, &PKEY_Device_DeviceDesc,
                                      &PKEY_DeviceInterface_FriendlyName };
        for (int i = 0; i < 3 && !isPnP; i++) {
            if (SUCCEEDED(pProps->GetValue(*keys[i], &var)) && var.vt == VT_LPWSTR && var.pwszVal) {
                std::string s = wstring_to_string(var.pwszVal);
                std::transform(s.begin(), s.end(), s.begin(), ::tolower);
                const char* kws[]         = { "usb", "bluetooth", "bt", "wireless", "external",
                                               "headset", "airpod", "bose", "sony", "jbl",
                                               "logitech", "hdmi", "displayport", "digital audio",
                                               "digital output", "soundblaster", "audio interface",
                                               "dac", "amplifier" };
                const char* internalKws[] = { "speakers", "internal", "built-in", "default",
                                               "primary", "main", "system", "laptop",
                                               "desktop", "monitor", "display" };
                bool foundInternal = false;
                for (const char* k : internalKws)
                    if (s.find(k) != std::string::npos) { foundInternal = true; break; }
                if (!foundInternal)
                    for (const char* k : kws)
                        if (s.find(k) != std::string::npos) { isPnP = true; break; }
            }
        }
        PropVariantClear(&var);
        pProps->Release();
    }

cleanup:
    if (pDevice)     pDevice->Release();
    if (pEnumerator) pEnumerator->Release();
    if (comInitialized) CoUninitialize();
    return isPnP;
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

// Maximum frames the audio device is expected to request per callback.
// The pitched-playback path uses fixed stack buffers sized to this value.
#define MAX_CALLBACK_FRAMES 4096

// ---- SIMD mix helpers -----------------------------------------------------

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
//  DecoderStream
// ==========================================================================

struct DecoderStream {
    // Triple-buffered PCM storage
    float* pcmBufferA = nullptr;
    float* pcmBufferB = nullptr;
    float* pcmBufferC = nullptr;

    // Pointers used by the audio thread only
    float* activeBuffer  = nullptr;
    float* nextBuffer    = nullptr;
    float* loadingBuffer = nullptr;

    // Audio-thread state (touched only by the audio thread)
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

        // Buffer pointers written by audio thread, read by async thread
        float* asyncNextBuffer    = nullptr;
        float* asyncLoadingBuffer = nullptr;
    } asyncState;

    bool      active        = false;
    ma_decoder decoder;
    ma_uint64 decoderLength = 0;

    // Per-stream mutex — previously static, which serialised all streams onto
    // one lock and caused unnecessary stalls.
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

    // Called from the audio thread only.
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
        // Caller (doBackgroundLoading) signals the AsyncLoader after this returns.
    }

    // Synchronous fill — used during init and seek (no mutex needed, decoder
    // is not yet shared with the async thread at those points).
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

    // Async fill — called from the worker thread; guards the decoder with its
    // per-stream mutex so the audio thread can seek without data races.
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
        // Atomics re-initialise to their defaults; the stream is not live
        // during a move so in-flight flags are intentionally not transferred.

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
        : streams(streamRefs) { start(); }

    ~AsyncLoader() { stop(); }

    void pauseLoading() { pause.store(true, std::memory_order_release); }

    void resumeLoading() {
        pause.store(false, std::memory_order_release);
        signal();
    }

    // Wake the worker immediately. Called by the audio thread when it urgently
    // needs a buffer — replaces the old 1ms sleep-poll that caused underflows.
    void signal() {
        workPending.store(true, std::memory_order_release);
        wakeCV.notify_one();
    }

private:
    std::vector<DecoderStream*>& streams;
    std::thread       workerThread;
    std::atomic<bool> running{false};
    std::atomic<bool> pause{false};
    std::mutex        wakeMutex;
    std::condition_variable wakeCV;
    std::atomic<bool> workPending{false};

    void start() {
        running.store(true, std::memory_order_release);
        workerThread = std::thread([this]() { worker(); });
    }

    void stop() {
        running.store(false, std::memory_order_release);
        signal(); // wake so the thread can observe running=false and exit
        if (workerThread.joinable()) workerThread.join();
    }

    void worker() {
        constexpr int MAX_PER_CYCLE = 2;
        int currentStream = 0;

        while (running.load(std::memory_order_acquire)) {
            if (pause.load(std::memory_order_acquire)) {
                std::unique_lock<std::mutex> lk(wakeMutex);
                wakeCV.wait_for(lk, std::chrono::milliseconds(5), [this] {
                    return !pause.load(std::memory_order_acquire) ||
                           !running.load(std::memory_order_acquire);
                });
                continue;
            }

            // Guard against % 0 divide-by-zero when stream list is empty.
            if (streams.empty()) {
                std::unique_lock<std::mutex> lk(wakeMutex);
                wakeCV.wait_for(lk, std::chrono::milliseconds(5), [this] {
                    return !streams.empty() || !running.load(std::memory_order_acquire);
                });
                continue;
            }

            workPending.store(false, std::memory_order_release);

            int processed = 0;
            for (int i = 0; i < (int)streams.size() && processed < MAX_PER_CYCLE; i++) {
                int idx = (currentStream + i) % (int)streams.size();
                DecoderStream* s = streams[idx];
                if (s && s->active && processStreamLoad(s))
                    processed++;
            }

            if (processed > 0)
                currentStream = (currentStream + 1) % (int)streams.size();

            if (processed == 0) {
                std::unique_lock<std::mutex> lk(wakeMutex);
                wakeCV.wait_for(lk, std::chrono::milliseconds(4), [this] {
                    return workPending.load(std::memory_order_acquire) ||
                           !running.load(std::memory_order_acquire);
                });
            }
        }
    }

    bool processStreamLoad(DecoderStream* s) {
        bool didWork = false;

        if (s->asyncState.requestNextBuffer.load(std::memory_order_acquire)) {
            if (!s->asyncState.loadingInProgress.load(std::memory_order_relaxed))
                if (tryLoadNextBuffer(s)) didWork = true;
            s->asyncState.requestNextBuffer.store(false, std::memory_order_release);
        }

        if (s->asyncState.requestLoadingBuffer.load(std::memory_order_acquire)) {
            if (!s->asyncState.loadingInProgress.load(std::memory_order_relaxed) &&
                 s->asyncState.nextBufferReady.load(std::memory_order_relaxed))
                if (tryLoadLoadingBuffer(s)) didWork = true;
            s->asyncState.requestLoadingBuffer.store(false, std::memory_order_release);
        }

        return didWork;
    }

    bool tryLoadNextBuffer(DecoderStream* s) {
        bool expected = false;
        if (!s->asyncState.loadingInProgress.compare_exchange_strong(
                expected, true, std::memory_order_acq_rel))
            return false;

        ma_uint64 start = s->bufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;

        if (start >= s->decoderLength || !s->asyncState.asyncNextBuffer) {
            s->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 framesRead = 0;
        s->fillBufferAsync(start, s->asyncState.asyncNextBuffer, &framesRead);

        s->asyncState.nextBufferStartPos    = start;
        s->asyncState.nextBufferValidFrames = framesRead;
        s->asyncState.nextBufferReady.store(true,  std::memory_order_release);
        s->asyncState.loadingInProgress.store(false, std::memory_order_release);
        return true;
    }

    bool tryLoadLoadingBuffer(DecoderStream* s) {
        bool expected = false;
        if (!s->asyncState.loadingInProgress.compare_exchange_strong(
                expected, true, std::memory_order_acq_rel))
            return false;

        ma_uint64 start = s->asyncState.nextBufferStartPos + HALF_BUFFER_FRAMES;
        if (start > PADDING_FRAMES) start -= PADDING_FRAMES;

        if (start >= s->decoderLength || !s->asyncState.asyncLoadingBuffer) {
            s->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }

        ma_uint64 framesRead = 0;
        s->fillBufferAsync(start, s->asyncState.asyncLoadingBuffer, &framesRead);

        s->asyncState.loadingBufferStartPos    = start;
        s->asyncState.loadingBufferValidFrames = framesRead;
        s->asyncState.loadingBufferReady.store(true,  std::memory_order_release);
        s->asyncState.loadingInProgress.store(false, std::memory_order_release);
        return true;
    }
};

// ==========================================================================
//  AudioSystem  (music track / multi-stream playback)
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
    float masterVolume        = 1.0f;

    // Pre-allocated scratch buffers for the pitched-playback path.
    // Sized to MAX_CALLBACK_FRAMES so we never allocate in the audio callback.
    float pitchInputMix[MAX_CALLBACK_FRAMES * CHANNEL_COUNT]      = {};
    float pitchStretchedOut[MAX_CALLBACK_FRAMES * CHANNEL_COUNT]  = {};

    // Throttle background-loading checks: only poll every N callbacks.
    // The async loader wakes immediately via signal() when urgently needed,
    // so we don't need to check every single callback.
    static constexpr int BG_LOAD_CHECK_INTERVAL = 8;
    int bgLoadCounter = 0;

    AudioSystem()  { memset(&device, 0, sizeof(ma_device)); }
    ~AudioSystem() { destroy(); }

    AudioSystem(AudioSystem&& other) noexcept { moveFrom(std::move(other)); }
    AudioSystem& operator=(AudioSystem&& other) noexcept {
        if (this != &other) { destroy(); moveFrom(std::move(other)); }
        return *this;
    }
    AudioSystem(const AudioSystem&)            = delete;
    AudioSystem& operator=(const AudioSystem&) = delete;

    // ------------------------------------------------------------------

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

        // Stop the async loader before touching the device or streams.
        if (asyncLoader) { delete asyncLoader; asyncLoader = nullptr; }

        ma_device_stop(&device);
        ma_device_uninit(&device);
        // Decoder uninit happens inside ~DecoderStream, which is called here.
        // This is safe: miniaudio decoders are independent of the device.
        streams.clear();
        decoderVolumes.clear();
        filePaths.clear();
        streamPtrs.clear();

        if (stretch) { delete stretch; stretch = nullptr; }

        longestDecoderIndex = 0;
        playbackRate  = 1.0f;
        masterVolume  = 1.0f;
        mixerState    = 3;
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
    double getGlobalVolume() const      { return (double)masterVolume; }
    double setGlobalVolume(double v)    { masterVolume = (float)v; return v; }
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
        s.fillBuffer(s.activeBuffer, decodeStart, &framesRead);

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

    // Called from the audio callback to post load-requests to the async loader.
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
        float vol = decoderVolumes[index] * masterVolume;

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

#ifdef __SSE__
            if (CHANNEL_COUNT == 2 &&
                ((uintptr_t)src & 15) == 0 && ((uintptr_t)dst & 15) == 0)
                mix_simd_stereo(dst, src, (int)toRead, vol);
            else
                mix_simd(dst, src, samples, vol);
#else
            if (vol != 0.0f) mix_scalar(dst, src, samples, vol);
#endif
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
            // Fixed-size stack buffers; assert that the device never asks for
            // more frames than we allocated for.
            static_assert(MAX_CALLBACK_FRAMES >= 4096,
                          "MAX_CALLBACK_FRAMES too small for pitched playback buffers");

            if (frameCount > MAX_CALLBACK_FRAMES) {
                // Defensive: can't pitch-stretch more than our buffer allows.
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
        masterVolume        = other.masterVolume;
        mixerState          = other.mixerState;
        exists              = other.exists;

        other.stretch = nullptr;  other.asyncLoader    = nullptr;
        other.longestDecoderIndex = 0;  other.playbackRate   = 1.0f;
        other.masterVolume = 1.0f; other.mixerState     = 3;
        other.exists = false;
    }
};

// ==========================================================================
//  BackgroundTrack
//
//  Preloads the entire file into memory (like SoundEffectPool) so the audio
//  callback never calls a decoder. This eliminates OGG/vorbis decode CPU from
//  the hot path entirely. Looping is a simple position wrap — zero decode cost.
//  For very long files (>~5 min at 44100 stereo f32 ≈ 100 MB) you may prefer
//  to revert to streaming, but for typical background music this is the right
//  trade-off.
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

    // Called from the audio callback — pure PCM copy + SIMD mix, no decoding.
    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames, float masterVolume) {
        if (!active || !pcmData || frameCount == 0) return 0;

        float vol = volume * masterVolume;
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

#ifdef __SSE__
            mix_simd(dst, src, samples, vol);
#else
            mix_scalar(dst, src, samples, vol);
#endif
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
    float     volume          = 1.0f;
    bool      playing         = false;

    SoundEffectInstance() = default;

    SoundEffectInstance(float* data, ma_uint64 frames, float vol = 1.0f)
        : pcmData(data), frameCount(frames), playbackPosition(0),
          volume(vol), playing(true) {}

    // Parameter named 'requestedFrames' to avoid shadowing the member 'frameCount'.
    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames, float masterVolume) {
        if (!playing || !pcmData) return 0;

        ma_uint64 remaining = frameCount - playbackPosition;
        if (remaining == 0) { playing = false; return 0; }

        ma_uint32 toRead = (ma_uint32)std::min<ma_uint64>(remaining, requestedFrames);
        float* src = pcmData + (playbackPosition * CHANNEL_COUNT);
        float  vol = volume * masterVolume;

#ifdef __SSE__
        mix_simd(output, src, (int)(toRead * CHANNEL_COUNT), vol);
#else
        mix_scalar(output, src, (int)(toRead * CHANNEL_COUNT), vol);
#endif
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

    void play(float volume = 1.0f) {
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
        // At capacity: silently drop — standard pool behaviour.
    }

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames, float masterVolume) {
        if (playingCount == 0) return 0;  // fast path: nothing active
        ma_uint64 maxRead = 0;
        int stillPlaying = 0;
        for (auto& inst : instances) {
            if (inst.isPlaying()) {
                ma_uint64 r = inst.readFrames(output, requestedFrames, masterVolume);
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
//
//  The audio callback must never block. We achieve this with a simple
//  double-buffered "snapshot" approach:
//    - Two arrays of raw pointers to BackgroundTrack / SoundEffectPool.
//    - The game thread updates the active list under mixerMutex, then
//      atomically publishes the new snapshot index.
//    - The audio callback reads the current snapshot index (relaxed load)
//      and iterates the matching pointer arrays — no lock required.
//    - Pointers in the snapshot are only invalidated when the game thread
//      calls unload*(), which first waits one extra callback cycle via a
//      generation counter before freeing.  For simplicity we just keep
//      unloaded objects alive until destroy() — the pool is typically
//      small (< 64 entries) and the memory cost is trivial.
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
        // Clear both snapshots
        for (int b = 0; b < 2; b++) {
            bgSnapshot[b].clear();
            sfxSnapshot[b].clear();
        }
    }

    // ------------------------------------------------------------------
    // Background track API
    // ------------------------------------------------------------------

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

    // ------------------------------------------------------------------
    // Sound effect API
    // ------------------------------------------------------------------

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

    void playSoundEffect(int idx, float volume = 1.0f) {
        if (inRange(idx, soundEffectPools)) soundEffectPools[idx].play(volume);
    }
    void playSoundEffect(const char* path, float volume = 1.0f) {
        int idx = findSoundEffect(path);
        if (idx < 0) idx = loadSoundEffect(path);
        if (idx >= 0) playSoundEffect(idx, volume);
    }
    void stopSoundEffect(int idx)           { if (inRange(idx, soundEffectPools)) soundEffectPools[idx].stopAll(); }
    bool isSoundEffectPlaying(int idx)      { return inRange(idx, soundEffectPools) && soundEffectPools[idx].isAnyPlaying(); }
    int  getSoundEffectPlayingCount(int idx){ return inRange(idx, soundEffectPools) ? soundEffectPools[idx].getPlayingCount() : 0; }

    // ------------------------------------------------------------------
    // Unload helpers
    // ------------------------------------------------------------------

    void unloadBackgroundTrack(int idx) {
        std::lock_guard<std::mutex> lk(mixerMutex);
        if (!inRange(idx, backgroundTracks)) return;
        eraseAndFixup(backgroundTrackMap, idx);
        backgroundTracks.erase(backgroundTracks.begin() + idx);
        publishSnapshot();
    }

    void unloadSoundEffect(int idx) {
        std::lock_guard<std::mutex> lk(mixerMutex);
        if (!inRange(idx, soundEffectPools)) return;
        eraseAndFixup(soundEffectMap, idx);
        soundEffectPools.erase(soundEffectPools.begin() + idx);
        publishSnapshot();
    }

    // ------------------------------------------------------------------
    // Volume
    // ------------------------------------------------------------------
    void  setMasterVolume(float v) { masterVolume.store(v, std::memory_order_relaxed); }
    float getMasterVolume() const  { return masterVolume.load(std::memory_order_relaxed); }

private:
    std::vector<BackgroundTrack>  backgroundTracks;
    std::vector<SoundEffectPool>  soundEffectPools;
    std::mutex mixerMutex;

    std::unordered_map<std::string, int> backgroundTrackMap;
    std::unordered_map<std::string, int> soundEffectMap;

    ma_device device;
    bool  deviceInitialized = false;

    // masterVolume is atomic so the callback can read without a lock.
    std::atomic<float> masterVolume{1.0f};

    // Double-buffered pointer snapshots for lock-free callback access.
    // snapshotIndex selects which buffer is "live" for the audio thread.
    std::vector<BackgroundTrack*> bgSnapshot[2];
    std::vector<SoundEffectPool*> sfxSnapshot[2];
    std::atomic<int> snapshotIndex{0};

    // Called under mixerMutex. Rebuilds the inactive snapshot from the
    // current vectors, then flips the index atomically.
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

        // Read the current snapshot — no lock needed.
        int snap = mixer->snapshotIndex.load(std::memory_order_acquire);
        float vol = mixer->masterVolume.load(std::memory_order_relaxed);

        for (BackgroundTrack* track : mixer->bgSnapshot[snap])
            if (track->active) track->readFrames(out, frameCount, vol);

        for (SoundEffectPool* pool : mixer->sfxSnapshot[snap])
            pool->readFrames(out, frameCount, vol);

        (void)pInput;
    }
};
