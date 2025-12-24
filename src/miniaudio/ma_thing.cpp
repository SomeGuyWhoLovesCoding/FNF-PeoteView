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
#include <algorithm>
#include <array>
#include <atomic>
#include <thread>
#include <mutex>
#include <chrono>
#include <cstring>
#include <unordered_map>

// Windows-specific headphone detection (if you're on Windows)
#ifdef HX_WINDOWS
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <functiondiscoverykeys_devpkey.h>
#include <locale>
#include <codecvt>
#pragma comment(lib, "ole32.lib")

// Helper function to convert wide string to UTF-8 string
static std::string wstring_to_utf8(const std::wstring& wstr) {
	if (wstr.empty()) return std::string();

	// Use the C++11 codecvt utilities for proper conversion
	std::wstring_convert<std::codecvt_utf8<wchar_t>> converter;
	return converter.to_bytes(wstr);
}

// Helper function to convert wide string to UTF-8 string (alternative method)
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
	HRESULT hr = S_OK;
	bool isHeadphones = false;

	hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	if (FAILED(hr)) {
		return false;
	}

	IMMDeviceEnumerator* pEnumerator = NULL;
	IMMDevice* pDevice = NULL;
	IPropertyStore* pProps = NULL;

	hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
						 __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator);
	if (SUCCEEDED(hr)) {
		hr = pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice);
		if (SUCCEEDED(hr)) {
			hr = pDevice->OpenPropertyStore(STGM_READ, &pProps);
			if (SUCCEEDED(hr)) {
				PROPVARIANT varName;
				PropVariantInit(&varName);

				// Check both device description and friendly name
				const PROPERTYKEY* propertyKeys[] = {&PKEY_Device_DeviceDesc, &PKEY_Device_FriendlyName};

				for (int i = 0; i < 2 && !isHeadphones; ++i) {
					hr = pProps->GetValue(*propertyKeys[i], &varName);
					if (SUCCEEDED(hr) && varName.vt == VT_LPWSTR && varName.pwszVal != nullptr) {
						std::wstring wname(varName.pwszVal);

						// Convert to UTF-8 string
						std::string name = wstring_to_string(wname);

						// Convert to lowercase for case-insensitive comparison
						std::transform(name.begin(), name.end(), name.begin(),
									 [](unsigned char c) { return std::tolower(c); });

						// Check for headphone keywords
						const char* keywords[] = {"headphone", "headset", "earphone", "earbud",
												 "airpod", "bluetooth", "bt", "wireless", "ear piece", "usb audio speakers"};
						for (const char* keyword : keywords) {
							if (name.find(keyword) != std::string::npos) {
								isHeadphones = true;
								break;
							}
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
	HRESULT hr = S_OK;
	bool isPnP = false;

	// Initialize COM for this thread if needed
	hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	bool comInitialized = SUCCEEDED(hr);
	if (hr == RPC_E_CHANGED_MODE) {
		comInitialized = false; // COM was already initialized
	}

	IMMDeviceEnumerator* pEnumerator = NULL;
	IMMDevice* pDevice = NULL;
	IPropertyStore* pProps = NULL;
	LPWSTR pwszDeviceId = NULL;

	hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
						 __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator);
	if (FAILED(hr)) {
		goto cleanup;
	}

	hr = pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice);
	if (FAILED(hr)) {
		goto cleanup;
	}

	// Get the device ID - this is the most reliable way
	hr = pDevice->GetId(&pwszDeviceId);
	if (SUCCEEDED(hr) && pwszDeviceId) {
		std::wstring deviceId(pwszDeviceId);
		std::string deviceIdUtf8 = wstring_to_string(deviceId);
		std::transform(deviceIdUtf8.begin(), deviceIdUtf8.end(), deviceIdUtf8.begin(),
					  [](unsigned char c) { return std::tolower(c); });

		// Check for device path patterns that indicate PnP
		// USB devices: \\?\usb#vid_xxxx&pid_xxxx...
		// Bluetooth: \\?\bth#... or \\?\bthenum#...
		// External/Network: \\?\swd#mmdevapi#...
		// Internal: \\?\hdaudio#...

		const char* pnpPatterns[] = {
			"usb#", "bth#", "bthenum#", "swd#mmdevapi#",
			"bluetooth", "hid#", "uefi"
		};

		const char* internalPatterns[] = {
			"hdaudio#", "intel", "realtek", "amd", "nvidia",
			"high definition audio", "hd audio"
		};

		for (const char* pattern : pnpPatterns) {
			if (deviceIdUtf8.find(pattern) != std::string::npos) {
				isPnP = true;
				break;
			}
		}

		// If not PnP by ID pattern, check for internal patterns
		if (!isPnP) {
			for (const char* pattern : internalPatterns) {
				if (deviceIdUtf8.find(pattern) != std::string::npos) {
					isPnP = false; // Definitely internal
					break;
				}
			}
		}

		CoTaskMemFree(pwszDeviceId);
	}

	// If still undetermined, check device properties
	if (!isPnP) {
		hr = pDevice->OpenPropertyStore(STGM_READ, &pProps);
		if (SUCCEEDED(hr)) {
			PROPVARIANT var;
			PropVariantInit(&var);

			// Check device description/friendly name
			// Try multiple property keys
			const PROPERTYKEY* keysToCheck[] = {
				&PKEY_Device_FriendlyName,
				&PKEY_Device_DeviceDesc,
				&PKEY_DeviceInterface_FriendlyName
			};

			for (int i = 0; i < 3 && !isPnP; i++) {
				PropVariantClear(&var);
				hr = pProps->GetValue(*keysToCheck[i], &var);
				if (SUCCEEDED(hr) && var.vt == VT_LPWSTR && var.pwszVal) {
					std::wstring propValue(var.pwszVal);
					std::string propStr = wstring_to_string(propValue);
					std::transform(propStr.begin(), propStr.end(), propStr.begin(),
								  [](unsigned char c) { return std::tolower(c); });

					// PnP device keywords
					const char* pnpKeywords[] = {
						"usb", "bluetooth", "bt", "wireless",
						"external", "headset", "airpod", "bose",
						"sony", "jbl", "logitech", "hdmi",
						"displayport", "digital audio", "digital output",
						"soundblaster", "audio interface", "dac", "amplifier"
					};

					// Internal speaker keywords (if found, not PnP)
					const char* internalKeywords[] = {
						"speakers", "internal", "built-in", "default",
						"primary", "main", "system", "laptop",
						"desktop", "monitor", "display"
					};

					bool foundInternal = false;
					for (const char* keyword : internalKeywords) {
						if (propStr.find(keyword) != std::string::npos) {
							foundInternal = true;
							break;
						}
					}

					if (!foundInternal) {
						for (const char* keyword : pnpKeywords) {
							if (propStr.find(keyword) != std::string::npos) {
								isPnP = true;
								break;
							}
						}
					}
				}
			}

			PropVariantClear(&var);
			pProps->Release();
		}
	}

cleanup:
	if (pProps) pProps->Release();
	if (pDevice) pDevice->Release();
	if (pEnumerator) pEnumerator->Release();

	if (comInitialized) {
		CoUninitialize();
	}

	// Debug output
	//printf("PnP detection: %s\n", isPnP ? "PnP device" : "Internal device");

	return isPnP;
}
#endif

struct TrieNode {
	std::array<TrieNode*, 26> children;
	bool isEnd;

	TrieNode() : isEnd(false) {
		children.fill(nullptr);
	}

	~TrieNode() {
		for (auto* child : children) {
			delete child;
		}
	}

	static TrieNode* getHeadphoneTrie() {
		static TrieNode* root = nullptr;
		static std::once_flag initFlag;

		std::call_once(initFlag, []() {
			root = new TrieNode();
			const char* keywords[] = {
				"headphone", "headset", "earphone", "earbud",
				"airpod", "bluetooth", "usb audio speakers"
			};

			for (const char* keyword : keywords) {
				TrieNode* node = root;
				for (const char* c = keyword; *c; ++c) {
					int index = *c - 'a';
					if (index < 0 || index >= 26) continue; // Skip non-lowercase letters

					if (!node->children[index]) {
						node->children[index] = new TrieNode();
					}
					node = node->children[index];
				}
				node->isEnd = true;
			}
		});

		return root;
	}
};

/*
For simplicity, this example requires the device to use floating point samples.
*/
#define SAMPLE_FORMAT   ma_format_f32
#define CHANNEL_COUNT   2
#define SAMPLE_RATE     44100

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

ma_uint32   g_decoderCount;
ma_decoder* g_pDecoders;
ma_bool32*  g_pDecodersActive;
ma_uint64*  g_pDecoderLengths;
int         g_pLongestDecoderIndex;
float*      g_pDecodersVolume;
float       playbackRate = 1;
double      masterVolume = 1;

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
ma_device_config  deviceConfig;
ma_device         device;
ma_bool32 deviceExists = MA_FALSE;
ma_uint32         iDecoder;
ma_context gDevicesContext;
ma_bool32 gDevicesContextInitialized = MA_FALSE;

// -------------------- AUTOMATIC HEADPHONE DETECTION WITH DEVICE MONITORING --------------------

// Keep track of the current device ID
static std::string currentDeviceId;
static std::string currentDeviceName;
static std::mutex deviceInfoMutex;

// Device change detection thread
static std::atomic<bool> monitorRunning{false};
static std::thread monitorThread;
static std::atomic<int> deviceChangeCounter{0};
static ma_context monitorContext;
static bool monitorContextInitialized = false;

// Use atomic for thread-safe caching with auto-reset
static std::atomic<int> headphoneCacheState{0}; // 0 = not checked, 1 = checking, 2 = headphones, 3 = not headphones
static std::chrono::steady_clock::time_point lastCheckTime;

// Function to reset headphone cache
static void resetHeadphoneCache() {
	headphoneCacheState.store(0, std::memory_order_release);
}

// Cache for PnP status
static std::atomic<int> pnpCacheState{0}; // 0 = not checked, 1 = checking, 2 = PnP, 3 = not PnP

// Function to reset PnP cache
static void resetPnPCache() {
	pnpCacheState.store(0, std::memory_order_release);
}

// Function to check if using PnP device with caching
bool checkIfUsingPnPDevice() {
	if (exists == 0 || deviceExists == MA_FALSE) {
		return false;
	}

	// Check for device changes
	static int lastChangeCounterPnP = 0;
	if (deviceChangeCounter.load() != lastChangeCounterPnP) {
		lastChangeCounterPnP = deviceChangeCounter.load();
		resetPnPCache();
	}

	int state = pnpCacheState.load(std::memory_order_acquire);
	if (state >= 2) {
		return state == 2;
	}

	// Try to acquire the check lock
	int expected = 0;
	if (!pnpCacheState.compare_exchange_strong(expected, 1,
											   std::memory_order_acq_rel)) {
		// Another thread is checking, wait for result
		while (pnpCacheState.load(std::memory_order_acquire) == 1) {
			std::this_thread::yield();
		}
		state = pnpCacheState.load(std::memory_order_acquire);
		return state == 2;
	}

	bool isPnP = false;

#ifdef HX_WINDOWS
	try {
		isPnP = checkIfPnPDevice();
	} catch (...) {
		isPnP = false;
	}
#else
	// On non-Windows platforms, assume PnP (most modern devices are)
	isPnP = true;
#endif

	pnpCacheState.store(isPnP ? 2 : 3, std::memory_order_release);
	return isPnP;
}

// Function to get current device ID and name
static void updateCurrentDeviceInfo() {
	// Don't try to access device if shutting down
	if (exists == 0 || deviceExists == MA_FALSE) {
		return;
	}

	std::lock_guard<std::mutex> lock(deviceInfoMutex);

	if (deviceExists) {
		// Convert device ID to string
		char idStr[64] = {0};
		snprintf(idStr, sizeof(idStr), "%p", (void*)&device.playback.id);
		currentDeviceId = idStr;

		// Get device name if available
		if (device.playback.name[0] != '\0') {
			currentDeviceName = device.playback.name;
		} else {
			currentDeviceName = "Unknown Device";
		}
	}
}

// Check if device has changed
static bool hasDeviceChanged() {
	static std::string lastDeviceId;
	static std::string lastDeviceName;

	std::lock_guard<std::mutex> lock(deviceInfoMutex);

	if (currentDeviceId != lastDeviceId || currentDeviceName != lastDeviceName) {
		lastDeviceId = currentDeviceId;
		lastDeviceName = currentDeviceName;
		return true;
	}
	return false;
}

// Device monitoring thread function
// Add this helper function to get the current default device ID
#ifdef HX_WINDOWS
static std::string getCurrentDefaultDeviceId() {
	HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	bool comInitialized = SUCCEEDED(hr);
	if (hr == RPC_E_CHANGED_MODE) {
		comInitialized = false;
	}

	std::string deviceId;
	IMMDeviceEnumerator* pEnumerator = nullptr;
	IMMDevice* pDevice = nullptr;
	LPWSTR pwszDeviceId = nullptr;

	hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
						 __uuidof(IMMDeviceEnumerator), (void**)&pEnumerator);
	if (SUCCEEDED(hr)) {
		hr = pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice);
		if (SUCCEEDED(hr)) {
			hr = pDevice->GetId(&pwszDeviceId);
			if (SUCCEEDED(hr) && pwszDeviceId) {
				// Convert to UTF-8
				int size_needed = WideCharToMultiByte(CP_UTF8, 0, pwszDeviceId, -1,
													 nullptr, 0, nullptr, nullptr);
				if (size_needed > 0) {
					deviceId.resize(size_needed - 1);
					WideCharToMultiByte(CP_UTF8, 0, pwszDeviceId, -1,
									   &deviceId[0], size_needed, nullptr, nullptr);
				}
				CoTaskMemFree(pwszDeviceId);
			}
			pDevice->Release();
		}
		pEnumerator->Release();
	}

	if (comInitialized) {
		CoUninitialize();
	}

	return deviceId;
}
#endif

