/*
 * Enhanced audio engine with double-buffered streaming, background tracks, and sound effects
 * HashLink version - All features synchronous, no threading
 */
#define HL_NAME(n) ma_thing_##n

#include <hl.h>
#include "signalsmith-stretch/signalsmith-stretch.h"

#if _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

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
			"swd#mmdevapi#","bluetooth","hid#","uefi" };
		const char* internalPatterns[] = { "hdaudio#","intel","realtek",
			"amd","nvidia","high definition audio","hd audio" };
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

// Buffer constants for double-buffering
#define PADDING_MS 100
#define BUFFER_MS 2000
#define HALF_BUFFER_MS 900

#define PADDING_FRAMES ((SAMPLE_RATE * PADDING_MS) / 1000)
#define BUFFER_FRAMES ((SAMPLE_RATE * BUFFER_MS) / 1000)
#define HALF_BUFFER_FRAMES ((SAMPLE_RATE * HALF_BUFFER_MS) / 1000)
#define TOTAL_BUFFER_FRAMES (PADDING_FRAMES + BUFFER_FRAMES + PADDING_FRAMES)

////////////////////////////////////////////////////////////////
// DECODER STREAM - Double-buffered streaming
////////////////////////////////////////////////////////////////

struct DecoderStream {
	float* pcmBufferA;
	float* pcmBufferB;
	float* activeBuffer;
	
	ma_uint64 filePosition;
	ma_uint64 bufferStartPos;
	ma_uint64 localReadPos;
	ma_uint64 validFrames;
	
	ma_bool32 active;
	
	ma_decoder decoder;
	ma_uint64 decoderLength;
	std::string filePath;
	
	// Second buffer state
	bool needsRefill;
	float* inactiveBuffer;
	ma_uint64 nextBufferStartPos;
	
	DecoderStream() : pcmBufferA(nullptr), pcmBufferB(nullptr), activeBuffer(nullptr),
		filePosition(0), bufferStartPos(0), localReadPos(0), validFrames(0),
		active(MA_FALSE), decoderLength(0), needsRefill(false), inactiveBuffer(nullptr),
		nextBufferStartPos(0) {
		memset(&decoder, 0, sizeof(ma_decoder));
	}
	
	~DecoderStream() {
		cleanup();
	}
	
	void cleanup() {
		if (decoder.onRead != nullptr || decoder.onSeek != nullptr) {
			ma_decoder_uninit(&decoder);
		}
		if (pcmBufferA) { free(pcmBufferA); pcmBufferA = nullptr; }
		if (pcmBufferB) { free(pcmBufferB); pcmBufferB = nullptr; }
		activeBuffer = nullptr;
		inactiveBuffer = nullptr;
		filePosition = 0;
		bufferStartPos = 0;
		localReadPos = 0;
		validFrames = 0;
		active = MA_FALSE;
		decoderLength = 0;
		needsRefill = false;
		nextBufferStartPos = 0;
		filePath.clear();
	}
};

////////////////////////////////////////////////////////////////
// BACKGROUND TRACK - Streaming background music
////////////////////////////////////////////////////////////////

struct BackgroundTrack {
	ma_decoder decoder;
	ma_uint64 length;
	float volume;
	ma_bool32 active;
	ma_bool32 looping;
	std::string filePath;
	ma_bool32 initialized;
	
	BackgroundTrack() : length(0), volume(1.0f), active(MA_FALSE), 
		looping(MA_TRUE), initialized(MA_FALSE) {
		memset(&decoder, 0, sizeof(ma_decoder));
	}
	
	~BackgroundTrack() {
		cleanup();
	}
	
	void cleanup() {
		if (initialized) {
			ma_decoder_uninit(&decoder);
			initialized = MA_FALSE;
		}
		memset(&decoder, 0, sizeof(ma_decoder));
		length = 0;
		volume = 1.0f;
		active = MA_FALSE;
		looping = MA_TRUE;
		filePath.clear();
	}
};

////////////////////////////////////////////////////////////////
// SOUND EFFECT - Fully loaded in memory
////////////////////////////////////////////////////////////////

