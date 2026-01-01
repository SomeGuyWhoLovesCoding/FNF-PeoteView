/*
 * Fixed double-buffered sliding window with clean shutdown.
 * RAII implementation - Resources manage their own lifetimes

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

/*// Use stb_vorbis instead of libvorbis - it's header-only!
//#define STB_VORBIS_HEADER_ONLY
#include "extras/stb_vorbis.c"    // miniaudio includes this*/

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

//#include "extras/miniaudio_libvorbis.h"
//#include "extras/decoders/libopus/miniaudio_libopus.c"

#define SAMPLE_FORMAT ma_format_f32
#define CHANNEL_COUNT 2
#define SAMPLE_RATE 44100

/*ma_decoding_backend_vtable* pCustomBackendVTables[] =
{
	ma_decoding_backend_libvorbis,
	ma_decoding_backend_libopus
};*/

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//	- MUSIC TRACK -	//
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Buffer constants (exactly as specified)
#define PADDING_MS 100
#define BUFFER_MS 2000
#define HALF_BUFFER_MS 900
// to reduce underrun, I set HALF_BUFFER_MS to 900 instead of 1000 for certain codecs just being slow in general to decode to raw pcm.
// This is also the sweet spot inbetween it because if you go mildly lower than that then you'll end up with early buffer termination.

#define PADDING_FRAMES ((SAMPLE_RATE * PADDING_MS) / 1000)        // 4410 frames
#define BUFFER_FRAMES ((SAMPLE_RATE * BUFFER_MS) / 1000)          // 88200 frames
#define HALF_BUFFER_FRAMES ((SAMPLE_RATE * HALF_BUFFER_MS) / 1000) // 44100 frames
#define TOTAL_BUFFER_FRAMES (PADDING_FRAMES + BUFFER_FRAMES + PADDING_FRAMES) // 96620 frames

// Async refill request
struct RefillRequest {
	int decoderIndex;
	ma_uint64 targetPosition;
	float* bufferToFill;
};

// Double-buffered decoder stream with RAII
struct DecoderStream {
	float* pcmBufferA = nullptr;     // First buffer
	float* pcmBufferB = nullptr;     // Second buffer
	float* activeBuffer = nullptr;   // Currently playing buffer

	ma_uint64 filePosition = 0;      // Current position in the source file (in frames)
	ma_uint64 bufferStartPos = 0;    // File position that maps to start of active buffer
	ma_uint64 localReadPos = 0;      // Read position within active buffer (0 to TOTAL_BUFFER_FRAMES)
	ma_uint64 validFrames = 0;       // How many frames in active buffer are valid

	bool active = false;

	ma_decoder decoder;
	ma_uint64 decoderLength = 0;

	// Async loading
	std::atomic<bool> asyncLoading{false};
	std::atomic<bool> asyncReady{false};
	float* asyncBuffer = nullptr;
	ma_uint64 asyncStartPos = 0;
	ma_uint64 asyncValidFrames = 0;

	// Constructor
	DecoderStream() {
		// Initialize decoder to a known state
		memset(&decoder, 0, sizeof(ma_decoder));
	}

	// Destructor - RAII cleanup
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

private:
	void cleanup() {
		// Uninitialize decoder if it was initialized
		if (decoder.onRead != nullptr || decoder.onSeek != nullptr) {
			ma_decoder_uninit(&decoder);
		}

		// Free buffers
		if (pcmBufferA) {
			free(pcmBufferA);
			pcmBufferA = nullptr;
		}
		if (pcmBufferB) {
			free(pcmBufferB);
			pcmBufferB = nullptr;
		}

		// Reset state
		activeBuffer = nullptr;
		asyncBuffer = nullptr;
		filePosition = 0;
		bufferStartPos = 0;
		localReadPos = 0;
		validFrames = 0;
		active = false;
		decoderLength = 0;
		asyncStartPos = 0;
		asyncValidFrames = 0;
		asyncLoading = false;
		asyncReady = false;
	}