// Update the device monitoring thread
static void deviceMonitorThread() {
#ifdef HX_WINDOWS
	// Initialize COM for this monitoring thread
	HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
	if (FAILED(hr) && hr != RPC_E_CHANGED_MODE) {
		return;
	}
#endif

	ma_result result = ma_context_init(NULL, 0, NULL, &monitorContext);
	if (result != MA_SUCCESS) {
#ifdef HX_WINDOWS
		CoUninitialize();
#endif
		return;
	}
	monitorContextInitialized = true;

	std::string lastDeviceId;
	ma_uint32 lastDeviceCount = 0;

	while (monitorRunning) {
		bool deviceChanged = false;

		// Method 1: Check default device ID (Windows-specific, most reliable)
#ifdef HX_WINDOWS
		std::string currentDeviceId = getCurrentDefaultDeviceId();
		if (!currentDeviceId.empty()) {
			if (lastDeviceId.empty()) {
				lastDeviceId = currentDeviceId;
			} else if (currentDeviceId != lastDeviceId) {
				// Device changed!
				deviceChanged = true;
				lastDeviceId = currentDeviceId;

				// Update device info immediately
				updateCurrentDeviceInfo();
			}
		}
#endif

		// Method 2: Check device count via miniaudio (cross-platform)
		ma_device_info* pPlaybackDeviceInfos = nullptr;
		ma_uint32 playbackDeviceCount = 0;

		result = ma_context_get_devices(&monitorContext, &pPlaybackDeviceInfos,
									   &playbackDeviceCount, NULL, NULL);
		if (result == MA_SUCCESS) {
			if (playbackDeviceCount != lastDeviceCount) {
				deviceChanged = true;
				lastDeviceCount = playbackDeviceCount;
			}
		}

		// If device changed, trigger updates
		if (deviceChanged) {
			deviceChangeCounter++;
			resetHeadphoneCache();
			resetPnPCache();

			// Force an immediate re-check of device status
			updateCurrentDeviceInfo();

			// Debug output
			printf("Device change detected! Counter: %d\n", deviceChangeCounter.load());
		}

		std::this_thread::sleep_for(std::chrono::milliseconds(100)); // Check more frequently
	}

#ifdef HX_WINDOWS
	CoUninitialize();
#endif

	if (monitorContextInitialized) {
		ma_context_uninit(&monitorContext);
		monitorContextInitialized = false;
	}
}

