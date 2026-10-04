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
 *
 * SURROUND SOUND (AudioSampleUnified):
 * - Song device can open in stereo (2ch) or 3.1 (4ch: FL/FR/C/LFE).
 * - Stereo path is unchanged: streams are mixed directly into FL/FR.
 * - Surround path routes each stream into one of CENTER / BACKGROUND / SUB
 *   and bass-manages the front buses into the LFE.
 * - SubBusDSP on the LFE bus: dual-band transient kick detector + spectral
 *   flatness rumble detector.  Runs only in surround mode.  No allocations,
 *   no locks, no FFT.
 * - No notification callback: miniaudio fires `stopped` on every deliberate
 *   ma_device_stop() too, which used to re-enter the stop path and deadlock
 *   pause.  Device lifecycle is owned solely by the explicit methods.
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

// ---- audio constants ------------------------------------------------------

#define SAMPLE_FORMAT  ma_format_f32
#define CHANNEL_COUNT  2
#define SAMPLE_RATE    44100
#define PERIOD_SIZE    192

#define PADDING_MS      150
#define BUFFER_MS       750
// BOTTLENECK (fixed): was 400ms. The next buffer starts HALF_BUFFER_MS -
// PADDING_MS after the current one, so the window slides forward by
// (HALF_BUFFER_MS - PADDING_MS) per swap while every fill re-decodes the full
// TOTAL_BUFFER_MS window. A 400ms half-buffer meant each 1050ms fill advanced
// only 250ms -> ~4.2x realtime decode waste. Raising HALF_BUFFER_MS to 600ms
// advances 450ms per fill (~2.3x waste) at the cost of drop-resistance slack
// (TOTAL_BUFFER_MS - PADDING_MS - HALF_BUFFER_MS) dropping 500ms -> 300ms,
// which is still ample for stb_vorbis (a 1050ms buffer decodes in ~10ms).
#define HALF_BUFFER_MS  600

#define PADDING_FRAMES      ((SAMPLE_RATE * PADDING_MS)     / 1000)
#define BUFFER_FRAMES       ((SAMPLE_RATE * BUFFER_MS)      / 1000)
#define HALF_BUFFER_FRAMES  ((SAMPLE_RATE * HALF_BUFFER_MS) / 1000)
#define TOTAL_BUFFER_FRAMES (PADDING_FRAMES + BUFFER_FRAMES + PADDING_FRAMES)

#define MAX_CALLBACK_FRAMES 4096
// Pitched playback reads `frameCount * rate` source frames per callback; allow
// up to 4x rate in the staging buffer instead of the old 1x cap (which
// overflowed pitchInputMix for rate > 1).
#define MAX_PITCH_FRAMES   (MAX_CALLBACK_FRAMES * 4)

// ---- surround sound system (AudioSampleUnified) ---------------------------
//
// The song mixer can run in two output layouts, toggled at runtime:
//
//   Stereo   (2 channels)  — FL / FR.  Every decoder stream is mixed straight
//                          into the front pair, exactly like the classic
//                          engine behavior.  Music and sound stay stereo.
//
//   Surround (3.1, 4 channels) — FL / FR / C / LFE.  Each decoder stream
//                          (inst, voices, ...) is routed into one of the
//                          channel buses identified by MaThingAudioChannel:
//
//     CENTER     — the center speaker.  Voices play here as a mono feed,
//                  pulling them out of the stereo image.
//     BACKGROUND — the front left/right pair.  The instrumental stays here,
//                  full-range and wide.
//     SUB        — the subwoofer (LFE).  Streams routed here play only
//                  their low-passed content; streams on the other buses are
//                  additionally bass-managed into the LFE so the ".1" always
//                  gets the low end of the song.
//
// The decoders themselves stay stereo (CHANNEL_COUNT); only the playback
// device widens to 4 channels.  The AudioMixerManager (background music and
// sound effects) always remains stereo.
#define SURROUND_CHANNEL_COUNT 4

// One-pole low-pass coefficient for the LFE feed: fc ≈ 120 Hz @ 44100 Hz.
//   coef = 1 - exp(-2π * fc / sampleRate)
#define SURROUND_LPF_COEF   0.016951f
// Bass-managed streams (CENTER/BACKGROUND) feed the LFE slightly quieter than
// streams routed to SUB itself, which get their full (low-passed) content.
#define SURROUND_LFE_BASS_GAIN 0.75f
#define SURROUND_LFE_FULL_GAIN 1.0f

// ---- SubBusDSP constants --------------------------------------------------
// The LFE DSP runs on the LFE channel only, only in surround mode.
//
// Band split: two one-pole lowpasses.  BODY captures the deep sub (20-60Hz)
// that gives a kick its weight.  PUNCH captures the upper bass (60-120Hz)
// that gives it its snap.  Both are cheap and stable.
//
// Kick detection: the leading edge of a kick spikes the PUNCH band faster
// than it spikes the BODY band.  We track two envelopes per band (fast and
// slow) and gate the boost on the fast/slow ratio in the punch band.  This
// distinguishes a real transient from a sustained bass note that happens to
// sit in the same range.
//
// Rumble detection: a slow-moving low-band energy tracker over a ~100ms
// window.  When the LFE is dominated by sustained low-frequency energy with
// no transients, we duck it smoothly to keep the sub from muddying the mix.
// A kick on top of rumble still punches through because the kick boost is
// applied before the rumble duck is computed.
#define SUB_LPF_BODY_HZ   55.0f    // body band cutoff
#define SUB_LPF_PUNCH_HZ  120.0f   // punch band cutoff

#define SUB_LPF_BODY_COEF  ((float)(1.0 - exp(-2.0 * 3.14159265358979323846 * SUB_LPF_BODY_HZ  / SAMPLE_RATE)))
#define SUB_LPF_PUNCH_COEF ((float)(1.0 - exp(-2.0 * 3.14159265358979323846 * SUB_LPF_PUNCH_HZ / SAMPLE_RATE)))

// Envelope times.  Attack is per-sample one-pole coefficient toward "instant";
// release is the slower coefficient.  2ms attack, 40ms release for kicks.
#define SUB_ENV_ATTACK_COEF  0.012f   // ~2ms to 63%
#define SUB_ENV_RELEASE_COEF 0.0006f  // ~40ms to 63%

// Kick gate thresholds.  TRANSIENT_RATIO is how much faster the fast envelope
// has to be rising than the slow one to count as a transient rather than a
// swell.  KICK_FLOOR is the absolute energy floor so silence doesn't trigger.
#define SUB_KICK_TRANSIENT_RATIO 2.2f
#define SUB_KICK_FLOOR           0.03f
#define SUB_KICK_HYSTERESIS      0.5f
#define SUB_KICK_BOOST_GAIN      0.75f   // peak boost = 1 + 0.75 = 1.75x
#define SUB_KICK_BOOST_ATTACK    0.05f   // boost envelope attack (~0.4ms)
#define SUB_KICK_BOOST_RELEASE   0.0009f // boost envelope release (~25ms)