struct SoundEffect {
	float* pcmData;
	ma_uint64 frameCount;
	ma_uint64 playbackPosition;
	float volume;
	ma_bool32 playing;
	std::string name;
	
	SoundEffect() : pcmData(nullptr), frameCount(0), playbackPosition(0),
		volume(1.0f), playing(MA_FALSE) {}
	
	~SoundEffect() {
		cleanup();
	}
	
	void cleanup() {
		if (pcmData) {
			free(pcmData);
			pcmData = nullptr;
		}
		frameCount = 0;
		playbackPosition = 0;
		volume = 1.0f;
		playing = MA_FALSE;
		name.clear();
	}
};

////////////////////////////////////////////////////////////////
// GLOBAL STATE
////////////////////////////////////////////////////////////////

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

// Main decoder streams (music tracks)
std::vector<DecoderStream> g_streams;
std::vector<float> g_decoderVolumes;
int g_longestDecoderIndex = 0;
float playbackRate = 1.0f;
double masterVolume = 1.0;

// Background tracks and sound effects
std::vector<BackgroundTrack> g_backgroundTracks;
std::vector<SoundEffect> g_soundEffects;
std::unordered_map<std::string, int> g_backgroundTrackMap;
std::unordered_map<std::string, int> g_soundEffectMap;

// Device state
int MIXER_STATE = 3;
int exists = 0;
ma_device device;
ma_bool32 deviceExists = MA_FALSE;
ma_device_config deviceConfig;

ma_mutex decoderMutex;
ma_bool32 decoderMutexInitialized = MA_FALSE;

static inline void ensure_mutex() {
	if(!decoderMutexInitialized){
		ma_mutex_init(&decoderMutex);
		decoderMutexInitialized=MA_TRUE;
	}
}

////////////////////////////////////////////////////////////////
// BUFFER MANAGEMENT
////////////////////////////////////////////////////////////////

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
	DecoderStream* s = &g_streams[index];
	
	ma_uint64 decodeStart = 0;
	if(startFrame > PADDING_FRAMES) {
		decodeStart = startFrame - PADDING_FRAMES;
	}
	
	ma_uint64 framesRead = 0;
	fillBuffer(s, s->pcmBufferA, decodeStart, &framesRead);
	
	s->activeBuffer = s->pcmBufferA;
	s->inactiveBuffer = s->pcmBufferB;
	s->bufferStartPos = decodeStart;
	s->validFrames = framesRead;
	s->needsRefill = false;
	
	if(startFrame >= decodeStart) {
		s->localReadPos = startFrame - decodeStart;
	} else {
		s->localReadPos = 0;
	}
	
	if(s->localReadPos >= TOTAL_BUFFER_FRAMES) {
		s->localReadPos = TOTAL_BUFFER_FRAMES - 1;
	}
	
	s->filePosition = startFrame;
	s->active = (startFrame < s->decoderLength && framesRead > 0) ? MA_TRUE : MA_FALSE;
	
	// Prepare next buffer position
	if (s->active) {
		ma_uint64 futurePosition = startFrame + HALF_BUFFER_FRAMES;
		if (futurePosition > PADDING_FRAMES) {
			s->nextBufferStartPos = futurePosition - PADDING_FRAMES;
		} else {
			s->nextBufferStartPos = 0;
		}
		s->needsRefill = (s->nextBufferStartPos < s->decoderLength);
	}
}

bool shouldSwitchBuffer(const DecoderStream* s) {
	ma_uint64 audioProgress = s->localReadPos;
	return audioProgress >= (PADDING_FRAMES + (BUFFER_FRAMES * 3 / 4));
}