// Start device monitoring
static void startDeviceMonitor() {
	if (!monitorRunning) {
		monitorRunning = true;
		monitorThread = std::thread(deviceMonitorThread);
	}
}

// Stop device monitoring
static void stopDeviceMonitor() {
	if (monitorRunning) {
		monitorRunning = false;
		if (monitorThread.joinable()) {
			monitorThread.join();
		}
	}
}

// Original headphone detection function
bool isHeadphoneDevice(const ma_device_info& deviceInfo) {
	const char* name = deviceInfo.name;
	if (!name) return false;

	TrieNode* trie = TrieNode::getHeadphoneTrie();
	if (!trie) return false; // Safety check

	for (const char* p = name; *p; ++p) {
		TrieNode* node = trie;

		// Try to match from current position
		for (const char* q = p; *q; ++q) {
			char c = (char)std::tolower((unsigned char)*q);
			if (c < 'a' || c > 'z') break;

			int index = c - 'a';
			if (!node->children[index]) break;

			node = node->children[index];
			if (node->isEnd) {
				return true;
			}
		}
	}

	return false;
}

// Enhanced headphone detection with automatic device change detection
bool checkIfUsingHeadphones() {
	// CRITICAL: Don't check if we're shutting down
	if (exists == 0 || deviceExists == MA_FALSE) {
		return false;
	}

	// Check for device changes
	static int lastChangeCounter = 0;
	if (deviceChangeCounter.load() != lastChangeCounter) {
		lastChangeCounter = deviceChangeCounter.load();
		resetHeadphoneCache(); // Force re-check
	}

	// Check if cache is still valid (re-check every 2 seconds)
	auto now = std::chrono::steady_clock::now();
	static auto lastDeviceCheck = now;

	if (now - lastDeviceCheck > std::chrono::seconds(2)) {
		resetHeadphoneCache();
		lastDeviceCheck = now;
	}

	int state = headphoneCacheState.load(std::memory_order_acquire);
	if (state >= 2) {
		return state == 2;
	}

	// Try to acquire the check lock
	int expected = 0;
	if (!headphoneCacheState.compare_exchange_strong(expected, 1,
													 std::memory_order_acq_rel)) {
		// Another thread is checking, wait for result
		while (headphoneCacheState.load(std::memory_order_acquire) == 1) {
			std::this_thread::yield();
		}
		state = headphoneCacheState.load(std::memory_order_acquire);
		return state == 2;
	}

	// We're the thread doing the check
	bool isHeadphones = false;

	try {
		updateCurrentDeviceInfo(); // Ensure we have current device info

		std::lock_guard<std::mutex> lock(deviceInfoMutex);

		// Method 1: Check current device name directly
		if (!currentDeviceName.empty()) {
			std::string nameLower = currentDeviceName;
			std::transform(nameLower.begin(), nameLower.end(), nameLower.begin(),
						 [](unsigned char c) { return std::tolower(c); });

			// Check against our keywords
			const char* keywords[] = {"headphone", "headset", "earphone", "earbud",
									 "airpod", "bluetooth", "bt", "wireless", "ear piece", "usb audio speakers"};
			for (const char* keyword : keywords) {
				if (nameLower.find(keyword) != std::string::npos) {
					isHeadphones = true;
					break;
				}
			}
		}

		// Method 2: If direct check fails, try to get device info from context
		if (!isHeadphones) {
			if (!gDevicesContextInitialized) {
				ma_result result = ma_context_init(NULL, 0, NULL, &gDevicesContext);
				if (result == MA_SUCCESS) {
					gDevicesContextInitialized = MA_TRUE;
				}
			}

			if (gDevicesContextInitialized) {
				ma_device_info defaultDeviceInfo;
				ma_result result = ma_context_get_device_info(&gDevicesContext,
															 ma_device_type_playback,
															 NULL,
															 &defaultDeviceInfo);
				if (result == MA_SUCCESS) {
					isHeadphones = isHeadphoneDevice(defaultDeviceInfo);
				}
			}
		}

		// Method 3: Windows-specific detection (if you're on Windows)
#ifdef HX_WINDOWS
		if (!isHeadphones) {
			// Windows-specific headphone detection using MMDevice API
			// This is more reliable on Windows
			isHeadphones = checkWindowsHeadphoneStatus();
		}
#endif

	} catch (...) {
		// If anything fails, assume not headphones
		isHeadphones = false;
	}

	// Store result
	headphoneCacheState.store(isHeadphones ? 2 : 3, std::memory_order_release);
	lastDeviceCheck = now;

	return isHeadphones;
}