// Rumble gate: how much of the total low-band energy must be in the body
// band, sustained, before we duck.  Also the duck depth and its smoothing.
#define SUB_RUMBLE_BODY_RATIO    0.55f
#define SUB_RUMBLE_FLOOR         0.02f
#define SUB_RUMBLE_DUCK          0.55f   // duck LFE to 55% when rumbling
#define SUB_RUMBLE_SMOOTH        0.0009f // ~25ms one-pole toward target gain

// Song channel bus identifiers.  Values must stay in sync with the Haxe
// `AudioChannelIdentifier` enum abstract in rhythm.AudioSampleUnified.
enum MaThingAudioChannel {
    MA_CH_CENTER     = 0,   // center speaker — vocals bus
    MA_CH_BACKGROUND = 1,   // front L/R pair — instrumental bus
    MA_CH_SUB        = 2    // subwoofer (LFE) — bass bus
};

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
//  SubBusDSP — dual-band transient kick detector + rumble detector
//
//  Runs entirely on the audio thread, on the LFE channel only, in surround
//  mode only.  No allocations, no locks, no FFT.
//
//  Signal flow per sample:
//
//    1. Split into BODY (<55Hz) and PUNCH (<120Hz) bands with one-pole LPs.
//    2. Update fast/slow envelopes on the PUNCH band.  A kick shows up as
//       fast > slow * ratio while the absolute energy exceeds the floor.
//    3. If a kick is detected, arm the boost envelope.  The boost is applied
//       to the whole LFE (punch more than body) via a short attack/decay
//       envelope so the leading edge is emphasized without smearing the tail.
//    4. Update body and total LFE envelopes over ~100ms.
//    5. If the body band dominates total LFE energy AND there is no active
//       kick AND the signal is above the rumble floor, duck the LFE smoothly
//       toward SUB_RUMBLE_DUCK.  A one-pole on the duck gain prevents the
//       duck from clicking in and out.
//
//  Everything is O(1) per sample and uses a handful of floats of state.
// ==========================================================================
class SubBusDSP {
public:
    SubBusDSP() { reset(); }

    void reset() {
        body_lpf     = 0.0f;
        punch_lpf    = 0.0f;
        total_env    = 0.0f;
        body_env     = 0.0f;
        punch_fast   = 0.0f;
        punch_slow   = 0.0f;
        kick_armed   = false;
        boost_env    = 0.0f;
        duck_gain    = 1.0f;
    }

    // Process the LFE channel in place inside an interleaved 3.1 buffer.
    // LFE is at index 3 of each frame.
    void process(float* interleaved, ma_uint32 frames) {
        for (ma_uint32 i = 0; i < frames; i++) {
            float* lfe = &interleaved[i * SURROUND_CHANNEL_COUNT + 3];
            float x = *lfe;

            // --- 1. band split ------------------------------------------
            body_lpf  += SUB_LPF_BODY_COEF  * (x - body_lpf);
            punch_lpf += SUB_LPF_PUNCH_COEF * (x - punch_lpf);

            // --- 2. punch-band envelopes --------------------------------
            float abs_punch = fabsf(punch_lpf);
            if (abs_punch > punch_fast) punch_fast += SUB_ENV_ATTACK_COEF  * (abs_punch - punch_fast);
            else                        punch_fast += SUB_ENV_RELEASE_COEF * (abs_punch - punch_fast);
            if (abs_punch > punch_slow) punch_slow += SUB_ENV_ATTACK_COEF  * (abs_punch - punch_slow);
            else                        punch_slow += SUB_ENV_RELEASE_COEF * (abs_punch - punch_slow);

            // --- 3. kick gate -------------------------------------------
            bool kick_now = false;
            if (punch_fast > SUB_KICK_FLOOR &&
                punch_slow > 0.0001f &&
                punch_fast > punch_slow * SUB_KICK_TRANSIENT_RATIO) {
                kick_now = true;
            }
            if (kick_now) kick_armed = true;
            else if (punch_fast < SUB_KICK_FLOOR * SUB_KICK_HYSTERESIS) kick_armed = false;

            // --- 4. boost envelope --------------------------------------
            float boost_target = kick_armed ? 1.0f : 0.0f;
            if (boost_target > boost_env) boost_env += SUB_KICK_BOOST_ATTACK  * (boost_target - boost_env);
            else                          boost_env += SUB_KICK_BOOST_RELEASE * (boost_target - boost_env);

            float boosted = x * (1.0f + SUB_KICK_BOOST_GAIN * boost_env);

            // --- 5. rumble detection ------------------------------------
            float abs_total = fabsf(boosted);
            float abs_body  = fabsf(body_lpf);
            total_env += 0.0006f * (abs_total - total_env);
            body_env  += 0.0006f * (abs_body  - body_env);

            bool rumbling = false;
            if (!kick_armed &&
                total_env > SUB_RUMBLE_FLOOR &&
                body_env > total_env * SUB_RUMBLE_BODY_RATIO) {
                rumbling = true;
            }

            float duck_target = rumbling ? SUB_RUMBLE_DUCK : 1.0f;
            duck_gain += SUB_RUMBLE_SMOOTH * (duck_target - duck_gain);

            // --- 6. write back ------------------------------------------
            *lfe = boosted * duck_gain;
        }
    }

private:
    // Band split state
    float body_lpf;
    float punch_lpf;

    // Envelopes
    float total_env;
    float body_env;
    float punch_fast;
    float punch_slow;

    // Kick state
    bool  kick_armed;
    float boost_env;