void tryRefillAndSwitch(DecoderStream* s, size_t index) {
	if (!s->needsRefill) return;
	if (!shouldSwitchBuffer(s)) return;
	
	// Refill the inactive buffer synchronously
	ma_uint64 framesRead = 0;
	fillBuffer(s, s->inactiveBuffer, s->nextBufferStartPos, &framesRead);
	
	if (framesRead == 0) {
		s->needsRefill = false;
		return;
	}
	
	// Swap buffers
	float* temp = s->activeBuffer;
	s->activeBuffer = s->inactiveBuffer;
	s->inactiveBuffer = temp;
	
	s->bufferStartPos = s->nextBufferStartPos;
	s->validFrames = framesRead;
	
	// Recalculate local read position
	if (s->filePosition >= s->bufferStartPos) {
		s->localReadPos = s->filePosition - s->bufferStartPos;
	} else {
		s->localReadPos = 0;
	}
	
	if(s->localReadPos >= TOTAL_BUFFER_FRAMES) {
		s->localReadPos = TOTAL_BUFFER_FRAMES - 1;
	}
	if(s->localReadPos > s->validFrames) {
		s->localReadPos = s->validFrames;
	}
	
	// Setup next refill
	ma_uint64 futurePosition = s->filePosition + HALF_BUFFER_FRAMES;
	if (futurePosition > PADDING_FRAMES) {
		s->nextBufferStartPos = futurePosition - PADDING_FRAMES;
	} else {
		s->nextBufferStartPos = 0;
	}
	s->needsRefill = (s->nextBufferStartPos < s->decoderLength);
}

ma_uint32 readFromBufferAsync(size_t index, float* output, ma_uint32 frameCount) {
	DecoderStream* s = &g_streams[index];
	
	if(!s->active) return 0;
	
	tryRefillAndSwitch(s, index);
	
	ma_uint32 framesRead = 0;
	
	while(framesRead < frameCount && s->active) {
		if(s->localReadPos >= s->validFrames) {
			s->active = MA_FALSE;
			break;
		}
		
		ma_uint64 available = s->validFrames - s->localReadPos;
		if(available == 0) {
			s->active = MA_FALSE;
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
			s->active = MA_FALSE;
			break;
		}
		
		float* src = s->activeBuffer + (s->localReadPos * CHANNEL_COUNT);
		float vol = g_decoderVolumes[index] * masterVolume;
		
		for(ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
			output[framesRead * CHANNEL_COUNT + i] += src[i] * vol;
		}
		
		s->localReadPos += toRead;
		s->filePosition += toRead;
		framesRead += toRead;
		
		if(s->filePosition >= s->decoderLength) {
			s->active = MA_FALSE;
			break;
		}
	}
	
	return framesRead;
}

////////////////////////////////////////////////////////////////
// BACKGROUND TRACK HELPERS
////////////////////////////////////////////////////////////////

ma_uint64 readBackgroundFrames(BackgroundTrack* track, float* output, ma_uint32 frameCount, float masterVol) {
	if (!track->initialized || !track->active) return 0;
	
	float tempBuffer[4096 * CHANNEL_COUNT];
	ma_uint32 toRead = frameCount;
	if (toRead > 4096) toRead = 4096;
	
	memset(tempBuffer, 0, sizeof(float) * toRead * CHANNEL_COUNT);
	
	ma_uint64 framesRead = 0;
	ma_decoder_read_pcm_frames(&track->decoder, tempBuffer, toRead, &framesRead);
	
	float vol = track->volume * masterVol;
	for (ma_uint64 i = 0; i < framesRead * CHANNEL_COUNT; i++) {
		output[i] += tempBuffer[i] * vol;
	}
	
	if (framesRead < toRead) {
		if (track->looping) {
			ma_decoder_seek_to_pcm_frame(&track->decoder, 0);
			ma_uint64 remainingFrames = toRead - framesRead;
			if (remainingFrames > 0) {
				float tempBuffer2[4096 * CHANNEL_COUNT];
				ma_uint64 framesRead2 = 0;
				memset(tempBuffer2, 0, sizeof(float) * remainingFrames * CHANNEL_COUNT);
				ma_decoder_read_pcm_frames(&track->decoder, tempBuffer2, remainingFrames, &framesRead2);
				
				for (ma_uint64 i = 0; i < framesRead2 * CHANNEL_COUNT; i++) {
					output[framesRead * CHANNEL_COUNT + i] += tempBuffer2[i] * vol;
				}
				framesRead += framesRead2;
			}
		} else {
			track->active = MA_FALSE;
		}
	}
	
	return framesRead;
}

////////////////////////////////////////////////////////////////
// SOUND EFFECT HELPERS
////////////////////////////////////////////////////////////////