	void moveFrom(DecoderStream&& other) noexcept {
		// Move resources
		pcmBufferA = other.pcmBufferA;
		pcmBufferB = other.pcmBufferB;
		activeBuffer = other.activeBuffer;
		asyncBuffer = other.asyncBuffer;

		// Move decoder
		memcpy(&decoder, &other.decoder, sizeof(ma_decoder));

		// Move scalar values
		filePosition = other.filePosition;
		bufferStartPos = other.bufferStartPos;
		localReadPos = other.localReadPos;
		validFrames = other.validFrames;
		active = other.active;
		decoderLength = other.decoderLength;
		asyncStartPos = other.asyncStartPos;
		asyncValidFrames = other.asyncValidFrames;

		// Move atomic values
		asyncLoading.store(other.asyncLoading.load());
		asyncReady.store(other.asyncReady.load());

		// Clear source to prevent double-free
		other.pcmBufferA = nullptr;
		other.pcmBufferB = nullptr;
		other.activeBuffer = nullptr;
		other.asyncBuffer = nullptr;
		memset(&other.decoder, 0, sizeof(ma_decoder));
		other.filePosition = 0;
		other.bufferStartPos = 0;
		other.localReadPos = 0;
		other.validFrames = 0;
		other.active = false;
		other.decoderLength = 0;
		other.asyncStartPos = 0;
		other.asyncValidFrames = 0;
		other.asyncLoading = false;
		other.asyncReady = false;
	}
};

// RAII wrapper for signalsmith stretch
class SignalsmithStretchWrapper {
public:
	signalsmith::stretch::SignalsmithStretch* ptr = nullptr;

	SignalsmithStretchWrapper() = default;

	~SignalsmithStretchWrapper() {
		cleanup();
	}

	// Move operations
	SignalsmithStretchWrapper(SignalsmithStretchWrapper&& other) noexcept {
		ptr = other.ptr;
		other.ptr = nullptr;
	}

	SignalsmithStretchWrapper& operator=(SignalsmithStretchWrapper&& other) noexcept {
		if (this != &other) {
			cleanup();
			ptr = other.ptr;
			other.ptr = nullptr;
		}
		return *this;
	}

	// Delete copy operations
	SignalsmithStretchWrapper(const SignalsmithStretchWrapper&) = delete;
	SignalsmithStretchWrapper& operator=(const SignalsmithStretchWrapper&) = delete;

	// Operator overloads for convenience
	signalsmith::stretch::SignalsmithStretch* operator->() { return ptr; }
	const signalsmith::stretch::SignalsmithStretch* operator->() const { return ptr; }
	signalsmith::stretch::SignalsmithStretch& operator*() { return *ptr; }
	const signalsmith::stretch::SignalsmithStretch& operator*() const { return *ptr; }
	operator bool() const { return ptr != nullptr; }

	void create() {
		if (!ptr) {
			ptr = new signalsmith::stretch::SignalsmithStretch();
		}
	}

private:
	void cleanup() {
		if (ptr) {
			delete ptr;
			ptr = nullptr;
		}
	}
};

// RAII wrapper for miniaudio device
class AudioDevice {
public:
	ma_device device;
	bool initialized = false;

	AudioDevice() {
		memset(&device, 0, sizeof(ma_device));
	}

	~AudioDevice() {
		cleanup();
	}

	// Move operations
	AudioDevice(AudioDevice&& other) noexcept {
		memcpy(&device, &other.device, sizeof(ma_device));
		initialized = other.initialized;
		memset(&other.device, 0, sizeof(ma_device));
		other.initialized = false;
	}

	AudioDevice& operator=(AudioDevice&& other) noexcept {
		if (this != &other) {
			cleanup();
			memcpy(&device, &other.device, sizeof(ma_device));
			initialized = other.initialized;
			memset(&other.device, 0, sizeof(ma_device));
			other.initialized = false;
		}
		return *this;
	}

	// Delete copy operations
	AudioDevice(const AudioDevice&) = delete;
	AudioDevice& operator=(const AudioDevice&) = delete;

	bool init(const ma_device_config* pConfig) {
		cleanup();
		ma_result result = ma_device_init(nullptr, pConfig, &device);
		initialized = (result == MA_SUCCESS);
		return initialized;
	}

	void uninit() {
		if (initialized) {
			ma_device_uninit(&device);
			memset(&device, 0, sizeof(ma_device));
			initialized = false;
		}
	}

	ma_result start() {
		return ma_device_start(&device);
	}

	void stop() {
		if (initialized) {
			ma_device_stop(&device);
		}
	}

	operator bool() const { return initialized; }

private:
	void cleanup() {
		uninit();
	}
};

// RAII wrapper for mutex
class AudioMutex {
public:
	ma_mutex mutex;
	bool initialized = false;

	AudioMutex() {
		memset(&mutex, 0, sizeof(ma_mutex));
	}

	~AudioMutex() {
		cleanup();
	}

	// Move operations
	AudioMutex(AudioMutex&& other) noexcept {
		memcpy(&mutex, &other.mutex, sizeof(ma_mutex));
		initialized = other.initialized;
		memset(&other.mutex, 0, sizeof(ma_mutex));
		other.initialized = false;
	}