// -------------------- LATENCY MEASUREMENT --------------------
int detectLatency() {
	int osMs = 48;

	if (deviceExists == MA_TRUE) {
		// Check if PnP device - if so, reduce base latency by 50ms
		if (!checkIfUsingPnPDevice()) {
			osMs += 50;
		}

		osMs += (int)(deviceConfig.periodSizeInMilliseconds);

		// Add 16ms extra latency if using headphones
		if (checkIfUsingHeadphones()) {
			std::lock_guard<std::mutex> lock(deviceInfoMutex);
			osMs += 16;
		}
	}

	return osMs;
}

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

	MIXER_STATE = anyActive ? 2 : 3;
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
			pBuffer[totalFramesRead * CHANNEL_COUNT + i] += (temp[i] * g_pDecodersVolume[index]) * masterVolume;
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

	MIXER_STATE = 1;

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
		ma_decoder_read_pcm_frames(pDecoder, latencyData.data(), (ma_uint64)latencyFrames, nullptr);
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

	// CRITICAL: Stop the device monitor thread FIRST
	stopDeviceMonitor();

	ma_device_uninit(&device);
	deviceExists = MA_FALSE;

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

	if (gDevicesContextInitialized) {
		ma_context_uninit(&gDevicesContext);
		gDevicesContextInitialized = MA_FALSE;
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
	deviceConfig.pUserData         = nullptr;
	deviceConfig.periodSizeInFrames = 256;
	deviceConfig.periods = 2;  // Double buffering

	if (ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS) {
		for (iDecoder = 0; iDecoder < g_decoderCount; ++iDecoder) {
			ma_decoder_uninit(&g_pDecoders[iDecoder]);
		}
		freeThingies();

		printf("Failed to open playback device.\n");
		return;
	}

	deviceExists = MA_TRUE;

	// Start monitoring for device changes
	startDeviceMonitor();
}

// pseudocode of what I'm doing
double getGlobalVolume() {
	return masterVolume;
}

double setGlobalVolume(double value) {
	masterVolume = value;
	return masterVolume;
}

/*void setPeriodSizeToFramerate(double rate) {
	int periodSizePerMs = (SAMPLE_RATE * 0.00);
	deviceConfig.periodSizeInFrames = std::min<int>((int)((rate * 0.5) * periodSizePerMs), periodSizePerMs);  // Try smaller buffer for lower latency
}*/