ma_uint64 readSoundEffectFrames(SoundEffect* sfx, float* output, ma_uint32 frameCount, float masterVol) {
	if (!sfx->playing || !sfx->pcmData) return 0;
	
	ma_uint64 pos = sfx->playbackPosition;
	ma_uint64 remaining = sfx->frameCount - pos;
	
	if (remaining == 0) {
		sfx->playing = MA_FALSE;
		return 0;
	}
	
	ma_uint32 toRead = (ma_uint32)remaining;
	if (toRead > frameCount) toRead = frameCount;
	
	float* src = sfx->pcmData + (pos * CHANNEL_COUNT);
	float vol = sfx->volume * masterVol;
	
	for (ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
		output[i] += src[i] * vol;
	}
	
	sfx->playbackPosition = pos + toRead;
	
	if (sfx->playbackPosition >= sfx->frameCount) {
		sfx->playing = MA_FALSE;
	}
	
	return toRead;
}

////////////////////////////////////////////////////////////////
// AUDIO CALLBACK
////////////////////////////////////////////////////////////////

static inline bool any_active() {
	for(size_t i = 0; i < g_streams.size(); i++) {
		if(g_streams[i].active) return true;
	}
	return false;
}

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
	float* pOutputF32 = (float*)pOutput;
	MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);
	
	ensure_mutex();
	ma_mutex_lock(&decoderMutex);
	
	bool hasAudio = any_active();
	
	// Check background tracks and sound effects
	for (auto& track : g_backgroundTracks) {
		if (track.active) { hasAudio = true; break; }
	}
	if (!hasAudio) {
		for (auto& sfx : g_soundEffects) {
			if (sfx.playing) { hasAudio = true; break; }
		}
	}
	
	if(!hasAudio){
		memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
		MIXER_STATE = 3;
		ma_mutex_unlock(&decoderMutex);
		(void)pInput;
		return;
	}

	if(playbackRate == 1.0f){
		memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
		
		// Mix main decoders
		for(size_t i = 0; i < g_streams.size(); i++){
			if(!g_streams[i].active) continue;
			ma_uint32 read = readFromBufferAsync(i, pOutputF32, frameCount);
			if(read == 0) g_streams[i].active = MA_FALSE;
		}
		
		// Mix background tracks
		for (auto& track : g_backgroundTracks) {
			if (track.active) {
				readBackgroundFrames(&track, pOutputF32, frameCount, masterVolume);
			}
		}
		
		// Mix sound effects
		for (auto& sfx : g_soundEffects) {
			if (sfx.playing) {
				readSoundEffectFrames(&sfx, pOutputF32, frameCount, masterVolume);
			}
		}
	} else {
		float inputMix[4096*CHANNEL_COUNT] = {0};
		float stretchedOutput[4096*CHANNEL_COUNT] = {0};
		ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * playbackRate);
		if(maxFramesToRead > 4096) maxFramesToRead = 4096;
		
		// Mix main decoders with stretching
		for(size_t i = 0; i < g_streams.size(); i++){
			if(!g_streams[i].active) continue;
			ma_uint32 read = readFromBufferAsync(i, inputMix, maxFramesToRead);
			if(read == 0) g_streams[i].active = MA_FALSE;
		}
		
		// Background tracks and SFX always play at normal speed
		float normalSpeedMix[4096*CHANNEL_COUNT] = {0};
		for (auto& track : g_backgroundTracks) {
			if (track.active) {
				readBackgroundFrames(&track, normalSpeedMix, frameCount, masterVolume);
			}
		}
		for (auto& sfx : g_soundEffects) {
			if (sfx.playing) {
				readSoundEffectFrames(&sfx, normalSpeedMix, frameCount, masterVolume);
			}
		}
		
		if(any_active()){
			if(stretch == nullptr){
				stretch = new signalsmith::stretch::SignalsmithStretch();
				stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
			}
			stretch->process(inputMix, maxFramesToRead, stretchedOutput, frameCount);
			
			// Mix stretched output with normal speed output
			for(ma_uint32 i = 0; i < frameCount * CHANNEL_COUNT; i++) {
				pOutputF32[i] = stretchedOutput[i] + normalSpeedMix[i];
			}
		} else {
			memcpy(pOutputF32, normalSpeedMix, sizeof(float)*frameCount*CHANNEL_COUNT);
		}
	}
	
	MIXER_STATE = (any_active() || hasAudio) ? 1 : 3;
	ma_mutex_unlock(&decoderMutex);
	(void)pInput;
}