	AudioMutex& operator=(AudioMutex&& other) noexcept {
		if (this != &other) {
			cleanup();
			memcpy(&mutex, &other.mutex, sizeof(ma_mutex));
			initialized = other.initialized;
			memset(&other.mutex, 0, sizeof(ma_mutex));
			other.initialized = false;
		}
		return *this;
	}

	// Delete copy operations
	AudioMutex(const AudioMutex&) = delete;
	AudioMutex& operator=(const AudioMutex&) = delete;

	bool init() {
		if (!initialized) {
			ma_result result = ma_mutex_init(&mutex);
			initialized = (result == MA_SUCCESS);
		}
		return initialized;
	}

	void lock() {
		if (initialized) ma_mutex_lock(&mutex);
	}

	void unlock() {
		if (initialized) ma_mutex_unlock(&mutex);
	}

	operator bool() const { return initialized; }

private:
	void cleanup() {
		if (initialized) {
			ma_mutex_uninit(&mutex);
			initialized = false;
		}
	}
};

// Main audio system manager with RAII
class AudioSystem {
public:
	// RAII-managed resources
	std::vector<DecoderStream> streams;
	std::vector<float> decoderVolumes;
	std::vector<std::string> filePaths;

	AudioDevice device;
	AudioMutex audioMutex;
	SignalsmithStretchWrapper stretch;

	// Refill thread management
	std::thread refillThread;
	std::atomic<bool> refillThreadRunning{false};
	std::mutex refillMutex;
	std::condition_variable refillCV;
	std::queue<RefillRequest> refillQueue;
	std::atomic<int> activeRefillJobs{0};

	// State variables
	int longestDecoderIndex = 0;
	float playbackRate = 1.0f;
	double masterVolume = 1.0;
	int mixerState = 3;
	bool exists = false;
	std::atomic<bool> deviceChanging{false};

	// Latency detection
	ma_uint64 detectedLatency = 0; // System-wide latency in frames (max across all decoders)
	bool latenciesDetected = false;
	static constexpr float SILENCE_THRESHOLD = 0.1f; // This was 20% but I realized it was too much and it would output more delay than expected so I'd say I leave it at 10%.

	AudioSystem() = default;

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