    // Rumble duck state
    float duck_gain;
};

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

        // BOTTLENECK (fixed): previously zeroed the whole ~370KB buffer before
        // decoding, which is wasted work when the read fills it. Decode first,
        // then zero only the tail the decode didn't touch.
        if (maxFrames > 0 && decodeStart < decoderLength) {
            if (ma_decoder_seek_to_pcm_frame(&dec, decodeStart) == MA_SUCCESS)
                ma_decoder_read_pcm_frames(&dec, buffer, maxFrames, framesRead);
        }
        if (*framesRead < maxFrames)
            memset(buffer + (*framesRead) * CHANNEL_COUNT, 0,
                   (maxFrames - *framesRead) * CHANNEL_COUNT * sizeof(float));

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

        // BOTTLENECK (fixed): tail-only memset, see fillBufferTemp.
        if (maxFrames > 0 && decodeStart < decoderLength) {
            if (ma_decoder_seek_to_pcm_frame(&workerDecoder, decodeStart) == MA_SUCCESS)
                ma_decoder_read_pcm_frames(&workerDecoder, buffer, maxFrames, framesRead);
        }
        if (*framesRead < maxFrames)
            memset(buffer + (*framesRead) * CHANNEL_COUNT, 0,
                   (maxFrames - *framesRead) * CHANNEL_COUNT * sizeof(float));
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

                // BOTTLENECK (fixed): was a 100-iteration yield spin followed by a
                // 1ms sleep, polled continuously. The worker is not a hot path, so
                // just sleep; it stays responsive within ~1ms (well inside the
                // hundreds of ms of buffered slack) without burning CPU.
                auto start = std::chrono::steady_clock::now();
                while (pause.load(std::memory_order_acquire) &&
                       !stopRequested.load(std::memory_order_acquire) &&
                       running.load(std::memory_order_acquire)) {
                    if (std::chrono::steady_clock::now() - start > std::chrono::milliseconds(10)) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                }
                workerIdle.store(false, std::memory_order_release);
                continue;
            }

            if (streams.empty()) {
                workerIdle.store(true, std::memory_order_release);

                auto start = std::chrono::steady_clock::now();
                while (streams.empty() &&
                       !stopRequested.load(std::memory_order_acquire) &&
                       running.load(std::memory_order_acquire)) {
                    if (std::chrono::steady_clock::now() - start > std::chrono::milliseconds(10)) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
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
                while (!workPending.load(std::memory_order_acquire) &&
                       !stopRequested.load(std::memory_order_acquire) &&
                       running.load(std::memory_order_acquire)) {
                    if (std::chrono::steady_clock::now() - start > std::chrono::milliseconds(5)) break;
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
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
//  StretchPipeline — moves SignalsmithStretch's FFT work off the realtime
//  audio thread.
//
//  Lock-free SPSC ring buffers: the audio thread pushes mixed input chunks in,
//  a dedicated worker thread runs stretch->process(), and the audio thread
//  pulls the stretched output back out. Only the worker touches `stretch`, so
//  it never blocks the callback. If the worker hasn't produced a chunk yet
//  (cold start / rate change) the callback simply gets silence for that chunk.
// ==========================================================================

class StretchPipeline {
public:
    static constexpr size_t RING_FRAMES = 1 << 14;      // 16384 stereo frames
    static constexpr size_t RING_MASK  = RING_FRAMES - 1;
    static constexpr size_t MAX_CHUNKS = 16;

    struct ChunkDesc {
        ma_uint32 inFrames;
        ma_uint32 outFrames;
    };

    StretchPipeline() {
        configureChannels(CHANNEL_COUNT);
    }

    ~StretchPipeline() { stop(); }

    // The stretch engine processes the song in the device's output layout so
    // pitched playback can carry the 3.1 surround buses natively.  Only call
    // while the worker is stopped (device stopped / pipeline reset), i.e. on
    // load or on a stereo <-> surround output toggle.
    void configureChannels(int ch) {
        if (channels == ch && !inSamples.empty()) return;
        stop();
        channels = ch;
        inSamples.assign(RING_FRAMES * channels, 0.0f);
        outSamples.assign(RING_FRAMES * channels, 0.0f);
        workIn.assign(MAX_PITCH_FRAMES * channels, 0.0f);
        workOut.assign(MAX_CALLBACK_FRAMES * channels, 0.0f);
        stretch.configure(channels, int(SAMPLE_RATE * 0.1), int(SAMPLE_RATE * 0.05));
    }

    // ---- audio thread -----------------------------------------------
    bool push(const float* input, ma_uint32 inFrames, ma_uint32 outFrames) {
        ensureStarted();

        size_t head = inHead.load(std::memory_order_acquire);
        size_t tail = inTail.load(std::memory_order_acquire);
        if (RING_FRAMES - (head - tail) < inFrames) return false;   // input ring full

        size_t cHead = chunkHead.load(std::memory_order_relaxed);
        size_t cTail = chunkTail.load(std::memory_order_acquire);
        if (MAX_CHUNKS - (cHead - cTail) < 1) return false;         // desc ring full

        writeSamples(inSamples.data(), head, input, inFrames);
        chunks[cHead & (MAX_CHUNKS - 1)] = { inFrames, outFrames };
        inHead.store(head + inFrames, std::memory_order_release);
        chunkHead.store(cHead + 1, std::memory_order_release);
        return true;
    }

    bool pull(float* output, ma_uint32 outFrames) {
        size_t head = outHead.load(std::memory_order_acquire);
        size_t tail = outTail.load(std::memory_order_acquire);
        if (head - tail < outFrames) return false;                  // not produced yet
        readSamples(outSamples.data(), tail, output, outFrames);
        outTail.store(tail + outFrames, std::memory_order_release);
        return true;
    }

    void stop() {
        if (!running.load(std::memory_order_acquire)) return;
        stopRequested.store(true, std::memory_order_release);
        if (thread.joinable()) thread.join();
        running.store(false, std::memory_order_release);
    }

    // Discard all in-flight stretched chunks and re-seed the stretch engine.
    // Only safe to call while the audio device is stopped (e.g. inside seek).
    void reset() {
        stop();
        inHead.store(0, std::memory_order_release); inTail.store(0, std::memory_order_release);
        outHead.store(0, std::memory_order_release); outTail.store(0, std::memory_order_release);
        chunkHead.store(0, std::memory_order_release); chunkTail.store(0, std::memory_order_release);
        stretch.reset();
    }

private:
    signalsmith::stretch::SignalsmithStretch stretch;
    int channels = CHANNEL_COUNT;   // output layout this pipeline stretches
    std::vector<float> inSamples, outSamples, workIn, workOut;
    std::array<ChunkDesc, MAX_CHUNKS> chunks;

    std::atomic<size_t> inHead{0}, inTail{0};
    std::atomic<size_t> outHead{0}, outTail{0};
    std::atomic<size_t> chunkHead{0}, chunkTail{0};

    std::thread thread;
    std::atomic<bool> running{false};
    std::atomic<bool> stopRequested{false};

    void ensureStarted() {
        bool expected = false;
        if (running.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
            stopRequested.store(false, std::memory_order_release);
            try {
                thread = std::thread([this]() { workerLoop(); });
            } catch (...) {
                running.store(false, std::memory_order_release);
            }
        }
    }

    void writeSamples(float* dst, size_t at, const float* src, ma_uint32 frames) {
        size_t offset = (at & RING_MASK) * channels;
        size_t first  = std::min<size_t>(frames, RING_FRAMES - (at & RING_MASK));
        size_t total  = (size_t)frames * channels;
        memcpy(dst + offset, src, first * channels * sizeof(float));
        if (frames > first)
            memcpy(dst, src + first * channels, (total - first * channels) * sizeof(float));
    }

    void readSamples(const float* src, size_t at, float* dst, ma_uint32 frames) {
        size_t offset = (at & RING_MASK) * channels;
        size_t first  = std::min<size_t>(frames, RING_FRAMES - (at & RING_MASK));
        memcpy(dst, src + offset, first * channels * sizeof(float));
        if (frames > first)
            memcpy(dst + first * channels, src, (frames - first) * channels * sizeof(float));
    }

    void workerLoop() {
        while (running.load(std::memory_order_acquire) && !stopRequested.load(std::memory_order_acquire)) {
            size_t cHead = chunkHead.load(std::memory_order_acquire);
            size_t cTail = chunkTail.load(std::memory_order_acquire);
            if (cTail >= cHead) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            const ChunkDesc& c = chunks[cTail & (MAX_CHUNKS - 1)];

            size_t oHead = outHead.load(std::memory_order_acquire);
            size_t oTail = outTail.load(std::memory_order_acquire);
            if ((oHead - oTail) + c.outFrames > RING_FRAMES) {      // output ring full
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }

            size_t iTail = inTail.load(std::memory_order_acquire);
            readSamples(inSamples.data(), iTail, workIn.data(), c.inFrames);
            inTail.store(iTail + c.inFrames, std::memory_order_release);

            stretch.process(workIn.data(), c.inFrames, workOut.data(), c.outFrames);
            writeSamples(outSamples.data(), oHead, workOut.data(), c.outFrames);
            outHead.store(oHead + c.outFrames, std::memory_order_release);
            chunkTail.store(cTail + 1, std::memory_order_release);
        }
    }
};

// ==========================================================================
//  AudioSystem (LOCK-FREE)
//
//  Stereo path is unchanged from the original engine.  The surround path
//  routes streams into buses and runs SubBusDSP on the LFE.  The SubBusDSP
//  is only ever touched when surroundEnabled and playbackChannels is 4,
//  which mirrors the original code's discipline of never running surround-
//  only code in the stereo path.
// ==========================================================================

class AudioSystem {
public:
    std::vector<DecoderStream> streams;
    std::vector<float>         decoderVolumes;
    std::vector<std::string>   filePaths;

    ma_device device;
    StretchPipeline* stretchPipe = nullptr;

    // LFE-bus DSP (dual-band kick detector + rumble duck).  Audio thread only.
    // Never touched in the stereo path.
    SubBusDSP subDSP;

    int   longestDecoderIndex = 0;
    std::atomic<float> playbackRate{1.0f};
    std::atomic<int> mixerState{3};
    std::atomic<bool> exists{false};
    std::atomic<bool> stretchEnabled{true};

    // ---- surround sound system (AudioSampleUnified) ----
    std::atomic<bool> surroundEnabled{false};
    std::atomic<int>  playbackChannels{CHANNEL_COUNT};
    std::deque<std::atomic<int>> streamChannels;
    std::vector<float> streamLpfState;

    // Staging mix for pitched playback.
    float pitchInputMix[MAX_PITCH_FRAMES * SURROUND_CHANNEL_COUNT] = {};

    // Per-stream stereo staging used by the surround routing pass.
    float streamStage[MAX_CALLBACK_FRAMES * CHANNEL_COUNT] = {};

    // Prediction state — PI-controlled software PLL.
    // Written only from the audio callback, read from anywhere (UI thread, etc.).
    // The PLL free-runs on steady_clock between callbacks and gently converges
    // toward the true DAC rate, eliminating the per-callback snap that used to
    // make the position jagged at small period sizes (e.g. 192 frames).
    mutable std::atomic<long long> predictBaseTimeNs{0};   // wall-clock anchor (ns since epoch)
    mutable std::atomic<double>    predictBaseFrames{0.0}; // predicted frame at that wall-clock
    mutable std::atomic<double>    predictRate{1.0};       // effective frames/sec per real-sec (rate * drift)
    mutable std::atomic<bool>      predictInit{false};
    mutable std::atomic<float>     predictPrevRate{1.0f}; // rate from last callback (detects user rate changes)

    AudioSystem()  {
        memset(&device, 0, sizeof(ma_device));
        init_simd_dispatch();
        stretchPipe = new StretchPipeline();
    }
    ~AudioSystem() {
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

        streamChannels.clear();
        streamLpfState.assign(streams.size(), 0.0f);
        for (size_t i = 0; i < streams.size(); i++) {
            streamChannels.emplace_back((i == 0) ? MA_CH_BACKGROUND : MA_CH_CENTER);
        }

        int wantedChannels = surroundEnabled.load(std::memory_order_acquire)
                           ? SURROUND_CHANNEL_COUNT : CHANNEL_COUNT;
        playbackChannels.store(wantedChannels, std::memory_order_release);

        ma_device_config deviceConfig = ma_device_config_init(ma_device_type_playback);
        deviceConfig.playback.format   = SAMPLE_FORMAT;
        deviceConfig.playback.channels = wantedChannels;
        deviceConfig.sampleRate        = SAMPLE_RATE;
        deviceConfig.periodSizeInFrames= PERIOD_SIZE;
        deviceConfig.dataCallback      = data_callback;
        deviceConfig.pUserData         = this;

        if (ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS && wantedChannels != CHANNEL_COUNT) {
            playbackChannels.store(CHANNEL_COUNT, std::memory_order_release);
            surroundEnabled.store(false, std::memory_order_release);
            deviceConfig.playback.channels = CHANNEL_COUNT;
            if (ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS) {
                streams.clear(); decoderVolumes.clear(); filePaths.clear();
                streamChannels.clear(); streamLpfState.clear();
                printf("Failed to open playback device.\n");
                return;
            }
            printf("Surround Sound 3.1 unavailable on this device; falling back to stereo.\n");
        }

        if (!stretchPipe)
            stretchPipe = new StretchPipeline();
        stretchPipe->reset();
        stretchPipe->configureChannels(playbackChannels.load(std::memory_order_acquire));

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
        streamChannels.clear();
        streamLpfState.clear();

        if (stretchPipe) {
            delete stretchPipe;
            stretchPipe = nullptr;
        }

        longestDecoderIndex = 0;
        playbackRate.store(1.0f, std::memory_order_release);
        mixerState.store(3, std::memory_order_release);

        predictInit.store(false, std::memory_order_relaxed);
        predictBaseTimeNs.store(0, std::memory_order_relaxed);
        predictBaseFrames.store(0.0, std::memory_order_relaxed);
        predictRate.store(1.0, std::memory_order_relaxed);
        predictPrevRate.store(1.0f, std::memory_order_relaxed);

        subDSP.reset();

        memset(&device, 0, sizeof(ma_device));
    }

    void start() {
        if (!exists.load(std::memory_order_acquire)) return;
        if (mixerState.load(std::memory_order_acquire) == 3) seekToPCMFrame(0);
        if (asyncLoader) asyncLoader->resumeLoading();

        mixerState.store(1, std::memory_order_release);

        ma_uint64 startFrame = 0;
        if (!streams.empty()) {
            startFrame = streams[longestDecoderIndex].filePosition.load(std::memory_order_relaxed);
        }
        // Let the next data_callback plant the PLL anchor cleanly so its
        // baseTime exactly matches the wall-clock at which audio starts
        // flowing. Planting here would race the first callback.
        predictInit.store(false, std::memory_order_relaxed);

        ma_device_start(&device);
    }

    void stop() {
        if (!exists.load(std::memory_order_acquire)) return;

        mixerState.store(2, std::memory_order_release);
        if (asyncLoader) asyncLoader->pauseLoading();
        ma_device_stop(&device);
    }

    bool stopped() const { return mixerState.load(std::memory_order_acquire) == 3; }

    void seekToPCMFrame(int64_t pos) {
        if (!exists.load(std::memory_order_acquire)) return;

        bool deviceRunning = ma_device_is_started(&device);

        if (deviceRunning) {
            mixerState.store(2, std::memory_order_release);
        }

        if (asyncLoader) asyncLoader->pauseLoading();
        if (asyncLoader) asyncLoader->waitUntilIdle();

        if (deviceRunning) ma_device_stop(&device);

        if (stretchPipe) stretchPipe->reset();

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

            if (s.workerDecoderInitialized)
                ma_decoder_seek_to_pcm_frame(&s.workerDecoder, target);
        }

        mixerState.store((pos < (int64_t)streams[longestDecoderIndex].decoderLength) ? 2 : 3, std::memory_order_release);

        // PLL will be re-planted by the next callback after the device
        // restarts, so baseTime lines up with actual audio flow.
        predictInit.store(false, std::memory_order_relaxed);

        if (deviceRunning && mixerState.load(std::memory_order_acquire) == 2) {
            if (asyncLoader) asyncLoader->resumeLoading();
            mixerState.store(1, std::memory_order_release);
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

    // ---- surround sound system (AudioSampleUnified) ----

    bool isSurroundEnabled() const { return surroundEnabled.load(std::memory_order_acquire); }

    void setSurroundEnabled(bool enable) {
        bool prev = surroundEnabled.exchange(enable, std::memory_order_acq_rel);
        if (prev == enable) return;

        int wanted = enable ? SURROUND_CHANNEL_COUNT : CHANNEL_COUNT;

        if (!exists.load(std::memory_order_acquire)) {
            playbackChannels.store(wanted, std::memory_order_release);
            if (stretchPipe) { stretchPipe->reset(); stretchPipe->configureChannels(wanted); }
            return;
        }

        int  prevState  = mixerState.load(std::memory_order_acquire);
        bool wasPlaying = (prevState == 1);

        ma_device_stop(&device);
        if (stretchPipe) stretchPipe->reset();
        ma_device_uninit(&device);
        memset(&device, 0, sizeof(ma_device));

        ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
        cfg.playback.format   = SAMPLE_FORMAT;
        cfg.playback.channels = wanted;
        cfg.sampleRate        = SAMPLE_RATE;
        cfg.periodSizeInFrames= PERIOD_SIZE;
        cfg.dataCallback      = data_callback;
        cfg.pUserData         = this;

        if (ma_device_init(nullptr, &cfg, &device) != MA_SUCCESS && wanted != CHANNEL_COUNT) {
            playbackChannels.store(CHANNEL_COUNT, std::memory_order_release);
            surroundEnabled.store(false, std::memory_order_release);
            cfg.playback.channels = CHANNEL_COUNT;
            if (ma_device_init(nullptr, &cfg, &device) != MA_SUCCESS) {
                mixerState.store(3, std::memory_order_release);
                return;
            }
            printf("Surround Sound 3.1 unavailable on this device; falling back to stereo.\n");
        } else {
            playbackChannels.store(wanted, std::memory_order_release);
        }

        if (stretchPipe) { stretchPipe->reset(); stretchPipe->configureChannels(playbackChannels.load(std::memory_order_acquire)); }

        if (wasPlaying) {
            mixerState.store(1, std::memory_order_release);
            ma_device_start(&device);
        } else {
            mixerState.store(prevState, std::memory_order_release);
        }
    }

    void setStreamChannel(int index, int channel) {
        if (index >= 0 && index < (int)streamChannels.size() &&
            channel >= MA_CH_CENTER && channel <= MA_CH_SUB)
            streamChannels[index].store(channel, std::memory_order_release);
    }

    int getStreamChannel(int index) const {
        if (index >= 0 && index < (int)streamChannels.size())
            return streamChannels[index].load(std::memory_order_acquire);
        return (index == 0) ? MA_CH_BACKGROUND : MA_CH_CENTER;
    }

    double getPlaybackPosition() const {
        if (!exists.load(std::memory_order_acquire)) return 0.0;
        if (streams.empty()) return 0.0;

        const DecoderStream& s = streams[longestDecoderIndex];
        if (!s.active.load(std::memory_order_acquire))
            return (double)s.decoderLength / (SAMPLE_RATE * 0.001);

        // If the PLL hasn't been planted yet (before first callback after
        // start/seek), fall back to raw filePosition so callers see a
        // sensible value instead of 0.
        if (!predictInit.load(std::memory_order_relaxed)) {
            return (double)s.filePosition.load(std::memory_order_relaxed)
                   / (SAMPLE_RATE * 0.001);
        }

        // Torn reads on 32-bit are sub-frame glitches that vanish at 60 Hz
        // poll rates; no seqlock needed. On 64-bit, atomic<double> is lock-free.
        double baseT = predictBaseTimeNs.load(std::memory_order_relaxed);
        double baseF = predictBaseFrames.load(std::memory_order_relaxed);
        double baseR = predictRate.load(std::memory_order_relaxed);

        long long nowNs = std::chrono::steady_clock::now().time_since_epoch().count();
        double dt = (nowNs - baseT) * 1e-9;
        double predicted = baseF + dt * SAMPLE_RATE * baseR;

        if (predicted < 0.0) predicted = 0.0;
        if (predicted > (double)s.decoderLength)
            predicted = (double)s.decoderLength;

        // No quantization — the PLL output is already smooth. If a caller
        // wants integer frames, quantize at the call site, not here.
        return predicted / (SAMPLE_RATE * 0.001);
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
        if (index < streamLpfState.size()) streamLpfState[index] = 0.0f;
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

    void routeStreamToOutput(size_t index, const float* stage, float* out,
                             ma_uint32 outFrames, int outCh) {
        const int route = streamChannels[index].load(std::memory_order_acquire);
        float lpf = streamLpfState[index];

        if (outCh == SURROUND_CHANNEL_COUNT) {
            switch (route) {
                case MA_CH_CENTER:
                    for (ma_uint32 f = 0; f < outFrames; f++) {
                        float sl = stage[f * 2], sr = stage[f * 2 + 1];
                        float mono = (sl + sr) * 0.5f;
                        lpf += SURROUND_LPF_COEF * (mono - lpf);
                        float* d = out + f * outCh;
                        d[2] += mono;
                        d[3] += lpf * SURROUND_LFE_BASS_GAIN;
                    }
                    break;
                case MA_CH_SUB:
                    for (ma_uint32 f = 0; f < outFrames; f++) {
                        float sl = stage[f * 2], sr = stage[f * 2 + 1];
                        float mono = (sl + sr) * 0.5f;
                        lpf += SURROUND_LPF_COEF * (mono - lpf);
                        out[f * outCh + 3] += lpf * SURROUND_LFE_FULL_GAIN;
                    }
                    break;
                case MA_CH_BACKGROUND:
                default:
                    for (ma_uint32 f = 0; f < outFrames; f++) {
                        float sl = stage[f * 2], sr = stage[f * 2 + 1];
                        float mono = (sl + sr) * 0.5f;
                        lpf += SURROUND_LPF_COEF * (mono - lpf);
                        float* d = out + f * outCh;
                        d[0] += sl;
                        d[1] += sr;
                        d[3] += lpf * SURROUND_LFE_BASS_GAIN;
                    }
                    break;
            }
        }

        streamLpfState[index] = lpf;
    }

    ma_uint32 readFromBuffer(size_t index, float* output, ma_uint32 requestedFrames) {
        DecoderStream& s = streams[index];
        if (!s.active.load(std::memory_order_acquire)) return 0;

        static thread_local double cachedMasterVolume = -1.0;
        static thread_local std::vector<float> precomputedVolumes;

        if (precomputedVolumes.size() != decoderVolumes.size()) {
            precomputedVolumes.resize(decoderVolumes.size(), 0.0f);
            cachedMasterVolume = -1.0;
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

        bool nextBufferReady = s.asyncState.nextBufferReady.load(std::memory_order_acquire);
        bool isActive = s.active.load(std::memory_order_acquire);

        if (nextBufferReady && s.shouldSwapBuffers() || s.isBufferLow()) s.trySwapBuffers();

        ma_uint32 framesRead = 0;

        while (framesRead < requestedFrames && isActive) {
            ma_uint64 available = (s.localReadPos < s.validFrames)
                                ? s.validFrames - s.localReadPos : 0;

            if (available == 0) {
                if (s.bufferStartPos + s.localReadPos < s.decoderLength) {
                    if (s.asyncState.nextBufferReady.load(std::memory_order_acquire)) {
                        s.trySwapBuffers();
                        continue;
                    }
                    s.asyncState.needsLoad.store(true, std::memory_order_release);
                    s.requestBufferLoad();
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

            if (vol != 0.0f) g_mix_func(dst, src, samples, vol);

            s.localReadPos  += toRead;
            framesRead      += toRead;
        }

        s.filePosition.store(s.bufferStartPos + s.localReadPos, std::memory_order_relaxed);

        if (isActive && !s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
            ma_uint64 available = (s.localReadPos < s.validFrames)
                                ? s.validFrames - s.localReadPos : 0;
            if (available < (HALF_BUFFER_FRAMES * 2) || framesRead < requestedFrames) {
                s.requestBufferLoad();
                s.asyncState.needsLoad.store(true, std::memory_order_release);
            }
        }
        return framesRead;
    }

    static void data_callback(ma_device* pDevice, void* pOutput,
                              const void* pInput, ma_uint32 frameCount) {
        AudioSystem* sys = static_cast<AudioSystem*>(pDevice->pUserData);
        if (!sys || !sys->exists.load(std::memory_order_acquire)) return;

        float* out = (float*)pOutput;
        int outCh = sys->playbackChannels.load(std::memory_order_relaxed);
        memset(out, 0, sizeof(float) * frameCount * outCh);

        // ---- PI-controlled prediction update (software PLL) ---------------
        // Free-runs on steady_clock between callbacks; each callback gently
        // converges (offset, rate) toward the true DAC progression. Absorbs
        // per-callback wall-clock jitter instead of forwarding it as a snap.
        {
            double fp = sys->streams.empty()
                ? 0.0
                : (double)sys->streams[sys->longestDecoderIndex]
                      .filePosition.load(std::memory_order_relaxed);
            long long nowNs = std::chrono::steady_clock::now()
                                  .time_since_epoch().count();
            double rate = sys->playbackRate.load(std::memory_order_relaxed);

            if (!sys->predictInit.load(std::memory_order_relaxed)) {
                // First callback after start/seek: plant the anchor cleanly.
                sys->predictBaseTimeNs.store(nowNs, std::memory_order_relaxed);
                sys->predictBaseFrames.store(fp, std::memory_order_relaxed);
                sys->predictRate.store((double)rate, std::memory_order_relaxed);
                sys->predictPrevRate.store((float)rate, std::memory_order_relaxed);
                sys->predictInit.store(true, std::memory_order_relaxed);
            } else {
                double prevRate = sys->predictPrevRate.load(std::memory_order_relaxed);
                bool rateChanged = std::fabs(rate - prevRate) > 1e-6;

                if (rateChanged) {
                    // User changed playbackRate since last callback. Re-plant
                    // the anchor at the current filePosition with the new rate
                    // so prediction responds instantly instead of lagging ~1s
                    // while beta slowly converges. Drift re-converges over a
                    // few seconds (fine — DAC drift is ~50ppm, invisible).
                    sys->predictBaseTimeNs.store(nowNs, std::memory_order_relaxed);
                    sys->predictBaseFrames.store(fp, std::memory_order_relaxed);
                    sys->predictRate.store((double)rate, std::memory_order_relaxed);
                    sys->predictPrevRate.store((float)rate, std::memory_order_relaxed);
                } else {
                    double baseT = sys->predictBaseTimeNs.load(std::memory_order_relaxed);
                    double baseF = sys->predictBaseFrames.load(std::memory_order_relaxed);
                    double baseR = sys->predictRate.load(std::memory_order_relaxed);

                    double dt = (nowNs - baseT) * 1e-9;
                    if (dt < 1e-6) dt = 1e-6;            // guard against QPC weirdness
                    double predicted = baseF + dt * SAMPLE_RATE * baseR;
                    double error     = fp - predicted;   // frames (positive = we're behind)

                    // PI gains, tuned for ~229 Hz callback rate at period=192.
                    // alpha = fast offset correction (settle in ~1/(alpha*CbPerSec) sec).
                    // beta  = slow rate correction  (tracks DAC drift over seconds).
                    const double alpha = 0.15;
                    const double beta  = 0.005;

                    double newBaseF = predicted + alpha * error;

                    // Implied effective rate, then re-base against user rate to
                    // extract a drift factor (clamped to ±1000 ppm).
                    double impliedRate = baseR + error / (dt * SAMPLE_RATE);
                    double drift = impliedRate / std::max<double>(rate, 1e-6);
                    if (drift < 0.999) drift = 0.999;
                    else if (drift > 1.001) drift = 1.001;
                    double newRate = rate * drift;

                    // Blend toward the new drift estimate (the "I" term).
                    newRate = baseR * (1.0 - beta) + newRate * beta;

                    sys->predictBaseTimeNs.store(nowNs,   std::memory_order_relaxed);
                    sys->predictBaseFrames.store(newBaseF, std::memory_order_relaxed);
                    sys->predictRate.store(newRate,        std::memory_order_relaxed);
                }
            }
        }

        bool anyRefill = false;

        bool anyActive = false;
        float rate = sys->playbackRate.load(std::memory_order_acquire);

        if (rate == 1.0f) {
            for (size_t i = 0; i < sys->streams.size(); i++) {
                if (!sys->streams[i].active.load(std::memory_order_acquire)) continue;

                ma_uint32 read;
                if (outCh == SURROUND_CHANNEL_COUNT) {
                    memset(sys->streamStage, 0, sizeof(float) * frameCount * CHANNEL_COUNT);
                    read = sys->readFromBuffer(i, sys->streamStage, frameCount);
                    if (read > 0) sys->routeStreamToOutput(i, sys->streamStage, out, frameCount, outCh);
                } else {
                    read = sys->readFromBuffer(i, out, frameCount);
                }

                if (read > 0) anyActive = true;
                if (read < frameCount && sys->streams[i].active.load(std::memory_order_acquire))
                    anyRefill = true;
            }
        } else {
            static_assert(MAX_CALLBACK_FRAMES >= 4096,
                          "MAX_CALLBACK_FRAMES too small for pitched playback buffers");

            if (frameCount > MAX_CALLBACK_FRAMES) {
                int currentState = sys->mixerState.load(std::memory_order_acquire);
                if (currentState != 2) sys->mixerState.store(anyActive ? 1 : 3, std::memory_order_release);
                (void)pInput;
                return;
            }

            float* inputMix = sys->pitchInputMix;

            static double positionError = 0;
            double exactRead = frameCount * rate + positionError;
            ma_uint32 maxToRead = (ma_uint32)exactRead;
            if (maxToRead > MAX_PITCH_FRAMES) maxToRead = MAX_PITCH_FRAMES;

            memset(inputMix, 0, sizeof(float) * maxToRead * outCh);

            positionError = exactRead - maxToRead;

            for (size_t i = 0; i < sys->streams.size(); i++) {
                if (!sys->streams[i].active.load(std::memory_order_acquire)) continue;

                ma_uint32 read;
                if (outCh == SURROUND_CHANNEL_COUNT) {
                    memset(sys->streamStage, 0, sizeof(float) * maxToRead * CHANNEL_COUNT);
                    read = sys->readFromBuffer(i, sys->streamStage, maxToRead);
                    if (read > 0) sys->routeStreamToOutput(i, sys->streamStage, inputMix, maxToRead, outCh);
                } else {
                    read = sys->readFromBuffer(i, inputMix, maxToRead);
                }

                if (read > 0) anyActive = true;
                if (read < maxToRead && sys->streams[i].active.load(std::memory_order_acquire))
                    anyRefill = true;
            }

            if (anyActive) {
                if (sys->stretchEnabled.load(std::memory_order_acquire)) {
                    if (sys->stretchPipe && sys->stretchPipe->push(inputMix, maxToRead, frameCount)) {
                        sys->stretchPipe->pull(out, frameCount);
                    }
                } else if (maxToRead > 0) {
                    double step = (frameCount > 1) ? (double)(maxToRead - 1) / (frameCount - 1) : 0.0;
                    for (ma_uint32 o = 0; o < frameCount; o++) {
                        double srcPos = o * step;
                        ma_uint32 i0 = (ma_uint32)srcPos;
                        if (i0 >= maxToRead) i0 = maxToRead - 1;
                        ma_uint32 i1 = (i0 + 1 < maxToRead) ? i0 + 1 : i0;
                        double frac = srcPos - (double)i0;
                        for (int c = 0; c < outCh; c++) {
                            float s0 = inputMix[i0 * outCh + c];
                            float s1 = inputMix[i1 * outCh + c];
                            out[o * outCh + c] = (float)(s0 + frac * (s1 - s0));
                        }
                    }
                }
            }
        }

        // ---- LFE DSP (surround only) --------------------------------------
        // Runs only when the device is actually open in 3.1 and at least one
        // stream produced audio this callback.  This is the sole difference
        // between the surround path and the stereo path: the stereo path
        // never touches subDSP.
        if (outCh == SURROUND_CHANNEL_COUNT && anyActive) {
            sys->subDSP.process(out, frameCount);
        }

        if (anyRefill && sys->asyncLoader)
            sys->asyncLoader->signal();

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
        stretchPipe    = other.stretchPipe;
        asyncLoader    = other.asyncLoader;

        streamChannels = std::move(other.streamChannels);
        streamLpfState = std::move(other.streamLpfState);
        playbackChannels.store(other.playbackChannels.load(std::memory_order_relaxed), std::memory_order_relaxed);
        surroundEnabled.store(other.surroundEnabled.load(std::memory_order_relaxed), std::memory_order_relaxed);

        memcpy(&device, &other.device, sizeof(ma_device));
        memset(&other.device, 0, sizeof(ma_device));

        longestDecoderIndex = other.longestDecoderIndex;
        playbackRate.store(other.playbackRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        mixerState.store(other.mixerState.load(std::memory_order_relaxed), std::memory_order_relaxed);
        exists.store(other.exists.load(std::memory_order_relaxed), std::memory_order_relaxed);
        stretchEnabled.store(other.stretchEnabled.load(std::memory_order_relaxed), std::memory_order_relaxed);

        other.stretchPipe  = nullptr;  other.asyncLoader = nullptr;
        other.longestDecoderIndex = 0;  other.playbackRate.store(1.0f, std::memory_order_relaxed);
        other.mixerState.store(3, std::memory_order_relaxed);
        other.exists.store(false, std::memory_order_relaxed);

        predictBaseTimeNs.store(other.predictBaseTimeNs.load(std::memory_order_relaxed), std::memory_order_relaxed);
        predictBaseFrames.store(other.predictBaseFrames.load(std::memory_order_relaxed), std::memory_order_relaxed);
        predictRate.store(other.predictRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        predictInit.store(other.predictInit.load(std::memory_order_relaxed), std::memory_order_relaxed);
        predictPrevRate.store(other.predictPrevRate.load(std::memory_order_relaxed), std::memory_order_relaxed);
        other.predictBaseTimeNs.store(0, std::memory_order_relaxed);
        other.predictBaseFrames.store(0.0, std::memory_order_relaxed);
        other.predictRate.store(1.0, std::memory_order_relaxed);
        other.predictInit.store(false, std::memory_order_relaxed);
        other.predictPrevRate.store(1.0f, std::memory_order_relaxed);

        // SubBusDSP is POD; a straight memcpy carries its state cleanly.
        memcpy(&subDSP, &other.subDSP, sizeof(SubBusDSP));
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
    std::atomic<ma_uint64> startFrame{0};

    SoundEffectInstance() = default;

    SoundEffectInstance(float* data, ma_uint64 frames, double vol = 1.0f)
        : pcmData(data), frameCount(frames), playbackPosition(0),
          volume(vol), playing(true), startFrame(0) {}

    SoundEffectInstance(SoundEffectInstance&& other) noexcept
        : pcmData(other.pcmData),
          frameCount(other.frameCount),
          playbackPosition(other.playbackPosition),
          volume(other.volume),
          playing(other.playing.load(std::memory_order_relaxed)),
          startFrame(other.startFrame.load(std::memory_order_relaxed))
    {
        other.pcmData = nullptr;
        other.frameCount = 0;
        other.playbackPosition = 0;
        other.volume = 1.0f;
        other.playing.store(false, std::memory_order_relaxed);
        other.startFrame.store(0, std::memory_order_relaxed);
    }

    SoundEffectInstance& operator=(SoundEffectInstance&& other) noexcept {
        if (this != &other) {
            pcmData = other.pcmData;
            frameCount = other.frameCount;
            playbackPosition = other.playbackPosition;
            volume = other.volume;
            playing.store(other.playing.load(std::memory_order_relaxed), std::memory_order_relaxed);
            startFrame.store(other.startFrame.load(std::memory_order_relaxed), std::memory_order_relaxed);

            other.pcmData = nullptr;
            other.frameCount = 0;
            other.playbackPosition = 0;
            other.volume = 1.0f;
            other.playing.store(false, std::memory_order_relaxed);
            other.startFrame.store(0, std::memory_order_relaxed);
        }
        return *this;
    }

    SoundEffectInstance(const SoundEffectInstance&) = delete;
    SoundEffectInstance& operator=(const SoundEffectInstance&) = delete;

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames,
                         ma_uint64 bufStartFrame, double masterVol) {
        if (!playing.load(std::memory_order_acquire) || !pcmData) return 0;

        long long offset = (long long)startFrame.load(std::memory_order_relaxed)
                         - (long long)bufStartFrame;
        if (offset >= (long long)requestedFrames) return 0;
        if (offset < 0) offset = 0;
        playbackPosition += (ma_uint64)offset;

        ma_uint64 remaining = frameCount - playbackPosition;
        if (remaining == 0) { playing.store(false, std::memory_order_release); return 0; }

        ma_uint32 toRead = (ma_uint32)std::min<ma_uint64>(remaining,
                                                          (ma_uint64)(requestedFrames - offset));
        float* src = pcmData + (playbackPosition * CHANNEL_COUNT);
        float* dst = output  + (offset  * CHANNEL_COUNT);
        float  vol = (float)(volume * masterVol);

        g_mix_func(dst, src, (int)(toRead * CHANNEL_COUNT), vol);

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

    void play(double volume = 1.0f, ma_uint64 startFrame = 0) {
        if (!pcmData || frameCount == 0) return;
        for (auto& inst : instances) {
            if (!inst.isPlaying()) {
                inst.playbackPosition = 0;
                inst.volume = volume;
                inst.startFrame.store(startFrame, std::memory_order_release);
                inst.playing.store(true, std::memory_order_release);
                ++playingCount;
                return;
            }
        }
        if (instances.size() < MAX_INSTANCES) {
            SoundEffectInstance inst(pcmData, frameCount, volume);
            inst.startFrame.store(startFrame, std::memory_order_relaxed);
            instances.push_back(std::move(inst));
            ++playingCount;
        }
    }

    ma_uint64 readFrames(float* output, ma_uint32 requestedFrames,
                         ma_uint64 bufStartFrame, double masterVol) {
        if (playingCount == 0) return 0;
        ma_uint64 maxRead = 0;
        int stillPlaying = 0;
        for (auto& inst : instances) {
            if (inst.isPlaying()) {
                ma_uint64 r = inst.readFrames(output, requestedFrames, bufStartFrame, masterVol);
                if (r > maxRead) maxRead = r;
                if (inst.isPlaying()) ++stillPlaying;
            }
        }
        playingCount = stillPlaying;
        return maxRead;
    }

    bool  isAnyPlaying()  const { return playingCount > 0; }
    void  stopAll()             { for (auto& i : instances) { i.playing.store(false, std::memory_order_release); i.playbackPosition = 0; i.startFrame.store(0, std::memory_order_release); } playingCount = 0; }
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
        cfg.periodSizeInFrames= PERIOD_SIZE;
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
        outFramesTotal.store(0, std::memory_order_relaxed);
        lastAnchorFrame.store(0, std::memory_order_relaxed);
        lastAnchorTime.store(0, std::memory_order_relaxed);
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
        if (!inRange(idx, soundEffectPools)) return;
        ma_uint64 startFrame = 0;
        long long anchorTime = lastAnchorTime.load(std::memory_order_relaxed);
        if (anchorTime != 0) {
            long long nowNs = std::chrono::steady_clock::now().time_since_epoch().count();
            long long dtNs = nowNs - anchorTime;
            ma_uint64 anchorFrame = lastAnchorFrame.load(std::memory_order_relaxed);
            if (dtNs > 0)
                startFrame = anchorFrame + (ma_uint64)((double)dtNs * (SAMPLE_RATE / 1000000000.0));
            else
                startFrame = anchorFrame;
        } else {
            startFrame = outFramesTotal.load(std::memory_order_relaxed);
        }
        soundEffectPools[idx].play(volume, startFrame);
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

    std::atomic<ma_uint64> outFramesTotal{0};
    std::atomic<ma_uint64> lastAnchorFrame{0};
    std::atomic<long long> lastAnchorTime{0};

    std::vector<BackgroundTrack*> bgSnapshot[3];
    std::vector<SoundEffectPool*> sfxSnapshot[3];

    std::atomic<int> readerIndex{0};
    std::atomic<int> newestIndex{1};

    void publishSnapshot() {
        int r = readerIndex.load(std::memory_order_acquire);
        int n = newestIndex.load(std::memory_order_acquire);

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

        ma_uint64 bufStart = mixer->outFramesTotal.fetch_add(frameCount, std::memory_order_relaxed);
        mixer->lastAnchorFrame.store(bufStart, std::memory_order_relaxed);
        mixer->lastAnchorTime.store(
            std::chrono::steady_clock::now().time_since_epoch().count(),
            std::memory_order_relaxed);
        double masterVol = MUSIC_MASTER_VOLUME_099.load(std::memory_order_relaxed);

        int r = mixer->readerIndex.load(std::memory_order_relaxed);
        int n = mixer->newestIndex.load(std::memory_order_acquire);
        if (r != n) {
            mixer->readerIndex.store(n, std::memory_order_release);
            r = n;
        }

        for (BackgroundTrack* track : mixer->bgSnapshot[r])
            if (track->active.load(std::memory_order_acquire)) track->readFrames(out, frameCount);

        for (SoundEffectPool* pool : mixer->sfxSnapshot[r])
            pool->readFrames(out, frameCount, bufStart, masterVol);

        (void)pInput;
    }
};