////////////////////////////////////////////////////////////////
// HASHLINK FUNCTIONS - Main decoder system
////////////////////////////////////////////////////////////////

HL_PRIM int HL_NAME(detectLatency)(_NO_ARG) {
	int osMs = 47;
	if (deviceExists == MA_TRUE) {
#ifdef HX_WINDOWS
		if(!checkIfPnPDevice()) osMs += 50;
		if(checkWindowsHeadphoneStatus()) osMs += 20;
#endif
	}
	return osMs;
}

HL_PRIM int HL_NAME(get_mixer_state)(_NO_ARG){
	return MIXER_STATE;
}

HL_PRIM double HL_NAME(get_playback_position)(_NO_ARG){
	ma_uint64 pos = 0;
	ensure_mutex();
	ma_mutex_lock(&decoderMutex);
	if(!g_streams.empty() && g_streams[g_longestDecoderIndex].active) {
		pos = g_streams[g_longestDecoderIndex].filePosition;
	} else if(!g_streams.empty()) {
		pos = g_streams[g_longestDecoderIndex].decoderLength;
	}
	ma_mutex_unlock(&decoderMutex);
	return ((double)pos / (SAMPLE_RATE * 0.001));
}

HL_PRIM double HL_NAME(get_duration)(_NO_ARG){ 
	if(g_streams.empty()) return 0.0;
	return (double)g_streams[g_longestDecoderIndex].decoderLength / (SAMPLE_RATE * 0.001); 
}

HL_PRIM void HL_NAME(seek_to_pcm_frame)(ma_uint64 pos) {
	if(exists == 0) return;
	ensure_mutex();
	ma_mutex_lock(&decoderMutex);
	
	for(size_t i = 0; i < g_streams.size(); i++) {
		DecoderStream& s = g_streams[i];
		ma_uint64 target = 0;
		if(pos <= 0) target = 0;
		else if((ma_uint64)pos >= s.decoderLength) target = s.decoderLength;
		else target = (ma_uint64)pos;
		
		fillInitialBuffer(i, target);
	}
	
	ma_mutex_unlock(&decoderMutex);
	MIXER_STATE = (pos < (ma_uint64)g_streams[g_longestDecoderIndex].decoderLength) ? 2 : 3;
}

HL_PRIM void HL_NAME(deactivate_decoder_hl)(int index) {
	if(index >= 0 && index < (int)g_streams.size()) {
		g_streams[index].active = MA_FALSE;
	}
}

HL_PRIM void HL_NAME(amplify_decoder_hl)(int index, double volume) {
	if(index >= 0 && index < (int)g_decoderVolumes.size()) {
		g_decoderVolumes[index] = (float)volume;
	}
}

HL_PRIM void HL_NAME(setPlaybackRate)(float value) {
	playbackRate = value;
}

HL_PRIM void HL_NAME(start)(_NO_ARG) {
	if(exists == 0) return;
	if(MIXER_STATE == 3) HL_NAME(seek_to_pcm_frame)(0);
	ma_device_start(&device);
}

HL_PRIM void HL_NAME(stop)(_NO_ARG) {
	if(exists == 0) return;
	ma_device_stop(&device);
	MIXER_STATE = 2;
}

HL_PRIM bool HL_NAME(stopped)(_NO_ARG) {
	return MIXER_STATE == 3;
}