	// Public interface methods
	void loadFiles(std::vector<const char*> argv) {
		if(argv.empty()){
			printf("No input files.\n");
			return;
		}

		// Clean up existing resources
		destroy();

		// Store file paths
		filePaths.clear();
		for (size_t i = 0; i < argv.size(); i++) {
			filePaths.push_back(argv[i]);
		}

		// Initialize streams
		streams.resize(argv.size());
		decoderVolumes.resize(argv.size(), 1.0f);

		ma_uint64 absoluteLengthOfSong = 0;
		ma_decoder_config decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

		for(size_t i = 0; i < argv.size(); i++) {
			const char* path = argv[i];
			DecoderStream& s = streams[i];

			// Initialize decoder
			ma_result result = ma_decoder_init_file(path, &decoderConfig, &s.decoder);
			if(result != MA_SUCCESS){
				// Cleanup already initialized decoders
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

			// Allocate double buffers
			s.pcmBufferA = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
			s.pcmBufferB = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
			memset(s.pcmBufferA, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
			memset(s.pcmBufferB, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);

			// Initialize atomic flags
			s.asyncLoading = false;
			s.asyncReady = false;

			// Detect latency for this decoder and keep track of maximum
			ma_uint64 thisLatency = detectLatency(i);
			if (thisLatency > detectedLatency) {
				detectedLatency = thisLatency;
			}

			// Fill initial buffer (starts at 0)
			fillInitialBuffer(i, 0);

			if(s.decoderLength > absoluteLengthOfSong){
				absoluteLengthOfSong = s.decoderLength;
				longestDecoderIndex = (int)i;
			}
		}

		latenciesDetected = true;

		// Initialize audio device
		ma_device_config deviceConfig = ma_device_config_init(ma_device_type_playback);
		deviceConfig.playback.format = SAMPLE_FORMAT;
		deviceConfig.playback.channels = CHANNEL_COUNT;
		deviceConfig.sampleRate = SAMPLE_RATE;
		deviceConfig.dataCallback = data_callback;
		deviceConfig.pUserData = this;
		deviceConfig.periodSizeInFrames = 256;
		deviceConfig.periods = 2;

		if(!device.init(&deviceConfig)){
			streams.clear();
			decoderVolumes.clear();
			filePaths.clear();
			printf("Failed to open playback device.\n");
			return;
		}

		// Initialize mutex
		audioMutex.init();

		exists = true;
		mixerState = 3;
	}

	// Detect latency by scanning for first sample above threshold
	ma_uint64 detectLatency(size_t index) {
		DecoderStream& s = streams[index];
		
		// Create temporary buffer for scanning
		const ma_uint64 SCAN_CHUNK_SIZE = 4096;
		float* scanBuffer = (float*)malloc(sizeof(float) * SCAN_CHUNK_SIZE * CHANNEL_COUNT);
		
		if (!scanBuffer) return 0;
		
		// Reset decoder to start
		ma_decoder_seek_to_pcm_frame(&s.decoder, 0);
		
		ma_uint64 totalFramesScanned = 0;
		ma_uint64 latencyFrames = 0;
		bool foundSignal = false;
		
		// Scan up to 1 second of audio (or end of file)
		ma_uint64 maxFramesToScan = SAMPLE_RATE * 1;
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
			
			// Check each frame for signal above threshold
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
		
		// Reset decoder back to start
		ma_decoder_seek_to_pcm_frame(&s.decoder, 0);
		
		return latencyFrames;
	}

	// Get detected latency in milliseconds (max across all decoders)
	double getLatencyMs() const {
		return (double)detectedLatency / (SAMPLE_RATE * 0.001);
	}

	// Get detected latency in frames (max across all decoders)
	ma_uint64 getLatencyFrames() const {
		return detectedLatency;
	}

	void destroy() {
		if(!exists) return;
		exists = false;
		deviceChanging = true;

		// Stop audio device first
		device.stop();

		// Stop refill thread
		stopRefillThread();

		// Uninitialize device
		device.uninit();

		// Clean up decoders and buffers (handled by RAII destructors)
		streams.clear();
		decoderVolumes.clear();
		filePaths.clear();

		// Reset state
		longestDecoderIndex = 0;
		playbackRate = 1.0f;
		masterVolume = 1.0;
		mixerState = 3;
		latenciesDetected = false;
		detectedLatency = 0;
		deviceChanging = false;
	}

	void start() {
		if(!exists) return;
		if(mixerState == 3) seekToPCMFrame(0);
		device.start();
		startRefillThread();
	}

	void stop() {
		if(!exists) return;
		bool wasPlaying = (mixerState == 1);
		device.stop();
		stopRefillThread();
		// Only set to stopped state if we were actually playing
		// This prevents premature termination during device switching
		if(wasPlaying) {
			mixerState = 2;
		}
	}

	bool stopped() const {
		return mixerState == 3;
	}

	void seekToPCMFrame(int64_t pos) {
		if(!exists) return;

		audioMutex.lock();

		// Clear refill queue
		{
			std::lock_guard<std::mutex> lock(refillMutex);
			while (!refillQueue.empty()) refillQueue.pop();
		}

		for(size_t i = 0; i < streams.size(); i++) {
			DecoderStream& s = streams[i];
			ma_uint64 target = 0;
			if(pos <= 0) target = 0;
			else if((ma_uint64)pos >= s.decoderLength) target = s.decoderLength;
			else target = (ma_uint64)pos;

			s.asyncLoading = false;
			s.asyncReady = false;

			fillInitialBuffer(i, target);
		}

		audioMutex.unlock();
		mixerState = (pos < (int64_t)streams[longestDecoderIndex].decoderLength) ? 2 : 3;
	}

	// Helper methods
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

	double setGlobalVolume(double value) {
		masterVolume = value;
		return masterVolume;
	}

	int getMixerState() const {
		return mixerState;
	}

	double getPlaybackPosition() const {
		if(!audioMutex.initialized) return 0.0;

		AudioMutex& mutexRef = const_cast<AudioMutex&>(audioMutex);
		mutexRef.lock();

		ma_uint64 pos = 0;
		if(!streams.empty() && streams[longestDecoderIndex].active) {
			pos = streams[longestDecoderIndex].filePosition;
		} else if(!streams.empty()) {
			pos = streams[longestDecoderIndex].decoderLength;
		}

		mutexRef.unlock();
		return ((double)pos / (SAMPLE_RATE * 0.001));
	}

	double getDuration() const {
		if(streams.empty()) return 0.0;
		return (double)streams[longestDecoderIndex].decoderLength / (SAMPLE_RATE * 0.001);
	}

	// Fill buffer with data starting at decodeStart
	void fillBuffer(DecoderStream* s, float* buffer, ma_uint64 decodeStart, ma_uint64* framesRead) {
		ma_uint64 maxDecodeFrames = TOTAL_BUFFER_FRAMES;
		if(decodeStart + TOTAL_BUFFER_FRAMES > s->decoderLength) {
			maxDecodeFrames = s->decoderLength - decodeStart;
		}

		memset(buffer, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
		ma_decoder_seek_to_pcm_frame(&s->decoder, decodeStart);

		if(maxDecodeFrames > 0) {
			ma_decoder_read_pcm_frames(&s->decoder, buffer, maxDecodeFrames, framesRead);
		} else {
			*framesRead = 0;
		}
	}

	void fillInitialBuffer(size_t index, ma_uint64 startFrame) {
		DecoderStream* s = &streams[index];

		ma_uint64 decodeStart = 0;
		if(startFrame > PADDING_FRAMES) {
			decodeStart = startFrame - PADDING_FRAMES;
		}

		ma_uint64 framesRead = 0;
		fillBuffer(s, s->pcmBufferA, decodeStart, &framesRead);

		s->activeBuffer = s->pcmBufferA;
		s->bufferStartPos = decodeStart;
		s->validFrames = framesRead;
		s->asyncLoading = false;
		s->asyncReady = false;
		s->asyncBuffer = s->pcmBufferB;

		if(startFrame >= decodeStart) {
			s->localReadPos = startFrame - decodeStart;
		} else {
			s->localReadPos = 0;
		}

		if(s->localReadPos >= TOTAL_BUFFER_FRAMES) {
			s->localReadPos = TOTAL_BUFFER_FRAMES - 1;
		}

		s->filePosition = startFrame;
		s->active = (startFrame < s->decoderLength && framesRead > 0);

		if (s->active) {
			ma_uint64 futurePosition = startFrame + HALF_BUFFER_FRAMES;
			ma_uint64 nextBufferStart = 0;
			if (futurePosition > PADDING_FRAMES) {
				nextBufferStart = futurePosition - PADDING_FRAMES;
			}

			if (nextBufferStart < s->decoderLength) {
				s->asyncLoading = true;

				RefillRequest request;
				request.decoderIndex = (int)index;
				request.targetPosition = nextBufferStart;
				request.bufferToFill = s->asyncBuffer;

				{
					std::lock_guard<std::mutex> lock(refillMutex);
					refillQueue.push(request);
					refillCV.notify_one();
				}
			}
		}
	}

	bool shouldSwitchBuffer(const DecoderStream* s) {
		ma_uint64 audioProgress = s->localReadPos;
		return audioProgress >= (PADDING_FRAMES + (BUFFER_FRAMES * 3 / 4));
	}

	bool trySwitchBuffer(DecoderStream* s, size_t index) {
		if (s->asyncReady && s->asyncValidFrames > 0) {
			ma_uint64 currentPos = s->filePosition;
			ma_uint64 expectedBufferStart = 0;
			if (currentPos > PADDING_FRAMES) {
				expectedBufferStart = currentPos - PADDING_FRAMES;
			}

			ma_int64 positionDiff = (ma_int64)s->asyncStartPos - (ma_int64)expectedBufferStart;
			if (positionDiff > (ma_int64)HALF_BUFFER_FRAMES || positionDiff < -(ma_int64)HALF_BUFFER_FRAMES) {
				s->asyncReady = false;
				s->asyncValidFrames = 0;
				return false;
			}

			float* temp = s->activeBuffer;
			s->activeBuffer = s->asyncBuffer;
			s->asyncBuffer = temp;

			s->bufferStartPos = s->asyncStartPos;
			s->validFrames = s->asyncValidFrames;

			if (s->filePosition >= s->asyncStartPos) {
				s->localReadPos = s->filePosition - s->asyncStartPos;
			} else {
				s->localReadPos = 0;
			}

			if(s->localReadPos >= TOTAL_BUFFER_FRAMES) {
				s->localReadPos = TOTAL_BUFFER_FRAMES - 1;
			}
			if(s->localReadPos > s->validFrames) {
				s->localReadPos = s->validFrames;
			}

			s->asyncReady = false;
			s->asyncValidFrames = 0;

			ma_uint64 futurePosition = s->filePosition + HALF_BUFFER_FRAMES;
			ma_uint64 nextBufferStart = 0;
			if (futurePosition > PADDING_FRAMES) {
				nextBufferStart = futurePosition - PADDING_FRAMES;
			}

			if (nextBufferStart < s->decoderLength) {
				s->asyncLoading = true;

				RefillRequest request;
				request.decoderIndex = (int)index;
				request.targetPosition = nextBufferStart;
				request.bufferToFill = s->asyncBuffer;

				{
					std::lock_guard<std::mutex> lock(refillMutex);
					refillQueue.push(request);
					refillCV.notify_one();
				}
			}

			return true;
		}
		return false;
	}

	void refillWorkerThread() {
		while (refillThreadRunning) {
			RefillRequest request;

			{
				std::unique_lock<std::mutex> lock(refillMutex);
				refillCV.wait_for(lock, std::chrono::milliseconds(10), [this]() {
					return !refillQueue.empty() || !refillThreadRunning;
				});

				if (!refillThreadRunning) break;
				if (refillQueue.empty()) continue;

				request = refillQueue.front();
				refillQueue.pop();
				activeRefillJobs++;
			}

			if (request.decoderIndex < 0 || request.decoderIndex >= (int)streams.size()) {
				activeRefillJobs--;
				continue;
			}

			DecoderStream* stream = &streams[request.decoderIndex];

			if (request.targetPosition >= stream->decoderLength) {
				stream->asyncLoading = false;
				activeRefillJobs--;
				continue;
			}

			ma_uint64 maxFrames = TOTAL_BUFFER_FRAMES;
			if (request.targetPosition + TOTAL_BUFFER_FRAMES > stream->decoderLength) {
				maxFrames = stream->decoderLength - request.targetPosition;
			}

			if (maxFrames == 0) {
				stream->asyncLoading = false;
				activeRefillJobs--;
				continue;
			}

			memset(request.bufferToFill, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));

			ma_decoder tempDecoder;
			ma_decoder_config decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

			const char* path = filePaths[request.decoderIndex].c_str();

			if (ma_decoder_init_file(path, &decoderConfig, &tempDecoder) == MA_SUCCESS) {
				ma_decoder_seek_to_pcm_frame(&tempDecoder, request.targetPosition);

				ma_uint64 framesRead = 0;
				ma_decoder_read_pcm_frames(&tempDecoder, request.bufferToFill, maxFrames, &framesRead);

				stream->asyncStartPos = request.targetPosition;
				stream->asyncValidFrames = framesRead;
				stream->asyncReady = true;
				stream->asyncLoading = false;

				ma_decoder_uninit(&tempDecoder);
			} else {
				stream->asyncLoading = false;
			}

			activeRefillJobs--;
		}
	}

	void startRefillThread() {
		if (refillThreadRunning) return;
		refillThreadRunning = true;
		refillThread = std::thread(&AudioSystem::refillWorkerThread, this);
	}

	void stopRefillThread() {
		if (!refillThreadRunning) return;

		refillThreadRunning = false;

		{
			std::lock_guard<std::mutex> lock(refillMutex);
			while (!refillQueue.empty()) refillQueue.pop();
		}

		refillCV.notify_all();

		if (refillThread.joinable()) {
			auto start = std::chrono::steady_clock::now();
			while (activeRefillJobs > 0 &&
				   std::chrono::steady_clock::now() - start < std::chrono::milliseconds(100)) {
				std::this_thread::sleep_for(std::chrono::milliseconds(1));
			}

			refillThread.join();
		}
	}

	ma_uint32 readFromBufferAsync(size_t index, float* output, ma_uint32 frameCount) {
		DecoderStream* s = &streams[index];

		if(!s->active) return 0;

		if (shouldSwitchBuffer(s)) {
			trySwitchBuffer(s, index);
		}

		ma_uint32 framesRead = 0;

		while(framesRead < frameCount && s->active) {
			if(s->localReadPos >= s->validFrames) {
				s->active = false;
				break;
			}

			ma_uint64 available = s->validFrames - s->localReadPos;
			if(available == 0) {
				s->active = false;
				break;
			}

			ma_uint64 remainingInFile = s->decoderLength - s->filePosition;
			if(remainingInFile < available) {
				available = remainingInFile;
			}

			ma_uint32 toRead = (ma_uint32)available;
			if(toRead > (frameCount - framesRead)) {
				toRead = frameCount - framesRead;
			}

			if(s->localReadPos + toRead > s->validFrames) {
				toRead = (ma_uint32)(s->validFrames - s->localReadPos);
			}

			if(toRead == 0) {
				s->active = false;
				break;
			}

			float* src = s->activeBuffer + (s->localReadPos * CHANNEL_COUNT);
			float vol = decoderVolumes[index] * masterVolume;

			for(ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
				output[framesRead * CHANNEL_COUNT + i] += src[i] * vol;
			}

			s->localReadPos += toRead;
			s->filePosition += toRead;
			framesRead += toRead;

			if(s->filePosition >= s->decoderLength) {
				s->active = false;
				break;
			}
		}

		return framesRead;
	}

	bool any_active() const {
		for(const auto& stream : streams) {
			if(stream.active) return true;
		}
		return false;
	}

	static void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
		AudioSystem* system = static_cast<AudioSystem*>(pDevice->pUserData);
		if (!system) return;

		float* pOutputF32 = (float*)pOutput;
		MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);

		system->audioMutex.lock();

		// If device is changing, output silence and don't modify state
		if(system->deviceChanging) {
			memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
			system->audioMutex.unlock();
			(void)pInput;
			return;
		}

		if(!system->any_active()){
			memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
			system->mixerState = 3;
			system->audioMutex.unlock();
			(void)pInput;
			return;
		}

		if(system->playbackRate == 1.0f){
			memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
			for(size_t i = 0; i < system->streams.size(); i++){
				if(!system->streams[i].active) continue;
				ma_uint32 read = system->readFromBufferAsync(i, pOutputF32, frameCount);
				if(read == 0) system->streams[i].active = false;
			}
		} else {
			float inputMix[4096*CHANNEL_COUNT] = {0};
			float stretchedOutput[4096*CHANNEL_COUNT] = {0};
			ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * system->playbackRate);
			if(maxFramesToRead > 4096) maxFramesToRead = 4096;

			for(size_t i = 0; i < system->streams.size(); i++){
				if(!system->streams[i].active) continue;
				ma_uint32 read = system->readFromBufferAsync(i, inputMix, maxFramesToRead);
				if(read == 0) system->streams[i].active = false;
			}

			if(system->any_active()){
				if(!system->stretch){
					system->stretch.create();
					system->stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
				}
				system->stretch->process(inputMix, maxFramesToRead, stretchedOutput, frameCount);
				memcpy(pOutputF32, stretchedOutput, sizeof(float)*frameCount*CHANNEL_COUNT);
			} else {
				memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
			}
		}

