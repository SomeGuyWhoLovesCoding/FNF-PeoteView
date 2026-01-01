/*
 * Triple-buffered sliding window implementation with proper continuity.
 * RAII implementation - Resources manage their own lifetimes
 *
 * Originally done as a small and isolated c++ test project.
 */
#include "include/ma_thing.h"

#define SIGNALSMITH_STRETCH_IMPLEMENTATION
#include "signalsmith-stretch/signalsmith-stretch.h"

#if _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

// Then include stb_vorbis as C code
#ifdef __cplusplus
extern "C" {
#endif

#define STB_VORBIS_IMPLEMENTATION
#include "extras/stb_vorbis.c"

#ifdef __cplusplus
}
#endif

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

#include <stdio.h>
#include <stdint.h>
#include <vector>
#include <string>
#include <algorithm>
#include <array>
#include <thread>
#include <atomic>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <unordered_map>

#ifdef HX_WINDOWS
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <locale>
#include <codecvt>
#include <windows.h>
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

	hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
						 __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator);
	if (SUCCEEDED(hr)) {
		if (SUCCEEDED(pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice))) {
			if (SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
				PROPVARIANT varName;
				PropVariantInit(&varName);
				const PROPERTYKEY* keys[] = { &PKEY_Device_DeviceDesc, &PKEY_Device_FriendlyName };
				for (int i=0;i<2 && !isHeadphones;i++) {
					if (SUCCEEDED(pProps->GetValue(*keys[i], &varName)) && varName.vt==VT_LPWSTR && varName.pwszVal) {
						std::string name = wstring_to_string(varName.pwszVal);
						std::transform(name.begin(), name.end(), name.begin(), ::tolower);
						const char* kws[] = { "headphone","headset","earphone","earbud","airpod",
							"bluetooth","bt","wireless","ear piece","usb audio speakers" };
						for (const char* kw : kws) if (name.find(kw)!=std::string::npos) {
							isHeadphones=true; break;
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

bool checkIfPnPDevice() {
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
		const char* pnpPatterns[] = { "usb#","bth#","bthenum#",
			/**/"swd#mmdevapi#","bluetooth","hid#","uefi" };
		const char* internalPatterns[] = { "hdaudio#","intel","realtek",
			/**/"amd","nvidia","high definition audio","hd audio" };
		for (const char* pat:pnpPatterns) if(id.find(pat)!=std::string::npos) {
			isPnP=true; break;
		}
		if(!isPnP) for (const char* pat:internalPatterns) if(id.find(pat)!=std::string::npos) {
			isPnP=false; break;
		}
		CoTaskMemFree(pwszDeviceId);
	}

	if (!isPnP && SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
		PROPVARIANT var; PropVariantInit(&var);
		const PROPERTYKEY* keys[] = { &PKEY_Device_FriendlyName, &PKEY_Device_DeviceDesc,
			&PKEY_DeviceInterface_FriendlyName };
		for(int i=0;i<3 && !isPnP;i++){
			if(SUCCEEDED(pProps->GetValue(*keys[i],&var)) && var.vt==VT_LPWSTR && var.pwszVal){
				std::string s = wstring_to_string(var.pwszVal);
				std::transform(s.begin(),s.end(),s.begin(),::tolower);
				const char* kws[]={"usb","bluetooth","bt","wireless",
					"external","headset","airpod","bose","sony","jbl",
					"logitech","hdmi","displayport","digital audio",
					"digital output","soundblaster","audio interface",
					"dac","amplifier"};
				const char* internalKws[]={"speakers","internal","built-in",
					"default","primary","main","system","laptop",
					"desktop","monitor","display"};
				bool foundInternal=false; for(const char* k:internalKws) if(s.find(k)!=std::string::npos){
					foundInternal=true;break;
				}
				if(!foundInternal) for(const char* k:kws) if(s.find(k)!=std::string::npos){
					isPnP=true; break;
				}
			}
		}
		PropVariantClear(&var); pProps->Release();
	}

cleanup:
	if(pDevice)pDevice->Release();
	if(pEnumerator)pEnumerator->Release();
	if(comInitialized) CoUninitialize();
	return isPnP;
}
#endif

#define SAMPLE_FORMAT ma_format_f32
#define CHANNEL_COUNT 2
#define SAMPLE_RATE 44100

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//  - MUSIC TRACK - //
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Buffer constants - slightly increased for stability
#define PADDING_MS 150  // Increased from 100
#define BUFFER_MS 750   // Increased from 500
#define HALF_BUFFER_MS 375  // Increased from 250

#define PADDING_FRAMES ((SAMPLE_RATE * PADDING_MS) / 1000)
#define BUFFER_FRAMES ((SAMPLE_RATE * BUFFER_MS) / 1000)
#define HALF_BUFFER_FRAMES ((SAMPLE_RATE * HALF_BUFFER_MS) / 1000)
#define TOTAL_BUFFER_FRAMES (PADDING_FRAMES + BUFFER_FRAMES + PADDING_FRAMES)

// Async loader forward declaration
class AsyncLoader;

// Triple-buffered decoder stream with async loading
struct DecoderStream {
    // Buffers (triple-buffered)
    float* pcmBufferA = nullptr;
    float* pcmBufferB = nullptr;
    float* pcmBufferC = nullptr;
    
    // Pointers used by audio thread
    float* activeBuffer = nullptr;
    float* nextBuffer = nullptr;
    float* loadingBuffer = nullptr;
    
    // Audio thread state (only touched by audio thread)
    ma_uint64 filePosition = 0;
    ma_uint64 bufferStartPos = 0;
    ma_uint64 localReadPos = 0;
    ma_uint64 validFrames = 0;
    
    // Async loading state (atomic for lock-free access)
    struct AsyncState {
        // Current buffer state
        ma_uint64 nextBufferStartPos = 0;
        ma_uint64 nextBufferValidFrames = 0;
        ma_uint64 loadingBufferStartPos = 0;
        ma_uint64 loadingBufferValidFrames = 0;
        
        // Buffer ready flags (atomic)
        std::atomic<bool> nextBufferReady{false};
        std::atomic<bool> loadingBufferReady{false};
        
        // Loading in progress flag
        std::atomic<bool> loadingInProgress{false};
        
        // Request flags
        std::atomic<bool> needsLoad{false};
        std::atomic<bool> requestNextBuffer{false};
        std::atomic<bool> requestLoadingBuffer{false};
        
        // Buffer pointers for async thread
        float* asyncNextBuffer = nullptr;
        float* asyncLoadingBuffer = nullptr;
        
    } asyncState;
    
    bool active = false;
    ma_decoder decoder;
    ma_uint64 decoderLength = 0;
    ma_uint64 detectedLatency = 0;
    
    DecoderStream() {
        memset(&decoder, 0, sizeof(ma_decoder));
    }
    
    ~DecoderStream() {
        cleanup();
    }
    
    // Move constructor
    DecoderStream(DecoderStream&& other) noexcept {
        moveFrom(std::move(other));
    }
    
    // Move assignment
    DecoderStream& operator=(DecoderStream&& other) noexcept {
        if (this != &other) {
            cleanup();
            moveFrom(std::move(other));
        }
        return *this;
    }
    
    // Delete copy operations
    DecoderStream(const DecoderStream&) = delete;
    DecoderStream& operator=(const DecoderStream&) = delete;
    
    // Buffer swap - only called from audio thread
    bool trySwapBuffers() {
        // Use atomic load to check if next buffer is ready
        if (!asyncState.nextBufferReady.load(std::memory_order_acquire)) {
            return false;
        }
        
        // Save current read position relative to buffer start
        ma_uint64 currentGlobalPos = bufferStartPos + localReadPos;
        
        // Perform the rotation
        float* oldActive = activeBuffer;
        float* oldNext = nextBuffer;
        float* oldLoading = loadingBuffer;
        
        // Rotate buffers
        activeBuffer = oldNext;
        nextBuffer = oldLoading;
        loadingBuffer = oldActive;
        
        // Update positions from async state
        bufferStartPos = asyncState.nextBufferStartPos;
        validFrames = asyncState.nextBufferValidFrames;
        
        // Rotate async state
        asyncState.nextBufferStartPos = asyncState.loadingBufferStartPos;
        asyncState.nextBufferValidFrames = asyncState.loadingBufferValidFrames;
        
        // Reset loading buffer state
        asyncState.loadingBufferStartPos = 0;
        asyncState.loadingBufferValidFrames = 0;
        
        // Update atomic flags
        asyncState.nextBufferReady.store(
            asyncState.loadingBufferReady.load(std::memory_order_relaxed),
            std::memory_order_release
        );
        asyncState.loadingBufferReady.store(false, std::memory_order_release);
        
        // Update buffer pointers for async thread
        asyncState.asyncNextBuffer = oldLoading;
        asyncState.asyncLoadingBuffer = oldActive;
        
        // Calculate new localReadPos
        if (currentGlobalPos >= bufferStartPos && currentGlobalPos < bufferStartPos + validFrames) {
            localReadPos = currentGlobalPos - bufferStartPos;
        } else if (currentGlobalPos < bufferStartPos) {
            localReadPos = 0;
        } else {
            localReadPos = std::min<ma_uint64>(validFrames, (ma_uint64)TOTAL_BUFFER_FRAMES);
        }
        
        // Clamp to buffer bounds
        if (localReadPos >= TOTAL_BUFFER_FRAMES) {
            localReadPos = TOTAL_BUFFER_FRAMES - 1;
        }
        
        // Request new buffer loading
        asyncState.requestLoadingBuffer.store(true, std::memory_order_release);
        
        return true;
    }
    
    // Reset state
    void resetState() {
        // Reset atomic flags
        asyncState.nextBufferReady.store(false, std::memory_order_release);
        asyncState.loadingBufferReady.store(false, std::memory_order_release);
        asyncState.loadingInProgress.store(false, std::memory_order_release);
        asyncState.needsLoad.store(false, std::memory_order_release);
        asyncState.requestNextBuffer.store(false, std::memory_order_release);
        asyncState.requestLoadingBuffer.store(false, std::memory_order_release);
        
        asyncState.nextBufferValidFrames = 0;
        asyncState.loadingBufferValidFrames = 0;
        asyncState.nextBufferStartPos = 0;
        asyncState.loadingBufferStartPos = 0;
        
        filePosition = 0;
        bufferStartPos = 0;
        localReadPos = 0;
        validFrames = 0;
        
        if (pcmBufferA) memset(pcmBufferA, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
        if (pcmBufferB) memset(pcmBufferB, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
        if (pcmBufferC) memset(pcmBufferC, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
    }
    
    // Check if swap should happen (audio thread only)
    bool shouldSwapBuffers() const {
        // Only swap when we're near the end of valid data in the current buffer
        if (localReadPos >= validFrames) {
            return true;
        }
        
        // Swap when we're past the halfway point AND next buffer is ready
        if (localReadPos >= (PADDING_FRAMES + HALF_BUFFER_FRAMES) && 
            asyncState.nextBufferReady.load(std::memory_order_acquire)) {
            return true;
        }
        
        return false;
    }
    
    // Check if buffer is low (audio thread only)
    bool isBufferLow() const {
        ma_uint64 available = (localReadPos < validFrames) ? 
                            (validFrames - localReadPos) : 0;
        return available < (HALF_BUFFER_FRAMES / 2);
    }
    
    // Request buffer load from audio thread
    void requestBufferLoad() {
        if (!asyncState.nextBufferReady.load(std::memory_order_relaxed) &&
            !asyncState.loadingInProgress.load(std::memory_order_relaxed)) {
            asyncState.requestNextBuffer.store(true, std::memory_order_release);
        }
    }
    
    // Fill buffer (for sync operations)
    void fillBuffer(float* buffer, ma_uint64 decodeStart, ma_uint64* framesRead) {
        ma_uint64 maxDecodeFrames = TOTAL_BUFFER_FRAMES;
        if(decodeStart + TOTAL_BUFFER_FRAMES > decoderLength) {
            maxDecodeFrames = decoderLength - decodeStart;
        }
        
        memset(buffer, 0, maxDecodeFrames * CHANNEL_COUNT * sizeof(float));
        
        if(maxDecodeFrames > 0) {
            ma_decoder_seek_to_pcm_frame(&decoder, decodeStart);
            ma_decoder_read_pcm_frames(&decoder, buffer, maxDecodeFrames, framesRead);
        } else {
            *framesRead = 0;
        }
    }
    
    // Fill buffer for async operations (uses mutex for decoder safety)
    void fillBufferAsync(ma_uint64 decodeStart, float* buffer, ma_uint64* framesRead) {
        ma_uint64 maxDecodeFrames = TOTAL_BUFFER_FRAMES;
        if (decodeStart + TOTAL_BUFFER_FRAMES > decoderLength) {
            maxDecodeFrames = decoderLength - decodeStart;
        }
        
        memset(buffer, 0, maxDecodeFrames * CHANNEL_COUNT * sizeof(float));
        
        if (maxDecodeFrames > 0) {
            // Use a mutex for decoder access since miniaudio decoders aren't thread-safe
            static std::mutex decoderMutex;
            std::lock_guard<std::mutex> lock(decoderMutex);
            
            ma_decoder_seek_to_pcm_frame(&decoder, decodeStart);
            ma_decoder_read_pcm_frames(&decoder, buffer, maxDecodeFrames, framesRead);
        } else {
            *framesRead = 0;
        }
    }
    
private:
    void cleanup() {
        if (decoder.onRead != nullptr || decoder.onSeek != nullptr) {
            ma_decoder_uninit(&decoder);
        }
        
        if (pcmBufferA) {
            free(pcmBufferA);
            pcmBufferA = nullptr;
        }
        if (pcmBufferB) {
            free(pcmBufferB);
            pcmBufferB = nullptr;
        }
        if (pcmBufferC) {
            free(pcmBufferC);
            pcmBufferC = nullptr;
        }
        
        activeBuffer = nullptr;
        nextBuffer = nullptr;
        loadingBuffer = nullptr;
        asyncState.asyncNextBuffer = nullptr;
        asyncState.asyncLoadingBuffer = nullptr;
    }
    
    void moveFrom(DecoderStream&& other) noexcept {
        // Move resources
        pcmBufferA = other.pcmBufferA;
        pcmBufferB = other.pcmBufferB;
        pcmBufferC = other.pcmBufferC;
        activeBuffer = other.activeBuffer;
        nextBuffer = other.nextBuffer;
        loadingBuffer = other.loadingBuffer;
        
        // Move decoder
        memcpy(&decoder, &other.decoder, sizeof(ma_decoder));
        
        // Move regular members
        filePosition = other.filePosition;
        bufferStartPos = other.bufferStartPos;
        localReadPos = other.localReadPos;
        validFrames = other.validFrames;
        active = other.active;
        decoderLength = other.decoderLength;
        detectedLatency = other.detectedLatency;
        
        // Move async state (non-atomic members)
        asyncState.nextBufferStartPos = other.asyncState.nextBufferStartPos;
        asyncState.nextBufferValidFrames = other.asyncState.nextBufferValidFrames;
        asyncState.loadingBufferStartPos = other.asyncState.loadingBufferStartPos;
        asyncState.loadingBufferValidFrames = other.asyncState.loadingBufferValidFrames;
        asyncState.asyncNextBuffer = other.asyncState.asyncNextBuffer;
        asyncState.asyncLoadingBuffer = other.asyncState.asyncLoadingBuffer;
        
        // Atomic members will be re-initialized to defaults
        
        // Clear other
        other.pcmBufferA = nullptr;
        other.pcmBufferB = nullptr;
        other.pcmBufferC = nullptr;
        other.activeBuffer = nullptr;
        other.nextBuffer = nullptr;
        other.loadingBuffer = nullptr;
        other.asyncState.asyncNextBuffer = nullptr;
        other.asyncState.asyncLoadingBuffer = nullptr;
        memset(&other.decoder, 0, sizeof(ma_decoder));
    }
};

// Async loader class
class AsyncLoader {
private:
    std::vector<DecoderStream*>& streams;
    std::thread workerThread;
    std::atomic<bool> running{false};
    std::atomic<bool> pause{false};
    
public:
    AsyncLoader(std::vector<DecoderStream*>& streamRefs) 
        : streams(streamRefs) {
        start();
    }
    
    ~AsyncLoader() {
        stop();
    }
    
    void start() {
        running.store(true, std::memory_order_release);
        workerThread = std::thread([this]() { worker(); });
    }
    
    void stop() {
        running.store(false, std::memory_order_release);
        if (workerThread.joinable()) {
            workerThread.join();
        }
    }
    
    void pauseLoading() {
        pause.store(true, std::memory_order_release);
    }
    
    void resumeLoading() {
        pause.store(false, std::memory_order_release);
    }
    
private:
    void worker() {
        constexpr int MAX_STREAMS_PER_CYCLE = 2; // Process 2 streams per cycle to avoid starvation
        int currentStream = 0;
        
        while (running.load(std::memory_order_acquire)) {
            if (pause.load(std::memory_order_acquire)) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            
            int processed = 0;
            for (int i = 0; i < streams.size() && processed < MAX_STREAMS_PER_CYCLE; i++) {
                int index = (currentStream + i) % streams.size();
                DecoderStream* stream = streams[index];
                
                if (!stream || !stream->active) {
                    continue;
                }
                
                // Process this stream if it needs loading
                bool processedThis = processStreamLoad(stream);
                if (processedThis) {
                    processed++;
                }
            }
            
            currentStream = (currentStream + 1) % streams.size();
            
            // Sleep briefly if nothing was processed to avoid busy-waiting
            if (processed == 0) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    }
    
    bool processStreamLoad(DecoderStream* stream) {
        bool didWork = false;
        
        // Check if next buffer is requested
        if (stream->asyncState.requestNextBuffer.load(std::memory_order_acquire)) {
            // Try to start loading next buffer
            if (!stream->asyncState.loadingInProgress.load(std::memory_order_relaxed)) {
                if (tryLoadNextBuffer(stream)) {
                    didWork = true;
                }
            }
            stream->asyncState.requestNextBuffer.store(false, std::memory_order_release);
        }
        
        // Check if loading buffer is requested
        if (stream->asyncState.requestLoadingBuffer.load(std::memory_order_acquire)) {
            // Try to start loading loading buffer
            if (!stream->asyncState.loadingInProgress.load(std::memory_order_relaxed) &&
                stream->asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
                if (tryLoadLoadingBuffer(stream)) {
                    didWork = true;
                }
            }
            stream->asyncState.requestLoadingBuffer.store(false, std::memory_order_release);
        }
        
        return didWork;
    }
    
    bool tryLoadNextBuffer(DecoderStream* stream) {
        // Check if already in progress or already ready
        bool expected = false;
        if (!stream->asyncState.loadingInProgress.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel)) {
            return false;
        }
        
        // Calculate buffer start position
        ma_uint64 nextBufferStart = stream->bufferStartPos + HALF_BUFFER_FRAMES;
        if (nextBufferStart > PADDING_FRAMES) {
            nextBufferStart -= PADDING_FRAMES;
        }
        
        if (nextBufferStart >= stream->decoderLength) {
            stream->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }
        
        // Load the buffer
        float* targetBuffer = stream->asyncState.asyncNextBuffer;
        if (!targetBuffer) {
            stream->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }
        
        ma_uint64 framesRead = 0;
        stream->fillBufferAsync(nextBufferStart, targetBuffer, &framesRead);
        
        // Update state atomically
        stream->asyncState.nextBufferStartPos = nextBufferStart;
        stream->asyncState.nextBufferValidFrames = framesRead;
        stream->asyncState.nextBufferReady.store(true, std::memory_order_release);
        stream->asyncState.loadingInProgress.store(false, std::memory_order_release);
        
        return true;
    }
    
    bool tryLoadLoadingBuffer(DecoderStream* stream) {
        // Check if already in progress or already ready
        bool expected = false;
        if (!stream->asyncState.loadingInProgress.compare_exchange_strong(
            expected, true, std::memory_order_acq_rel)) {
            return false;
        }
        
        // Calculate buffer start position
        ma_uint64 loadingBufferStart = stream->asyncState.nextBufferStartPos + HALF_BUFFER_FRAMES;
        if (loadingBufferStart > PADDING_FRAMES) {
            loadingBufferStart -= PADDING_FRAMES;
        }
        
        if (loadingBufferStart >= stream->decoderLength) {
            stream->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }
        
        // Load the buffer
        float* targetBuffer = stream->asyncState.asyncLoadingBuffer;
        if (!targetBuffer) {
            stream->asyncState.loadingInProgress.store(false, std::memory_order_release);
            return false;
        }
        
        ma_uint64 framesRead = 0;
        stream->fillBufferAsync(loadingBufferStart, targetBuffer, &framesRead);
        
        // Update state atomically
        stream->asyncState.loadingBufferStartPos = loadingBufferStart;
        stream->asyncState.loadingBufferValidFrames = framesRead;
        stream->asyncState.loadingBufferReady.store(true, std::memory_order_release);
        stream->asyncState.loadingInProgress.store(false, std::memory_order_release);
        
        return true;
    }
};

// Main audio system manager
class AudioSystem {
private:
    AsyncLoader* asyncLoader = nullptr;
    std::vector<DecoderStream*> streamPtrs;  // Pointers for async loader
    
public:
    std::vector<DecoderStream> streams;
    std::vector<float> decoderVolumes;
    std::vector<std::string> filePaths;
    
    ma_device device;
    signalsmith::stretch::SignalsmithStretch* stretch = nullptr;
    
    int longestDecoderIndex = 0;
    float playbackRate = 1.0f;
    int mixerState = 3;
    bool exists = false;
    double masterVolume = 1.0;
    
    ma_uint64 detectedLatency = 0;  // Max latency across all decoders
    bool latenciesDetected = false;
    static constexpr float SILENCE_THRESHOLD = 0.1f;
    
    ma_uint32 callbackCounter = 0;
    
    AudioSystem() {
        memset(&device, 0, sizeof(ma_device));
    }
    
    ~AudioSystem() {
        destroy();
    }
    
    // Move operations
    AudioSystem(AudioSystem&& other) noexcept {
        moveFrom(std::move(other));
    }
    
    AudioSystem& operator=(AudioSystem&& other) noexcept {
        if (this != &other) {
            destroy();
            moveFrom(std::move(other));
        }
        return *this;
    }
    
    // Delete copy operations
    AudioSystem(const AudioSystem&) = delete;
    AudioSystem& operator=(const AudioSystem&) = delete;
    
    void loadFiles(std::vector<const char*> argv) {
        if(argv.empty()){
            printf("No input files.\n");
            return;
        }
        
        destroy();
        
        filePaths.clear();
        for (size_t i = 0; i < argv.size(); i++) {
            filePaths.push_back(argv[i]);
        }
        
        streams.resize(argv.size());
        decoderVolumes.resize(argv.size(), 1.0f);
        
        ma_uint64 absoluteLengthOfSong = 0;
        ma_decoder_config decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
        
        for(size_t i = 0; i < argv.size(); i++) {
            const char* path = argv[i];
            DecoderStream& s = streams[i];
            
            ma_result result = ma_decoder_init_file(path, &decoderConfig, &s.decoder);
            if(result != MA_SUCCESS){
                for(size_t j = 0; j < i; j++) {
                    ma_decoder_uninit(&streams[j].decoder);
                }
                streams.clear();
                decoderVolumes.clear();
                filePaths.clear();
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
            
            s.activeBuffer = s.pcmBufferA;
            s.nextBuffer = s.pcmBufferB;
            s.loadingBuffer = s.pcmBufferC;
            
            // Set async buffer pointers
            s.asyncState.asyncNextBuffer = s.pcmBufferB;
            s.asyncState.asyncLoadingBuffer = s.pcmBufferC;
            
            // Store per-decoder latency
            s.detectedLatency = detectLatency(i);
            if (s.detectedLatency > detectedLatency) {
                detectedLatency = s.detectedLatency;
            }
            
            // Fill initial buffer (starts at 0)
            fillInitialBuffer(i, 0);
            
            // Load BOTH next buffers immediately
            if (s.active) {
                loadNextBufferSync(i);
                if (s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
                    loadLoadingBufferSync(i);
                }
            }
            
            if(s.decoderLength > absoluteLengthOfSong){
                absoluteLengthOfSong = s.decoderLength;
                longestDecoderIndex = (int)i;
            }
        }
        
        latenciesDetected = true;
        
        // Initialize async loader
        streamPtrs.clear();
        for (auto& stream : streams) {
            streamPtrs.push_back(&stream);
        }
        
        if (asyncLoader) {
            delete asyncLoader;
        }
        asyncLoader = new AsyncLoader(streamPtrs);
        
        ma_device_config deviceConfig = ma_device_config_init(ma_device_type_playback);
        deviceConfig.playback.format = SAMPLE_FORMAT;
        deviceConfig.playback.channels = CHANNEL_COUNT;
        deviceConfig.sampleRate = SAMPLE_RATE;
        deviceConfig.dataCallback = data_callback;
        deviceConfig.pUserData = this;
        
        if(ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS){
            streams.clear();
            decoderVolumes.clear();
            filePaths.clear();
            printf("Failed to open playback device.\n");
            return;
        }
        
        exists = true;
        mixerState = 3;
    }
    
    ma_uint64 detectLatency(size_t index) {
        DecoderStream& s = streams[index];
        
        const ma_uint64 SCAN_CHUNK_SIZE = 4096;
        float* scanBuffer = (float*)malloc(sizeof(float) * SCAN_CHUNK_SIZE * CHANNEL_COUNT);
        
        if (!scanBuffer) return 0;
        
        ma_decoder_seek_to_pcm_frame(&s.decoder, 0);
        
        ma_uint64 totalFramesScanned = 0;
        ma_uint64 latencyFrames = 0;
        bool foundSignal = false;
        
        ma_uint64 maxFramesToScan = SAMPLE_RATE * 0.1;
        if (maxFramesToScan > s.decoderLength) {
            maxFramesToScan = s.decoderLength;
        }
        
        while (totalFramesScanned < maxFramesToScan && !foundSignal) {
            ma_uint64 framesToRead = SCAN_CHUNK_SIZE;
            if (totalFramesScanned + framesToRead > maxFramesToScan) {
                framesToRead = maxFramesToScan - totalFramesScanned;
            }
            
            ma_uint64 framesRead = 0;
            ma_decoder_read_pcm_frames(&s.decoder, scanBuffer, framesToRead, &framesRead);
            
            if (framesRead == 0) break;
            
            for (ma_uint64 frame = 0; frame < framesRead && !foundSignal; frame++) {
                for (int ch = 0; ch < CHANNEL_COUNT; ch++) {
                    float sample = scanBuffer[frame * CHANNEL_COUNT + ch];
                    if (fabs(sample) > SILENCE_THRESHOLD) {
                        latencyFrames = totalFramesScanned + frame;
                        foundSignal = true;
                        break;
                    }
                }
            }
            
            totalFramesScanned += framesRead;
        }
        
        free(scanBuffer);
        ma_decoder_seek_to_pcm_frame(&s.decoder, 0);
        
        return latencyFrames;
    }
    
    double getLatencyMs() const {
        return (double)detectedLatency / (SAMPLE_RATE * 0.001);
    }
    
    ma_uint64 getLatencyFrames() const {
        return detectedLatency;
    }
    
    void destroy() {
        if(!exists) return;
        exists = false;
        
        // Stop async loader first
        if (asyncLoader) {
            delete asyncLoader;
            asyncLoader = nullptr;
        }
        
        ma_device_stop(&device);
        ma_device_uninit(&device);
        
        if (stretch) {
            delete stretch;
            stretch = nullptr;
        }
        
        streams.clear();
        decoderVolumes.clear();
        filePaths.clear();
        streamPtrs.clear();
        
        longestDecoderIndex = 0;
        playbackRate = 1.0f;
        masterVolume = 1.0;
        mixerState = 3;
        latenciesDetected = false;
        detectedLatency = 0;
        callbackCounter = 0;
    }
    
    void start() {
        if(!exists) return;
        
        if(mixerState == 3) {
            seekToPCMFrame(0);
        }
        
        if (asyncLoader) {
            asyncLoader->resumeLoading();
        }
        
        ma_device_start(&device);
        mixerState = 1;
    }
    
    void stop() {
        if(!exists) return;
        
        if (asyncLoader) {
            asyncLoader->pauseLoading();
        }
        
        ma_device_stop(&device);
        mixerState = 2;
    }
    
    bool stopped() const {
        return mixerState == 3;
    }
    
    void seekToPCMFrame(int64_t pos) {
        if(!exists) return;
        
        // Pause async loading during seek
        if (asyncLoader) {
            asyncLoader->pauseLoading();
        }
        
        bool wasPlaying = (mixerState == 1);
        if (wasPlaying) {
            ma_device_stop(&device);
        }
        
        for (size_t i = 0; i < streams.size(); i++) {
            DecoderStream& s = streams[i];
            
            // Seek to the exact position requested
            ma_uint64 target = std::min<ma_uint64>(
                (ma_uint64)std::max<int64_t>(pos, (int64_t)0), 
                s.decoderLength
            );
            
            s.resetState();
            fillInitialBuffer(i, target);
            
            if (s.active && target < s.decoderLength) {
                s.filePosition = target;
            }
            
            // Aggressively preload both buffers synchronously
            if (s.active) {
                loadNextBufferSync(i);
                if (s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
                    loadLoadingBufferSync(i);
                }
            }
        }
        
        mixerState = (pos < (int64_t)streams[longestDecoderIndex].decoderLength) ? 2 : 3;
        
        if (wasPlaying && mixerState == 2) {
            // Resume async loading before starting playback
            if (asyncLoader) {
                asyncLoader->resumeLoading();
            }
            ma_device_start(&device);
            mixerState = 1;
        }
    }
    
    void deactivate_decoder(int index) {
        if(index >= 0 && index < (int)streams.size()) {
            streams[index].active = false;
        }
    }
    
    void amplify_decoder(int index, double volume) {
        if(index >= 0 && index < (int)decoderVolumes.size()) {
            decoderVolumes[index] = (float)volume;
        }
    }
    
    void setPlaybackRate(float value) {
        playbackRate = value;
    }
    
    double getGlobalVolume() const {
        return masterVolume;
    }
    
    double setGlobalVolume(double volume) {
        masterVolume = volume;
        return volume;
    }
    
    int getMixerState() const {
        return mixerState;
    }
    
    double getPlaybackPosition() const {
        ma_uint64 pos = 0;
        if(!streams.empty() && streams[longestDecoderIndex].active) {
            pos = streams[longestDecoderIndex].filePosition;
        } else if(!streams.empty()) {
            pos = streams[longestDecoderIndex].decoderLength;
        }
        return ((double)pos / (SAMPLE_RATE * 0.001));
    }
    
    double getDuration() const {
        if(streams.empty()) return 0.0;
        return (double)streams[longestDecoderIndex].decoderLength / (SAMPLE_RATE * 0.001);
    }
    
    void fillInitialBuffer(size_t index, ma_uint64 startFrame) {
        DecoderStream& s = streams[index];
        
        ma_uint64 decodeStart = 0;
        if(startFrame > PADDING_FRAMES) {
            decodeStart = startFrame - PADDING_FRAMES;
        }
        
        ma_uint64 framesRead = 0;
        s.fillBuffer(s.activeBuffer, decodeStart, &framesRead);
        
        s.bufferStartPos = decodeStart;
        s.validFrames = framesRead;
        
        if(startFrame >= decodeStart) {
            s.localReadPos = startFrame - decodeStart;
        } else {
            s.localReadPos = 0;
        }
        
        if(s.localReadPos >= TOTAL_BUFFER_FRAMES) {
            s.localReadPos = TOTAL_BUFFER_FRAMES - 1;
        }
        
        s.filePosition = startFrame;
        s.active = (startFrame < s.decoderLength && framesRead > 0);
        s.asyncState.needsLoad.store(false, std::memory_order_release);
    }
    
    // Synchronous loading for initial setup
    void loadNextBufferSync(size_t index) {
        DecoderStream& s = streams[index];
        
        if (!s.active || s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
            return;
        }
        
        ma_uint64 nextBufferStart = s.bufferStartPos + HALF_BUFFER_FRAMES;
        if (nextBufferStart > PADDING_FRAMES) {
            nextBufferStart -= PADDING_FRAMES;
        }
        
        if (nextBufferStart >= s.decoderLength) {
            return;
        }
        
        ma_uint64 framesRead = 0;
        s.fillBuffer(s.nextBuffer, nextBufferStart, &framesRead);
        
        s.asyncState.nextBufferStartPos = nextBufferStart;
        s.asyncState.nextBufferValidFrames = framesRead;
        s.asyncState.nextBufferReady.store(true, std::memory_order_release);
    }
    
    // Synchronous loading for initial setup
    void loadLoadingBufferSync(size_t index) {
        DecoderStream& s = streams[index];
        
        if (!s.active || 
            s.asyncState.loadingBufferReady.load(std::memory_order_relaxed) || 
            !s.asyncState.nextBufferReady.load(std::memory_order_relaxed)) {
            return;
        }
        
        ma_uint64 loadingBufferStart = s.asyncState.nextBufferStartPos + HALF_BUFFER_FRAMES;
        if (loadingBufferStart > PADDING_FRAMES) {
            loadingBufferStart -= PADDING_FRAMES;
        }
        
        if (loadingBufferStart >= s.decoderLength) {
            return;
        }
        
        ma_uint64 framesRead = 0;
        s.fillBuffer(s.loadingBuffer, loadingBufferStart, &framesRead);
        
        s.asyncState.loadingBufferStartPos = loadingBufferStart;
        s.asyncState.loadingBufferValidFrames = framesRead;
        s.asyncState.loadingBufferReady.store(true, std::memory_order_release);
    }
    
    // Only make requests, async loader will fulfill them
    void doBackgroundLoading() {
        for (size_t i = 0; i < streams.size(); i++) {
            DecoderStream& s = streams[i];
            
            if (!s.active) {
                continue;
            }
            
            // Check if we need to request next buffer
            if (!s.asyncState.nextBufferReady.load(std::memory_order_acquire) &&
                !s.asyncState.loadingInProgress.load(std::memory_order_acquire)) {
                
                // Only request if we're getting close to needing it
                ma_uint64 available = (s.localReadPos < s.validFrames) ? 
                                    (s.validFrames - s.localReadPos) : 0;
                
                if (available < (HALF_BUFFER_FRAMES * 2)) {
                    s.requestBufferLoad();
                }
            }
            
            // Handle needsLoad flag
            if (s.asyncState.needsLoad.load(std::memory_order_acquire) &&
                !s.asyncState.nextBufferReady.load(std::memory_order_acquire) &&
                !s.asyncState.loadingInProgress.load(std::memory_order_acquire)) {
                
                s.requestBufferLoad();
                s.asyncState.needsLoad.store(false, std::memory_order_release);
            }
        }
    }
    
    ma_uint32 readFromBuffer(size_t index, float* output, ma_uint32 frameCount) {
        DecoderStream& s = streams[index];
        
        if (!s.active) {
            return 0;
        }
        
        if (s.shouldSwapBuffers() || s.isBufferLow()) {
            s.trySwapBuffers();
        }
        
        ma_uint32 framesRead = 0;
        
        while (framesRead < frameCount && s.active) {
            ma_uint64 available = 0;
            if (s.localReadPos < s.validFrames) {
                available = s.validFrames - s.localReadPos;
            }
            
            if (available == 0) {
                if (s.filePosition < s.decoderLength) {
                    if (s.asyncState.nextBufferReady.load(std::memory_order_acquire)) {
                        s.trySwapBuffers();
                        continue;
                    } else {
                        s.asyncState.needsLoad.store(true, std::memory_order_release);
                        break;
                    }
                } else {
                    s.active = false;
                    break;
                }
            }
            
            ma_uint32 toRead = std::min<ma_uint32>((ma_uint32)available, frameCount - framesRead);
            
            float* src = s.activeBuffer + (s.localReadPos * CHANNEL_COUNT);
            float vol = decoderVolumes[index] * (float)masterVolume;
            
            if (vol == 1.0f) {
                for (ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
                    output[framesRead * CHANNEL_COUNT + i] += src[i];
                }
            } else {
                for (ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
                    output[framesRead * CHANNEL_COUNT + i] += src[i] * vol;
                }
            }
            
            s.localReadPos += toRead;
            s.filePosition += toRead;
            framesRead += toRead;
            
            if (s.filePosition >= s.decoderLength) {
                s.active = false;
                break;
            }
        }
        
        return framesRead;
    }
    
    static void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
        AudioSystem* system = static_cast<AudioSystem*>(pDevice->pUserData);
        if (!system || !system->exists) {
            return;
        }
        
        float* pOutputF32 = (float*)pOutput;
        memset(pOutputF32, 0, sizeof(float) * frameCount * CHANNEL_COUNT);
        
        // Only make requests, async loader will fulfill them
        system->doBackgroundLoading();
        
        bool anyActive = false;
        
        if (system->playbackRate == 1.0f) {
            for (size_t i = 0; i < system->streams.size(); i++) {
                if (system->streams[i].active) {
                    ma_uint32 read = system->readFromBuffer(i, pOutputF32, frameCount);
                    if (read > 0) anyActive = true;
                    
                    if (read < frameCount && system->streams[i].active) {
                        system->streams[i].asyncState.needsLoad.store(true, std::memory_order_release);
                    }
                }
            }
        } else {
            float inputMix[4096 * CHANNEL_COUNT] = {0};
            float stretchedOutput[4096 * CHANNEL_COUNT] = {0};
            ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * system->playbackRate);
            
            for (size_t i = 0; i < system->streams.size(); i++) {
                if (system->streams[i].active) {
                    ma_uint32 read = system->readFromBuffer(i, inputMix, maxFramesToRead);
                    if (read > 0) anyActive = true;
                    
                    if (read < maxFramesToRead && system->streams[i].active) {
                        system->streams[i].asyncState.needsLoad.store(true, std::memory_order_release);
                    }
                }
            }
            
            if (anyActive) {
                if (!system->stretch) {
                    system->stretch = new signalsmith::stretch::SignalsmithStretch();
                    system->stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
                }
                system->stretch->process(inputMix, maxFramesToRead, stretchedOutput, frameCount);
                memcpy(pOutputF32, stretchedOutput, sizeof(float) * frameCount * CHANNEL_COUNT);
            }
        }
        
        system->mixerState = anyActive ? 1 : 3;
        (void)pInput;
    }
    
private:
    void moveFrom(AudioSystem&& other) noexcept {
        streams = std::move(other.streams);
        decoderVolumes = std::move(other.decoderVolumes);
        filePaths = std::move(other.filePaths);
        streamPtrs = std::move(other.streamPtrs);
        stretch = other.stretch;
        asyncLoader = other.asyncLoader;
        
        memcpy(&device, &other.device, sizeof(ma_device));
        memset(&other.device, 0, sizeof(ma_device));
        
        longestDecoderIndex = other.longestDecoderIndex;
        playbackRate = other.playbackRate;
        masterVolume = other.masterVolume;
        mixerState = other.mixerState;
        exists = other.exists;
        latenciesDetected = other.latenciesDetected;
        detectedLatency = other.detectedLatency;
        callbackCounter = other.callbackCounter;
        
        other.stretch = nullptr;
        other.asyncLoader = nullptr;
        other.longestDecoderIndex = 0;
        other.playbackRate = 1.0f;
        other.masterVolume = 1.0;
        other.mixerState = 3;
        other.exists = false;
        other.latenciesDetected = false;
        other.detectedLatency = 0;
        other.callbackCounter = 0;
    }
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//  - BG TRACK -    //
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Background track structure - streams audio in real-time with looping support
struct BackgroundTrack {
	ma_decoder decoder;
	ma_uint64 length;
	float volume;
	std::atomic<bool> active;
	std::atomic<bool> looping;
	std::string filePath;
	bool initialized;

	BackgroundTrack() : length(0), volume(1.0f), active(false), looping(true), initialized(false) {
		memset(&decoder, 0, sizeof(ma_decoder));
	}

	~BackgroundTrack() {
		cleanup();
	}

	// Move constructor
	BackgroundTrack(BackgroundTrack&& other) noexcept
		: length(other.length),
		  volume(other.volume),
		  active(other.active.load()),
		  looping(other.looping.load()),
		  filePath(std::move(other.filePath)),
		  initialized(other.initialized) {
		memcpy(&decoder, &other.decoder, sizeof(ma_decoder));
		memset(&other.decoder, 0, sizeof(ma_decoder));
		other.initialized = false;
		other.length = 0;
		other.volume = 1.0f;
		other.active = false;
		other.looping = true;
	}

	// Move assignment
	BackgroundTrack& operator=(BackgroundTrack&& other) noexcept {
		if (this != &other) {
			cleanup();
			memcpy(&decoder, &other.decoder, sizeof(ma_decoder));
			length = other.length;
			volume = other.volume;
			active.store(other.active.load());
			looping.store(other.looping.load());
			filePath = std::move(other.filePath);
			initialized = other.initialized;

			memset(&other.decoder, 0, sizeof(ma_decoder));
			other.initialized = false;
			other.length = 0;
			other.volume = 1.0f;
			other.active = false;
			other.looping = true;
		}
		return *this;
	}

	// Delete copy operations
	BackgroundTrack(const BackgroundTrack&) = delete;
	BackgroundTrack& operator=(const BackgroundTrack&) = delete;

	void cleanup() {
		if (initialized) {
			ma_decoder_uninit(&decoder);
			initialized = false;
		}
		memset(&decoder, 0, sizeof(ma_decoder));
		length = 0;
		volume = 1.0f;
		active = false;
		looping = true;
		filePath.clear();
	}

	bool load(const char* path) {
		cleanup();

		ma_decoder_config config = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
		if (ma_decoder_init_file(path, &config, &decoder) != MA_SUCCESS) {
			printf("Failed to load background track: %s\n", path);
			return false;
		}

		initialized = true;
		filePath = path;
		ma_decoder_get_length_in_pcm_frames(&decoder, &length);
		active = false;
		looping = true;

		return true;
	}

	void play() {
		if (initialized) {
			active = true;
		}
	}

	void stop() {
		active = false;
		if (initialized) {
			ma_decoder_seek_to_pcm_frame(&decoder, 0);
		}
	}

	void setVolume(float vol) {
		volume = vol;
	}

	void setLooping(bool loop) {
		looping = loop;
	}

	// Read frames with volume applied
	ma_uint64 readFrames(float* output, ma_uint32 frameCount, float masterVolume) {
		if (!initialized || !active) return 0;

		float tempBuffer[4096 * CHANNEL_COUNT];
		ma_uint32 toRead = frameCount;
		if (toRead > 4096) toRead = 4096;

		memset(tempBuffer, 0, sizeof(float) * toRead * CHANNEL_COUNT);

		ma_uint64 framesRead = 0;
		ma_decoder_read_pcm_frames(&decoder, tempBuffer, toRead, &framesRead);

		// Mix into output with volume
		float vol = volume * masterVolume;
		for (ma_uint64 i = 0; i < framesRead * CHANNEL_COUNT; i++) {
			output[i] += tempBuffer[i] * vol;
		}

		// Check if we hit the end
		if (framesRead < toRead) {
			// If looping is enabled, seek back to start
			if (looping) {
				ma_decoder_seek_to_pcm_frame(&decoder, 0);

				// Try to read the remaining frames from the beginning
				ma_uint64 remainingFrames = toRead - framesRead;
				if (remainingFrames > 0) {
					float tempBuffer2[4096 * CHANNEL_COUNT];
					ma_uint64 framesRead2 = 0;
					memset(tempBuffer2, 0, sizeof(float) * remainingFrames * CHANNEL_COUNT);
					ma_decoder_read_pcm_frames(&decoder, tempBuffer2, remainingFrames, &framesRead2);

					// Mix the rest of the frames
					for (ma_uint64 i = 0; i < framesRead2 * CHANNEL_COUNT; i++) {
						output[framesRead * CHANNEL_COUNT + i] += tempBuffer2[i] * vol;
					}

					framesRead += framesRead2;
				}
			} else {
				// Not looping, so stop
				active = false;
			}
		}

		return framesRead;
	}
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//  - SOUND EFFECT INSTANCE - //
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Individual sound effect instance
struct SoundEffectInstance {
	float* pcmData;
	ma_uint64 frameCount;
	ma_uint64 playbackPosition;
	float volume;
	bool playing;

	SoundEffectInstance() : pcmData(nullptr), frameCount(0), playbackPosition(0), volume(1.0f), playing(false) {}

	SoundEffectInstance(float* data, ma_uint64 frames, float vol = 1.0f)
		: pcmData(data), frameCount(frames), playbackPosition(0), volume(vol), playing(true) {}

	// Read frames with volume applied
	ma_uint64 readFrames(float* output, ma_uint32 frameCount, float masterVolume) {
		if (!playing || !pcmData) return 0;

		ma_uint64 remaining = this->frameCount - playbackPosition;

		if (remaining == 0) {
			playing = false;
			return 0;
		}

		ma_uint32 toRead = (ma_uint32)remaining;
		if (toRead > frameCount) toRead = frameCount;

		// Mix into output with volume
		float* src = pcmData + (playbackPosition * CHANNEL_COUNT);
		float vol = volume * masterVolume;

		for (ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
			output[i] += src[i] * vol;
		}

		playbackPosition += toRead;

		// Stop if finished
		if (playbackPosition >= this->frameCount) {
			playing = false;
		}

		return toRead;
	}

	bool isPlaying() const {
		return playing;
	}
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//  - SOUND EFFECT POOL - //
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Sound effect pool - manages multiple instances of the same sound
class SoundEffectPool {
private:
	float* pcmData;
	ma_uint64 frameCount;
	std::string name;

	// Pool of available instances (recycled to avoid allocation)
	std::vector<SoundEffectInstance> instances;

	// Maximum number of simultaneous instances
	static const int MAX_INSTANCES = 16;

public:
	SoundEffectPool() : pcmData(nullptr), frameCount(0) {}

	~SoundEffectPool() {
		cleanup();
	}

	// Delete copy operations
	SoundEffectPool(const SoundEffectPool&) = delete;
	SoundEffectPool& operator=(const SoundEffectPool&) = delete;

	// Move operations
	SoundEffectPool(SoundEffectPool&& other) noexcept {
		moveFrom(std::move(other));
	}

	SoundEffectPool& operator=(SoundEffectPool&& other) noexcept {
		if (this != &other) {
			cleanup();
			moveFrom(std::move(other));
		}
		return *this;
	}

	void cleanup() {
		if (pcmData) {
			free(pcmData);
			pcmData = nullptr;
		}
		frameCount = 0;
		name.clear();
		instances.clear();
	}

	bool load(const char* path) {
		cleanup();

		// Decode entire file into memory
		ma_decoder decoder;
		ma_decoder_config config = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

		if (ma_decoder_init_file(path, &config, &decoder) != MA_SUCCESS) {
			printf("Failed to load sound effect: %s\n", path);
			return false;
		}

		ma_uint64 length = 0;
		ma_decoder_get_length_in_pcm_frames(&decoder, &length);

		if (length == 0) {
			ma_decoder_uninit(&decoder);
			printf("Sound effect has zero length: %s\n", path);
			return false;
		}

		// Allocate memory for entire sound
		pcmData = (float*)malloc(sizeof(float) * length * CHANNEL_COUNT);
		if (!pcmData) {
			ma_decoder_uninit(&decoder);
			printf("Failed to allocate memory for sound effect: %s\n", path);
			return false;
		}

		// Read entire file into memory
		ma_uint64 framesRead = 0;
		ma_decoder_read_pcm_frames(&decoder, pcmData, length, &framesRead);
		ma_decoder_uninit(&decoder);

		if (framesRead == 0) {
			cleanup();
			printf("Failed to read sound effect: %s\n", path);
			return false;
		}

		frameCount = framesRead;
		name = path;

		// Pre-allocate instances
		instances.reserve(MAX_INSTANCES);

		return true;
	}

	void play(float volume = 1.0f) {
		if (!pcmData || frameCount == 0) return;

		// Find an available instance or create a new one
		SoundEffectInstance* availableInstance = nullptr;

		// First, try to find a finished instance to reuse
		for (auto& instance : instances) {
			if (!instance.isPlaying()) {
				availableInstance = &instance;
				break;
			}
		}

		if (availableInstance) {
			// Reuse existing instance
			availableInstance->playbackPosition = 0;
			availableInstance->volume = volume;
			availableInstance->playing = true;
		} else if (instances.size() < MAX_INSTANCES) {
			// Create new instance if we haven't reached max
			instances.emplace_back(pcmData, frameCount, volume);
		}
		// If we've reached MAX_INSTANCES and all are playing, do nothing
		// (silently ignore the request - this is common behavior for sound pools)
	}

	// Read frames from all playing instances
	ma_uint64 readFrames(float* output, ma_uint32 frameCount, float masterVolume) {
		ma_uint64 maxFramesRead = 0;

		for (auto& instance : instances) {
			if (instance.isPlaying()) {
				ma_uint64 framesRead = instance.readFrames(output, frameCount, masterVolume);
				if (framesRead > maxFramesRead) {
					maxFramesRead = framesRead;
				}
			}
		}

		return maxFramesRead;
	}

	bool isAnyPlaying() const {
		for (const auto& instance : instances) {
			if (instance.isPlaying()) {
				return true;
			}
		}
		return false;
	}

	void stopAll() {
		for (auto& instance : instances) {
			instance.playing = false;
			instance.playbackPosition = 0;
		}
	}

	int getPlayingCount() const {
		int count = 0;
		for (const auto& instance : instances) {
			if (instance.isPlaying()) {
				count++;
			}
		}
		return count;
	}

private:
	void moveFrom(SoundEffectPool&& other) noexcept {
		pcmData = other.pcmData;
		frameCount = other.frameCount;
		name = std::move(other.name);
		instances = std::move(other.instances);

		other.pcmData = nullptr;
		other.frameCount = 0;
		other.name.clear();
		other.instances.clear();
	}
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//  - UPDATED MIXER MANAGER -   //
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

class AudioMixerManager {
private:
	std::vector<BackgroundTrack> backgroundTracks;
	std::vector<SoundEffectPool> soundEffectPools;  // Changed from SoundEffect to SoundEffectPool
	std::mutex mixerMutex;

	// Maps to track loaded files
	std::unordered_map<std::string, int> backgroundTrackMap;
	std::unordered_map<std::string, int> soundEffectMap;  // Now maps to SoundEffectPool

	ma_device device;
	bool deviceInitialized;
	float masterVolume;

public:
	AudioMixerManager() : deviceInitialized(false), masterVolume(1.0f) {
		memset(&device, 0, sizeof(ma_device));
	}

	~AudioMixerManager() {
		destroy();
	}

	bool initialize() {
		if (deviceInitialized) return true;

		ma_device_config config = ma_device_config_init(ma_device_type_playback);
		config.playback.format = SAMPLE_FORMAT;
		config.playback.channels = CHANNEL_COUNT;
		config.sampleRate = SAMPLE_RATE;
		config.dataCallback = audioCallback;
		config.pUserData = this;

		if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS) {
			printf("Failed to initialize audio mixer device\n");
			return false;
		}

		deviceInitialized = true;

		// Start device immediately
		ma_device_start(&device);

		return true;
	}

	void destroy() {
		if (deviceInitialized) {
			ma_device_uninit(&device);
			deviceInitialized = false;
		}

		std::lock_guard<std::mutex> lock(mixerMutex);
		backgroundTracks.clear();
		soundEffectPools.clear();
		backgroundTrackMap.clear();
		soundEffectMap.clear();
	}

	////////////////////////////////////////////////////////////////
	// Background Track API (unchanged)
	////////////////////////////////////////////////////////////////

	int loadBackgroundTrack(const char* path) {
		if (!deviceInitialized) {
			if (!initialize()) return -1;
		}

		std::lock_guard<std::mutex> lock(mixerMutex);

		// Check if already loaded
		std::string key = path;
		auto it = backgroundTrackMap.find(key);
		if (it != backgroundTrackMap.end()) {
			// Already loaded, return existing index
			return it->second;
		}

		BackgroundTrack track;
		if (!track.load(path)) {
			return -1;
		}

		int index = (int)backgroundTracks.size();
		backgroundTracks.push_back(std::move(track));
		backgroundTrackMap[key] = index;
		return index;
	}

	int findBackgroundTrack(const char* path) {
		std::lock_guard<std::mutex> lock(mixerMutex);
		std::string key = path;
		auto it = backgroundTrackMap.find(key);
		if (it != backgroundTrackMap.end()) {
			return it->second;
		}
		return -1; // Not found
	}

	bool isBackgroundTrackLoaded(const char* path) {
		return findBackgroundTrack(path) >= 0;
	}

	void playBackgroundTrack(int index) {
		if (index < 0 || index >= (int)backgroundTracks.size()) return;
		backgroundTracks[index].play();
	}

	void stopBackgroundTrack(int index) {
		if (index < 0 || index >= (int)backgroundTracks.size()) return;
		backgroundTracks[index].stop();
	}

	void setBackgroundTrackVolume(int index, float volume) {
		if (index < 0 || index >= (int)backgroundTracks.size()) return;
		backgroundTracks[index].setVolume(volume);
	}

	void setBackgroundTrackLooping(int index, bool looping) {
		if (index < 0 || index >= (int)backgroundTracks.size()) return;
		backgroundTracks[index].setLooping(looping);
	}

	bool isBackgroundTrackPlaying(int index) {
		if (index < 0 || index >= (int)backgroundTracks.size()) return false;
		return backgroundTracks[index].active;
	}

	////////////////////////////////////////////////////////////////
	// Sound Effect API (UPDATED for overlapping sounds)
	////////////////////////////////////////////////////////////////

	int loadSoundEffect(const char* path) {
		if (!deviceInitialized) {
			if (!initialize()) return -1;
		}

		std::lock_guard<std::mutex> lock(mixerMutex);

		// Check if already loaded
		std::string key = path;
		auto it = soundEffectMap.find(key);
		if (it != soundEffectMap.end()) {
			// Already loaded, return existing index
			return it->second;
		}

		SoundEffectPool pool;
		if (!pool.load(path)) {
			return -1;
		}

		int index = (int)soundEffectPools.size();
		soundEffectPools.push_back(std::move(pool));
		soundEffectMap[key] = index;
		return index;
	}

	int findSoundEffect(const char* path) {
		std::lock_guard<std::mutex> lock(mixerMutex);
		std::string key = path;
		auto it = soundEffectMap.find(key);
		if (it != soundEffectMap.end()) {
			return it->second;
		}
		return -1; // Not found
	}

	bool isSoundEffectLoaded(const char* path) {
		return findSoundEffect(path) >= 0;
	}

	// Play a sound effect (can overlap with itself)
	void playSoundEffect(int index, float volume = 1.0f) {
		if (index < 0 || index >= (int)soundEffectPools.size()) return;
		soundEffectPools[index].play(volume);
	}

	// Convenience method to play sound effect by path
	void playSoundEffect(const char* path, float volume = 1.0f) {
		int index = findSoundEffect(path);
		if (index < 0) {
			index = loadSoundEffect(path);
			if (index < 0) return;
		}
		playSoundEffect(index, volume);
	}

	// Stop all instances of a sound effect
	void stopSoundEffect(int index) {
		if (index < 0 || index >= (int)soundEffectPools.size()) return;
		soundEffectPools[index].stopAll();
	}

	// Check if any instance of a sound effect is playing
	bool isSoundEffectPlaying(int index) {
		if (index < 0 || index >= (int)soundEffectPools.size()) return false;
		return soundEffectPools[index].isAnyPlaying();
	}

	// Get number of currently playing instances
	int getSoundEffectPlayingCount(int index) {
		if (index < 0 || index >= (int)soundEffectPools.size()) return 0;
		return soundEffectPools[index].getPlayingCount();
	}

	////////////////////////////////////////////////////////////////
	// Cleanup and Management
	////////////////////////////////////////////////////////////////

	void unloadBackgroundTrack(int index) {
		std::lock_guard<std::mutex> lock(mixerMutex);
		if (index < 0 || index >= (int)backgroundTracks.size()) return;

		// Remove from map
		for (auto it = backgroundTrackMap.begin(); it != backgroundTrackMap.end(); ) {
			if (it->second == index) {
				it = backgroundTrackMap.erase(it);
			} else {
				// Adjust indices for entries after the removed one
				if (it->second > index) {
					it->second--;
				}
				++it;
			}
		}

		// Remove from vector
		backgroundTracks.erase(backgroundTracks.begin() + index);
	}

	void unloadSoundEffect(int index) {
		std::lock_guard<std::mutex> lock(mixerMutex);
		if (index < 0 || index >= (int)soundEffectPools.size()) return;

		// Remove from map
		for (auto it = soundEffectMap.begin(); it != soundEffectMap.end(); ) {
			if (it->second == index) {
				it = soundEffectMap.erase(it);
			} else {
				// Adjust indices for entries after the removed one
				if (it->second > index) {
					it->second--;
				}
				++it;
			}
		}

		// Remove from vector
		soundEffectPools.erase(soundEffectPools.begin() + index);
	}

	////////////////////////////////////////////////////////////////
	// Volume Control
	////////////////////////////////////////////////////////////////

	void setMasterVolume(float volume) {
		masterVolume = volume;
	}

	float getMasterVolume() const {
		return masterVolume;
	}

private:
	static void audioCallback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
		AudioMixerManager* mixer = static_cast<AudioMixerManager*>(pDevice->pUserData);
		if (!mixer) return;

		float* output = (float*)pOutput;
		memset(output, 0, sizeof(float) * frameCount * CHANNEL_COUNT);

		std::lock_guard<std::mutex> lock(mixer->mixerMutex);

		// Mix background tracks
		for (auto& track : mixer->backgroundTracks) {
			if (track.active) {
				track.readFrames(output, frameCount, mixer->masterVolume);
			}
		}

		// Mix sound effects (now from pools)
		for (auto& pool : mixer->soundEffectPools) {
			pool.readFrames(output, frameCount, mixer->masterVolume);
		}

		(void)pInput;
	}
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//  - GLOBAL INTERFACE -   //
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

namespace {
	AudioSystem g_audioSystem;
	AudioMixerManager g_mixer;
}

// Original global function interfaces (delegate to AudioSystem)
void loadFiles(std::vector<const char*> argv) {
	g_audioSystem.loadFiles(argv);
}

void start() {
	g_audioSystem.start();
}

void stop() {
	g_audioSystem.stop();
}

bool stopped() {
	return g_audioSystem.stopped();
}

void destroy() {
	g_audioSystem.destroy();
}

void seekToPCMFrame(int64_t pos) {
	g_audioSystem.seekToPCMFrame(pos);
}

int getMixerState() {
	return g_audioSystem.getMixerState();
}

double getPlaybackPosition() {
	return g_audioSystem.getPlaybackPosition();
}

double getDuration() {
	return g_audioSystem.getDuration();
}

void deactivate_decoder(int index) {
	g_audioSystem.deactivate_decoder(index);
}

void amplify_decoder(int index, double volume) {
	g_audioSystem.amplify_decoder(index, volume);
}

void setPlaybackRate(float value) {
	g_audioSystem.setPlaybackRate(value);
}

double getGlobalVolume() {
	return g_audioSystem.getGlobalVolume();
}

double setGlobalVolume(double value) {
	return g_audioSystem.setGlobalVolume(value);
}

bool wearingHeadphones() {
#if HX_WINDOWS
	return checkWindowsHeadphoneStatus();
#else
	return false;
#endif
}

bool wearingPlugNPlay() {
#if HX_WINDOWS
	return checkIfPnPDevice();
#else
	return false;
#endif
}

int detectLatency() {
	#if HX_WINDOWS
	int osMs = 68;
	#else
	int osMs = 1;
	#endif
	if (g_audioSystem.exists) {
		if(!wearingPlugNPlay()) osMs += 50;
		if(wearingHeadphones()) osMs += 25;
		osMs -= g_audioSystem.getLatencyMs();
	}
	return osMs;
}

// Background track functions
int loadBackgroundTrack(const char* path) {
	return g_mixer.loadBackgroundTrack(path);
}

void playBackgroundTrack(int index) {
	g_mixer.playBackgroundTrack(index);
}

void stopBackgroundTrack(int index) {
	g_mixer.stopBackgroundTrack(index);
}

void setBackgroundTrackVolume(int index, float volume) {
	g_mixer.setBackgroundTrackVolume(index, volume);
}

void setBackgroundTrackLooping(int index, bool looping) {
	g_mixer.setBackgroundTrackLooping(index, looping);
}

bool isBackgroundTrackPlaying(int index) {
	return g_mixer.isBackgroundTrackPlaying(index);
}

// Sound effect functions
int loadSoundEffect(const char* path) {
	return g_mixer.loadSoundEffect(path);
}

void playSoundEffect(int index, float volume) {
	g_mixer.playSoundEffect(index, volume);
}

void stopSoundEffect(int index) {
	g_mixer.stopSoundEffect(index);
}

bool isSoundEffectPlaying(int index) {
	return g_mixer.isSoundEffectPlaying(index);
}

// Volume control
void setMixerMasterVolume(float volume) {
	g_mixer.setMasterVolume(volume);
}

float getMixerMasterVolume() {
	return g_mixer.getMasterVolume();
}

void destroyMixer() {
	g_mixer.destroy();
}