HL_PRIM void HL_NAME(destroy)(_NO_ARG) {
	if(exists == 0) return;
	exists = 0;
	
	ma_device_stop(&device);
	ma_device_uninit(&device);
	
	g_streams.clear();
	g_decoderVolumes.clear();
	g_backgroundTracks.clear();
	g_soundEffects.clear();
	g_backgroundTrackMap.clear();
	g_soundEffectMap.clear();
	
	if(stretch) {
		delete stretch;
		stretch = nullptr;
	}
	if(decoderMutexInitialized) {
		ma_mutex_uninit(&decoderMutex);
		decoderMutexInitialized = MA_FALSE;
	}
	deviceExists = MA_FALSE;
	g_longestDecoderIndex = 0;
	playbackRate = 1.0f;
	masterVolume = 1.0;
	MIXER_STATE = 3;
}

HL_PRIM void HL_NAME(loadFiles)(varray* argv) {
	if(argv->size == 0) {
		printf("No input files.\n");
		return;
	}
	
	// Clean up existing resources
	if(exists) HL_NAME(destroy)();
	
	g_streams.resize(argv->size);
	g_decoderVolumes.resize(argv->size, 1.0f);
	
	ma_uint64 absoluteLengthOfSong = 0;
	ma_decoder_config decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
	
	for(size_t i = 0; i < argv->size; i++) {
		const char* path = hl_aptr(argv, const char*)[i];
		DecoderStream& s = g_streams[i];
		
		ma_result result = ma_decoder_init_file(path, &decoderConfig, &s.decoder);
		if(result != MA_SUCCESS) {
			g_streams.clear();
			g_decoderVolumes.clear();
			printf("Failed to load %s.\n", path);
			exists = 0;
			return;
		}
		
		s.filePath = path;
		ma_data_source_set_looping(&s.decoder, MA_FALSE);
		ma_decoder_get_length_in_pcm_frames(&s.decoder, &s.decoderLength);
		
		// Allocate double buffers
		s.pcmBufferA = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
		s.pcmBufferB = (float*)malloc(sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
		memset(s.pcmBufferA, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
		memset(s.pcmBufferB, 0, sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
		
		fillInitialBuffer(i, 0);
		
		if(s.decoderLength > absoluteLengthOfSong) {
			absoluteLengthOfSong = s.decoderLength;
			g_longestDecoderIndex = (int)i;
		}
	}
	
	// Initialize audio device
	deviceConfig = ma_device_config_init(ma_device_type_playback);
	deviceConfig.playback.format = SAMPLE_FORMAT;
	deviceConfig.playback.channels = CHANNEL_COUNT;
	deviceConfig.sampleRate = SAMPLE_RATE;
	deviceConfig.dataCallback = data_callback;
	deviceConfig.pUserData = nullptr;
	deviceConfig.periodSizeInFrames = 256;
	deviceConfig.periods = 2;
	
	if(ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS) {
		g_streams.clear();
		g_decoderVolumes.clear();
		printf("Failed to open playback device.\n");
		return;
	}
	
	ensure_mutex();
	deviceExists = MA_TRUE;
	exists = 1;
	MIXER_STATE = 3;
}

HL_PRIM double HL_NAME(getGlobalVolume)(_NO_ARG) {
	return masterVolume;
}

HL_PRIM double HL_NAME(setGlobalVolume)(double value) {
	masterVolume = value;
	return masterVolume;
}

HL_PRIM bool HL_NAME(wearingHeadphones)(_NO_ARG) {
#ifdef HX_WINDOWS
	return checkWindowsHeadphoneStatus();
#else
	return false;
#endif
}

HL_PRIM bool HL_NAME(wearingPlugNPlay)(_NO_ARG) {
#ifdef HX_WINDOWS
	return checkIfPnPDevice();
#else
	return false;
#endif
}

////////////////////////////////////////////////////////////////
// HASHLINK FUNCTIONS - Background Tracks
////////////////////////////////////////////////////////////////

HL_PRIM int HL_NAME(loadBackgroundTrack)(vstring* path) {
	// Initialize device if not already done
	if (!deviceExists) {
		ma_device_config config = ma_device_config_init(ma_device_type_playback);
		config.playback.format = SAMPLE_FORMAT;
		config.playback.channels = CHANNEL_COUNT;
		config.sampleRate = SAMPLE_RATE;
		config.dataCallback = data_callback;
		config.pUserData = nullptr;
		config.periodSizeInMilliseconds = 40;
		
		if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS) {
			printf("Failed to initialize audio device for background track\n");
			return -1;
		}
		deviceExists = MA_TRUE;
		ma_device_start(&device);
	}
	
	const char* pathStr = hl_to_utf8(path->bytes);
	std::string key = pathStr;
	
	// Check if already loaded
	auto it = g_backgroundTrackMap.find(key);
	if (it != g_backgroundTrackMap.end()) {
		return it->second;
	}
	
	BackgroundTrack track;
	ma_decoder_config config = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
	
	if (ma_decoder_init_file(pathStr, &config, &track.decoder) != MA_SUCCESS) {
		printf("Failed to load background track: %s\n", pathStr);
		return -1;
	}
	
	track.initialized = MA_TRUE;
	track.filePath = pathStr;
	ma_decoder_get_length_in_pcm_frames(&track.decoder, &track.length);
	track.active = MA_FALSE;
	track.looping = MA_TRUE;
	
	int index = (int)g_backgroundTracks.size();
	g_backgroundTracks.push_back(std::move(track));
	g_backgroundTrackMap[key] = index;
	return index;
}

HL_PRIM void HL_NAME(playBackgroundTrack)(int index) {
	if (index >= 0 && index < (int)g_backgroundTracks.size()) {
		g_backgroundTracks[index].active = MA_TRUE;
	}
}

HL_PRIM void HL_NAME(stopBackgroundTrack)(int index) {
	if (index >= 0 && index < (int)g_backgroundTracks.size()) {
		BackgroundTrack& track = g_backgroundTracks[index];
		track.active = MA_FALSE;
		if (track.initialized) {
			ma_decoder_seek_to_pcm_frame(&track.decoder, 0);
		}
	}
}

HL_PRIM void HL_NAME(setBackgroundTrackVolume)(int index, float volume) {
	if (index >= 0 && index < (int)g_backgroundTracks.size()) {
		g_backgroundTracks[index].volume = volume;
	}
}

HL_PRIM void HL_NAME(setBackgroundTrackLooping)(int index, bool looping) {
	if (index >= 0 && index < (int)g_backgroundTracks.size()) {
		g_backgroundTracks[index].looping = looping ? MA_TRUE : MA_FALSE;
	}
}

HL_PRIM bool HL_NAME(isBackgroundTrackPlaying)(int index) {
	if (index >= 0 && index < (int)g_backgroundTracks.size()) {
		return g_backgroundTracks[index].active == MA_TRUE;
	}
	return false;
}

////////////////////////////////////////////////////////////////
// HASHLINK FUNCTIONS - Sound Effects
////////////////////////////////////////////////////////////////

HL_PRIM int HL_NAME(loadSoundEffect)(vstring* path) {
	// Initialize device if not already done
	if (!deviceExists) {
		ma_device_config config = ma_device_config_init(ma_device_type_playback);
		config.playback.format = SAMPLE_FORMAT;
		config.playback.channels = CHANNEL_COUNT;
		config.sampleRate = SAMPLE_RATE;
		config.dataCallback = data_callback;
		config.pUserData = nullptr;
		config.periodSizeInMilliseconds = 40;
		
		if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS) {
			printf("Failed to initialize audio device for sound effect\n");
			return -1;
		}
		deviceExists = MA_TRUE;
		ma_device_start(&device);
	}
	
	const char* pathStr = hl_to_utf8(path->bytes);
	std::string key = pathStr;
	
	// Check if already loaded
	auto it = g_soundEffectMap.find(key);
	if (it != g_soundEffectMap.end()) {
		return it->second;
	}
	
	// Decode entire file into memory
	ma_decoder decoder;
	ma_decoder_config config = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);
	
	if (ma_decoder_init_file(pathStr, &config, &decoder) != MA_SUCCESS) {
		printf("Failed to load sound effect: %s\n", pathStr);
		return -1;
	}
	
	ma_uint64 length = 0;
	ma_decoder_get_length_in_pcm_frames(&decoder, &length);
	
	if (length == 0) {
		ma_decoder_uninit(&decoder);
		printf("Sound effect has zero length: %s\n", pathStr);
		return -1;
	}
	
	SoundEffect sfx;
	sfx.pcmData = (float*)malloc(sizeof(float) * length * CHANNEL_COUNT);
	if (!sfx.pcmData) {
		ma_decoder_uninit(&decoder);
		printf("Failed to allocate memory for sound effect: %s\n", pathStr);
		return -1;
	}
	
	ma_uint64 framesRead = 0;
	ma_decoder_read_pcm_frames(&decoder, sfx.pcmData, length, &framesRead);
	ma_decoder_uninit(&decoder);
	
	if (framesRead == 0) {
		free(sfx.pcmData);
		printf("Failed to read sound effect: %s\n", pathStr);
		return -1;
	}
	
	sfx.frameCount = framesRead;
	sfx.name = pathStr;
	
	int index = (int)g_soundEffects.size();
	g_soundEffects.push_back(std::move(sfx));
	g_soundEffectMap[key] = index;
	return index;
}