		system->mixerState = system->any_active() ? 1 : 3;
		system->audioMutex.unlock();
		(void)pInput;
	}

private:
	void moveFrom(AudioSystem&& other) noexcept {
		streams = std::move(other.streams);
		decoderVolumes = std::move(other.decoderVolumes);
		filePaths = std::move(other.filePaths);
		device = std::move(other.device);
		audioMutex = std::move(other.audioMutex);
		stretch = std::move(other.stretch);

		refillThread = std::move(other.refillThread);
		refillThreadRunning.store(other.refillThreadRunning.load());
		refillQueue = std::move(other.refillQueue);
		activeRefillJobs.store(other.activeRefillJobs.load());

		longestDecoderIndex = other.longestDecoderIndex;
		playbackRate = other.playbackRate;
		masterVolume = other.masterVolume;
		mixerState = other.mixerState;
		exists = other.exists;
		latenciesDetected = other.latenciesDetected;
		detectedLatency = other.detectedLatency;
		deviceChanging.store(other.deviceChanging.load());

		other.longestDecoderIndex = 0;
		other.playbackRate = 1.0f;
		other.masterVolume = 1.0;
		other.mixerState = 3;
		other.exists = false;
		other.refillThreadRunning = false;
		other.activeRefillJobs = 0;
		other.latenciesDetected = false;
		other.detectedLatency = 0;
		other.deviceChanging = false;
	}
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//	- BG TRACK -	//
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
		//config.ppCustomBackendVTables = pCustomBackendVTables;
		//config.customBackendCount     = sizeof(pCustomBackendVTables) / sizeof(pCustomBackendVTables[0]);

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
																				//	- SHORT SOUND -	//
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Sound effect structure - fully loaded in memory for instant playback
struct SoundEffect {
	float* pcmData;
	ma_uint64 frameCount;
	std::atomic<ma_uint64> playbackPosition;
	float volume;
	std::atomic<bool> playing;
	std::string name;

	SoundEffect() : pcmData(nullptr), frameCount(0), playbackPosition(0), volume(1.0f), playing(false) {}

	~SoundEffect() {
		cleanup();
	}

	// Move constructor
	SoundEffect(SoundEffect&& other) noexcept
		: pcmData(other.pcmData),
		  frameCount(other.frameCount),
		  playbackPosition(other.playbackPosition.load()),
		  volume(other.volume),
		  playing(other.playing.load()),
		  name(std::move(other.name)) {
		other.pcmData = nullptr;
		other.frameCount = 0;
		other.playbackPosition = 0;
		other.volume = 1.0f;
		other.playing = false;
	}

	// Move assignment
	SoundEffect& operator=(SoundEffect&& other) noexcept {
		if (this != &other) {
			cleanup();
			pcmData = other.pcmData;
			frameCount = other.frameCount;
			playbackPosition.store(other.playbackPosition.load());
			volume = other.volume;
			playing.store(other.playing.load());
			name = std::move(other.name);

			other.pcmData = nullptr;
			other.frameCount = 0;
			other.playbackPosition = 0;
			other.volume = 1.0f;
			other.playing = false;
		}
		return *this;
	}

	// Delete copy operations
	SoundEffect(const SoundEffect&) = delete;
	SoundEffect& operator=(const SoundEffect&) = delete;