HL_PRIM void HL_NAME(playSoundEffect)(int index, float volume) {
	if (index >= 0 && index < (int)g_soundEffects.size()) {
		SoundEffect& sfx = g_soundEffects[index];
		if (sfx.pcmData && sfx.frameCount > 0) {
			sfx.playbackPosition = 0;
			sfx.volume = volume;
			sfx.playing = MA_TRUE;
		}
	}
}

HL_PRIM void HL_NAME(stopSoundEffect)(int index) {
	if (index >= 0 && index < (int)g_soundEffects.size()) {
		g_soundEffects[index].playing = MA_FALSE;
		g_soundEffects[index].playbackPosition = 0;
	}
}

HL_PRIM bool HL_NAME(isSoundEffectPlaying)(int index) {
	if (index >= 0 && index < (int)g_soundEffects.size()) {
		return g_soundEffects[index].playing == MA_TRUE;
	}
	return false;
}

////////////////////////////////////////////////////////////////
// HASHLINK BINDINGS
////////////////////////////////////////////////////////////////

DEFINE_PRIM(_I32, detectLatency, _NO_ARG)
DEFINE_PRIM(_I32, get_mixer_state, _NO_ARG)
DEFINE_PRIM(_F64, get_playback_position, _NO_ARG)
DEFINE_PRIM(_F64, get_duration, _NO_ARG)
DEFINE_PRIM(_VOID, seek_to_pcm_frame, _I64)
DEFINE_PRIM(_VOID, deactivate_decoder_hl, _I32)
DEFINE_PRIM(_VOID, amplify_decoder_hl, _I32 _F64)
DEFINE_PRIM(_VOID, setPlaybackRate, _F32)
DEFINE_PRIM(_VOID, start, _NO_ARG)
DEFINE_PRIM(_VOID, stop, _NO_ARG)
DEFINE_PRIM(_BOOL, stopped, _NO_ARG)
DEFINE_PRIM(_VOID, destroy, _NO_ARG)
DEFINE_PRIM(_VOID, loadFiles, _ARR)
DEFINE_PRIM(_F64, getGlobalVolume, _NO_ARG)
DEFINE_PRIM(_F64, setGlobalVolume, _F64)
DEFINE_PRIM(_BOOL, wearingHeadphones, _NO_ARG)
DEFINE_PRIM(_BOOL, wearingPlugNPlay, _NO_ARG)

// Background track bindings
DEFINE_PRIM(_I32, loadBackgroundTrack, _STRING)
DEFINE_PRIM(_VOID, playBackgroundTrack, _I32)
DEFINE_PRIM(_VOID, stopBackgroundTrack, _I32)
DEFINE_PRIM(_VOID, setBackgroundTrackVolume, _I32 _F32)
DEFINE_PRIM(_VOID, setBackgroundTrackLooping, _I32 _BOOL)
DEFINE_PRIM(_BOOL, isBackgroundTrackPlaying, _I32)

// Sound effect bindings
DEFINE_PRIM(_I32, loadSoundEffect, _STRING)
DEFINE_PRIM(_VOID, playSoundEffect, _I32 _F32)
DEFINE_PRIM(_VOID, stopSoundEffect, _I32)
DEFINE_PRIM(_BOOL, isSoundEffectPlaying, _I32)