	void cleanup() {
		if (pcmData) {
			free(pcmData);
			pcmData = nullptr;
		}
		frameCount = 0;
		playbackPosition = 0;
		volume = 1.0f;
		playing = false;
		name.clear();
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

		return true;
	}

	void play(float vol = 1.0f) {
		if (pcmData && frameCount > 0) {
			playbackPosition = 0;
			volume = vol;
			playing = true;
		}
	}

	void stop() {
		playing = false;
		playbackPosition = 0;
	}

	bool isPlaying() const {
		return playing;
	}

	// Read frames with volume applied
	ma_uint64 readFrames(float* output, ma_uint32 frameCount, float masterVolume) {
		if (!playing || !pcmData) return 0;

		ma_uint64 pos = playbackPosition.load();
		ma_uint64 remaining = this->frameCount - pos;

		if (remaining == 0) {
			playing = false;
			return 0;
		}

		ma_uint32 toRead = (ma_uint32)remaining;
		if (toRead > frameCount) toRead = frameCount;

		// Mix into output with volume
		float* src = pcmData + (pos * CHANNEL_COUNT);
		float vol = volume * masterVolume;

		for (ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
			output[i] += src[i] * vol;
		}

		playbackPosition = pos + toRead;

		// Stop if finished
		if (playbackPosition >= this->frameCount) {
			playing = false;
		}

		return toRead;
	}
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//	- MIXER MANAGER -	//
																							/***//////

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

class AudioMixerManager {
private:
    std::vector<BackgroundTrack> backgroundTracks;
    std::vector<SoundEffect> soundEffects;
    std::mutex mixerMutex;

    // Maps to track loaded files
    std::unordered_map<std::string, int> backgroundTrackMap;
    std::unordered_map<std::string, int> soundEffectMap;

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
        config.periodSizeInMilliseconds = 2;

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
            //ma_device_stop(&device);
            ma_device_uninit(&device);
            deviceInitialized = false;
        }

        std::lock_guard<std::mutex> lock(mixerMutex);
        backgroundTracks.clear();
        soundEffects.clear();
        backgroundTrackMap.clear();
        soundEffectMap.clear();
    }

    ////////////////////////////////////////////////////////////////
    // Background Track API
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
    // Sound Effect API
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

        SoundEffect sfx;
        if (!sfx.load(path)) {
            return -1;
        }

        int index = (int)soundEffects.size();
        soundEffects.push_back(std::move(sfx));
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

    void playSoundEffect(int index, float volume = 1.0f) {
        if (index < 0 || index >= (int)soundEffects.size()) return;
        soundEffects[index].play(volume);
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

    void stopSoundEffect(int index) {
        if (index < 0 || index >= (int)soundEffects.size()) return;
        soundEffects[index].stop();
    }

    bool isSoundEffectPlaying(int index) {
        if (index < 0 || index >= (int)soundEffects.size()) return false;
        return soundEffects[index].isPlaying();
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
        if (index < 0 || index >= (int)soundEffects.size()) return;

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
        soundEffects.erase(soundEffects.begin() + index);
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

        // Mix sound effects
        for (auto& sfx : mixer->soundEffects) {
            if (sfx.playing) {
                sfx.readFrames(output, frameCount, mixer->masterVolume);
            }
        }

        (void)pInput;
    }
};

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

																				//////***
																				//	- GLOBAL INTERFACE -	//
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
    int osMs = 50;
	#else
	int osMs = 1;
	#endif
	if (g_audioSystem.exists) {
		if(!wearingPlugNPlay()) osMs += 50;
		if(wearingHeadphones()) osMs += 60;
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