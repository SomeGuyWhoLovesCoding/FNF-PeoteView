/*
 * Clean sliding window buffer implementation.
 * 2-second raw PCM buffer with 100ms padding on each side.
 * Refills when playback crosses the 1-second mark.
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
						const char* kws[] = { "headphone","headset","earphone","earbud","airpod","bluetooth","bt","wireless","ear piece","usb audio speakers" };
						for (const char* kw : kws) if (name.find(kw)!=std::string::npos) { isHeadphones=true; break; }
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
		const char* pnpPatterns[] = { "usb#","bth#","bthenum#","swd#mmdevapi#","bluetooth","hid#","uefi" };
		const char* internalPatterns[] = { "hdaudio#","intel","realtek","amd","nvidia","high definition audio","hd audio" };
		for (const char* pat:pnpPatterns) if(id.find(pat)!=std::string::npos) { isPnP=true; break; }
		if(!isPnP) for (const char* pat:internalPatterns) if(id.find(pat)!=std::string::npos) { isPnP=false; break; }
		CoTaskMemFree(pwszDeviceId);
	}

	if (!isPnP && SUCCEEDED(pDevice->OpenPropertyStore(STGM_READ, &pProps))) {
		PROPVARIANT var; PropVariantInit(&var);
		const PROPERTYKEY* keys[] = { &PKEY_Device_FriendlyName, &PKEY_Device_DeviceDesc, &PKEY_DeviceInterface_FriendlyName };
		for(int i=0;i<3 && !isPnP;i++){
			if(SUCCEEDED(pProps->GetValue(*keys[i],&var)) && var.vt==VT_LPWSTR && var.pwszVal){
				std::string s = wstring_to_string(var.pwszVal); std::transform(s.begin(),s.end(),s.begin(),::tolower);
				const char* kws[]={"usb","bluetooth","bt","wireless","external","headset","airpod","bose","sony","jbl","logitech","hdmi","displayport","digital audio","digital output","soundblaster","audio interface","dac","amplifier"};
				const char* internalKws[]={"speakers","internal","built-in","default","primary","main","system","laptop","desktop","monitor","display"};
				bool foundInternal=false; for(const char* k:internalKws) if(s.find(k)!=std::string::npos){foundInternal=true;break;} 
				if(!foundInternal) for(const char* k:kws) if(s.find(k)!=std::string::npos){isPnP=true; break;}
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

// Buffer constants (exactly as specified)
#define PADDING_MS 100
#define BUFFER_MS 2000
#define HALF_BUFFER_MS 1000

#define PADDING_FRAMES ((SAMPLE_RATE * PADDING_MS) / 1000)        // 4410 frames
#define BUFFER_FRAMES ((SAMPLE_RATE * BUFFER_MS) / 1000)          // 88200 frames
#define HALF_BUFFER_FRAMES ((SAMPLE_RATE * HALF_BUFFER_MS) / 1000) // 44100 frames
#define TOTAL_BUFFER_FRAMES (PADDING_FRAMES + BUFFER_FRAMES + PADDING_FRAMES) // 96620 frames

// Per-decoder streaming buffer
struct DecoderStream {
	float* pcmBuffer;           // Raw PCM buffer: [100ms padding][2000ms audio][100ms padding]
	ma_uint64 filePosition;     // Current position in the source file (in frames)
	ma_uint64 bufferStartPos;   // File position that maps to start of pcmBuffer
	ma_uint64 localReadPos;     // Read position within pcmBuffer (0 to TOTAL_BUFFER_FRAMES)
	ma_uint64 validFrames;      // How many frames in buffer are valid
	bool active;
};

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

ma_uint32   g_decoderCount;
ma_decoder* g_pDecoders;
ma_uint64*  g_pDecoderLengths;
int         g_pLongestDecoderIndex;
float*      g_pDecodersVolume;
DecoderStream* g_pStreams;

float playbackRate = 1;
double masterVolume = 1;

int MIXER_STATE = 3;
int exists = 0;

ma_result result;
ma_decoder_config decoderConfig;
ma_device_config  deviceConfig;
ma_device         device;
ma_bool32 deviceExists = MA_FALSE;
ma_uint32 iDecoder;

ma_mutex audioMutex;
ma_bool32 mutexInitialized = MA_FALSE;

static inline void ensure_mutex() {
	if(!mutexInitialized){ma_mutex_init(&audioMutex);mutexInitialized=MA_TRUE;}
}

int detectLatency() {
	int osMs=45;
	if(deviceExists==MA_TRUE){
		if(!wearingPlugNPlay()) osMs+=50;
		osMs+=(int)(deviceConfig.periodSizeInMilliseconds);
		if(wearingHeadphones()) osMs+=20;
	}
	return osMs;
}

int getMixerState(){return MIXER_STATE;}

double getPlaybackPosition(){
	ensure_mutex(); 
	ma_mutex_lock(&audioMutex);
	ma_uint64 pos = 0;
	if(g_pStreams && g_pStreams[g_pLongestDecoderIndex].active) {
		pos = g_pStreams[g_pLongestDecoderIndex].filePosition;
	} else {
		pos = g_pDecoderLengths[g_pLongestDecoderIndex];
	}
	ma_mutex_unlock(&audioMutex);
	return ((double)pos / (SAMPLE_RATE * 0.001));
}

double getDuration(){ 
	return (double)g_pDecoderLengths[g_pLongestDecoderIndex] / (SAMPLE_RATE * 0.001); 
}

// Initial buffer fill - decode from file into PCM buffer
void fillInitialBuffer(ma_uint32 index, ma_uint64 startFrame) {
	DecoderStream* s = &g_pStreams[index];
	ma_decoder* dec = &g_pDecoders[index];
	
	// DEBUG: Clear buffer to avoid garbage data
	memset(s->pcmBuffer, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
	
	// Calculate where to start decoding
	ma_uint64 decodeStart = 0;
	if(startFrame > PADDING_FRAMES) {
		decodeStart = startFrame - PADDING_FRAMES;
	}
	
	// Don't decode past end of file
	ma_uint64 maxDecodeFrames = TOTAL_BUFFER_FRAMES;
	if(decodeStart + TOTAL_BUFFER_FRAMES > g_pDecoderLengths[index]) {
		maxDecodeFrames = g_pDecoderLengths[index] - decodeStart;
	}
	
	// Seek and decode
	ma_decoder_seek_to_pcm_frame(dec, decodeStart);
	
	ma_uint64 framesRead = 0;
	if(maxDecodeFrames > 0) {
		ma_decoder_read_pcm_frames(dec, s->pcmBuffer, maxDecodeFrames, &framesRead);
	}
	
	// Setup positions
	s->bufferStartPos = decodeStart;
	s->validFrames = framesRead;
	
	// Calculate where startFrame is in this buffer
	if(startFrame >= decodeStart) {
		s->localReadPos = startFrame - decodeStart;
	} else {
		s->localReadPos = 0;
	}
	
	// Safety check
	if(s->localReadPos >= TOTAL_BUFFER_FRAMES) {
		s->localReadPos = TOTAL_BUFFER_FRAMES - 1;
	}
	
	s->filePosition = startFrame;
	s->active = (startFrame < g_pDecoderLengths[index] && framesRead > 0);
	
	/*printf("fillInitialBuffer: index=%u, startFrame=%llu, decodeStart=%llu, localReadPos=%llu, validFrames=%llu\n",
		   index, startFrame, decodeStart, s->localReadPos, s->validFrames);*/
}

// Sliding window refill - CORRECT VERSION with padding handling
void refillBufferSafe(ma_uint32 index) {
	DecoderStream* s = &g_pStreams[index];
	ma_decoder* dec = &g_pDecoders[index];
	
	/*printf("refillBufferSafe called: index=%u, filePosition=%llu, localReadPos=%llu, validFrames=%llu\n",
		   index, s->filePosition, s->localReadPos, s->validFrames);*/
	
	// We need a new buffer centered around current position
	ma_uint64 targetBufferStart = 0;
	if(s->filePosition > PADDING_FRAMES) {
		targetBufferStart = s->filePosition - PADDING_FRAMES;
	}
	
	// Don't go past end of file
	if(targetBufferStart >= g_pDecoderLengths[index]) {
		s->active = false;
		return;
	}
	
	// Calculate how many frames we can actually decode
	ma_uint64 maxDecodeFrames = TOTAL_BUFFER_FRAMES;
	if(targetBufferStart + TOTAL_BUFFER_FRAMES > g_pDecoderLengths[index]) {
		maxDecodeFrames = g_pDecoderLengths[index] - targetBufferStart;
	}
	
	// Clear buffer first
	memset(s->pcmBuffer, 0, TOTAL_BUFFER_FRAMES * CHANNEL_COUNT * sizeof(float));
	
	// Seek and decode
	ma_decoder_seek_to_pcm_frame(dec, targetBufferStart);
	
	ma_uint64 framesRead = 0;
	if(maxDecodeFrames > 0) {
		ma_decoder_read_pcm_frames(dec, s->pcmBuffer, maxDecodeFrames, &framesRead);
	}
	
	// Update positions
	s->bufferStartPos = targetBufferStart;
	s->validFrames = framesRead;
	
	// Calculate local read position (where current file position is in buffer)
	if(s->filePosition >= targetBufferStart) {
		s->localReadPos = s->filePosition - targetBufferStart;
	} else {
		s->localReadPos = 0;
	}
	
	// Safety checks
	if(s->localReadPos >= TOTAL_BUFFER_FRAMES) {
		s->localReadPos = TOTAL_BUFFER_FRAMES - 1;
	}
	if(s->localReadPos > s->validFrames) {
		s->localReadPos = s->validFrames;
	}
	
	/*printf("refillBufferSafe done: new bufferStartPos=%llu, localReadPos=%llu, validFrames=%llu\n",
		   s->bufferStartPos, s->localReadPos, s->validFrames);*/
}

void seekToPCMFrame(int64_t pos){
	if(exists==0) return; 
	ensure_mutex(); 
	ma_mutex_lock(&audioMutex);
	
	for(iDecoder=0; iDecoder<g_decoderCount; iDecoder++){
		ma_uint64 target = 0;
		if(pos <= 0) target = 0;
		else if((ma_uint64)pos >= g_pDecoderLengths[iDecoder]) target = g_pDecoderLengths[iDecoder];
		else target = (ma_uint64)pos;
		
		fillInitialBuffer(iDecoder, target);
	}
	
	ma_mutex_unlock(&audioMutex);
	MIXER_STATE = (pos < (int64_t)g_pDecoderLengths[g_pLongestDecoderIndex]) ? 2 : 3;
}

void freeThingies(){
	if(g_pDecoders) free(g_pDecoders);
	if(g_pDecoderLengths) free(g_pDecoderLengths);
	if(g_pDecodersVolume) free(g_pDecodersVolume);
	if(g_pStreams) {
		for(ma_uint32 i=0; i<g_decoderCount; i++) {
			if(g_pStreams[i].pcmBuffer) free(g_pStreams[i].pcmBuffer);
		}
		free(g_pStreams);
	}
}

// Read frames from PCM buffer
// Fixed readFromBuffer with proper padding handling
ma_uint32 readFromBufferSafe(ma_uint32 index, float* output, ma_uint32 frameCount) {
	DecoderStream* s = &g_pStreams[index];
	
	if(!s->active) return 0;
	
	/*printf("readFromBufferSafe start: index=%u, filePosition=%llu/%llu, localReadPos=%llu, validFrames=%llu, frameCount=%u\n",
		   index, s->filePosition, g_pDecoderLengths[index], s->localReadPos, s->validFrames, frameCount);*/
	
	// Safety check - are we trying to read past end of buffer?
	if(s->localReadPos >= s->validFrames) {
		//printf("ERROR: localReadPos %llu >= validFrames %llu\n", s->localReadPos, s->validFrames);
		s->active = false;
		return 0;
	}
	
	ma_uint32 framesRead = 0;
	
	while(framesRead < frameCount && s->active) {
		// Check if we need to refill
		// We want to refill when we're 1.5 seconds into the 2-second audio portion
		ma_uint64 audioProgress = s->localReadPos;
		if(audioProgress >= (PADDING_FRAMES + (BUFFER_FRAMES * 3 / 4))) {
			/*printf("Need to refill: audioProgress=%llu, threshold=%llu\n", 
				   audioProgress, PADDING_FRAMES + (BUFFER_FRAMES * 3 / 4));*/
			refillBufferSafe(index);
			continue; // Start over with new buffer
		}
		
		// Calculate how much we can read
		ma_uint64 available = s->validFrames - s->localReadPos;
		if(available == 0) {
			//printf("No more data available\n");
			s->active = false;
			break;
		}
		
		// Don't read past end of file
		ma_uint64 remainingInFile = g_pDecoderLengths[index] - s->filePosition;
		if(remainingInFile < available) {
			available = remainingInFile;
		}
		
		// Read chunk
		ma_uint32 toRead = (ma_uint32)available;
		if(toRead > (frameCount - framesRead)) {
			toRead = frameCount - framesRead;
		}
		
		// Safety: don't read past buffer
		if(s->localReadPos + toRead > s->validFrames) {
			toRead = (ma_uint32)(s->validFrames - s->localReadPos);
		}
		
		if(toRead == 0) {
			//printf("toRead is 0, stopping\n");
			s->active = false;
			break;
		}
		
		//printf("Reading %u frames from localPos %llu\n", toRead, s->localReadPos);
		
		// Copy data
		float* src = s->pcmBuffer + (s->localReadPos * CHANNEL_COUNT);
		float vol = g_pDecodersVolume[index] * masterVolume;
		
		for(ma_uint32 i = 0; i < toRead * CHANNEL_COUNT; i++) {
			output[framesRead * CHANNEL_COUNT + i] += src[i] * vol;
		}
		
		// Update positions
		s->localReadPos += toRead;
		s->filePosition += toRead;
		framesRead += toRead;
		
		// Check if we've reached end of file
		if(s->filePosition >= g_pDecoderLengths[index]) {
			printf("Reached end of file\n");
			s->active = false;
			break;
		}
	}
	
	//printf("readFromBufferSafe end: read %u frames, new filePosition=%llu\n", framesRead, s->filePosition);
	return framesRead;
}

static inline bool any_active(){
	for(ma_uint32 i=0; i<g_decoderCount; i++) 
		if(g_pStreams[i].active) return true; 
	return false;
}

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount){
	float* pOutputF32 = (float*)pOutput;
	MA_ASSERT(pDevice->playback.format == SAMPLE_FORMAT);
	
	ensure_mutex();
	ma_mutex_lock(&audioMutex);
	
	if(!any_active()){
		memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
		MIXER_STATE = 3;
		ma_mutex_unlock(&audioMutex);
		(void)pInput;
		return;
	}

	if(playbackRate == 1.0f){
		memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
		for(ma_uint32 i=0; i<g_decoderCount; i++){
			if(!g_pStreams[i].active) continue;
			ma_uint32 read = readFromBufferSafe(i, pOutputF32, frameCount);
			if(read == 0) g_pStreams[i].active = false;
		}
	} else {
		float inputMix[4096*CHANNEL_COUNT] = {0};
		float stretchedOutput[4096*CHANNEL_COUNT] = {0};
		ma_uint32 maxFramesToRead = (ma_uint32)(frameCount * playbackRate);
		if(maxFramesToRead > 4096) maxFramesToRead = 4096;
		
		for(ma_uint32 i=0; i<g_decoderCount; i++){
			if(!g_pStreams[i].active) continue;
			ma_uint32 read = readFromBufferSafe(i, inputMix, maxFramesToRead);
			if(read == 0) g_pStreams[i].active = false;
		}
		
		if(any_active()){
			if(stretch == nullptr){
				stretch = new signalsmith::stretch::SignalsmithStretch();
				stretch->presetCheaper(CHANNEL_COUNT, SAMPLE_RATE);
			}
			stretch->process(inputMix, maxFramesToRead, stretchedOutput, frameCount);
			memcpy(pOutputF32, stretchedOutput, sizeof(float)*frameCount*CHANNEL_COUNT);
		} else {
			memset(pOutputF32, 0, sizeof(float)*frameCount*CHANNEL_COUNT);
		}
	}
	
	MIXER_STATE = any_active() ? 1 : 3;
	ma_mutex_unlock(&audioMutex);
	(void)pInput;
}

void deactivate_decoder(int index){
	if(index < (int)g_decoderCount) g_pStreams[index].active = false;
}

void amplify_decoder(int index, double volume){
	g_pDecodersVolume[index] = volume;
}

void setPlaybackRate(float value){
	playbackRate = value;
}

void start(){
	if(exists==0) return;
	if(MIXER_STATE==3) seekToPCMFrame(0);
	ma_device_start(&device);
}

void stop(){
	if(exists==0) return;
	ma_device_stop(&device);
	MIXER_STATE = 2;
}

bool stopped(){
	return MIXER_STATE == 3;
}

void destroy(){
	if(exists==0) return;
	exists = 0;
	ma_device_uninit(&device);
	for(iDecoder=0; iDecoder<g_decoderCount; iDecoder++) 
		ma_decoder_uninit(&g_pDecoders[iDecoder]);
	freeThingies();
	if(stretch){
		delete stretch;
		stretch = nullptr;
	}
	if(mutexInitialized){
		ma_mutex_uninit(&audioMutex);
		mutexInitialized = MA_FALSE;
	}
	deviceExists = MA_FALSE;
}

void loadFiles(std::vector<const char*> argv){
	if(argv.empty()){
		printf("No input files.\n");
		return;
	}
	
	g_decoderCount = argv.size();
	g_pDecoders = (ma_decoder*)malloc(sizeof(*g_pDecoders) * g_decoderCount);
	g_pDecoderLengths = (ma_uint64*)malloc(sizeof(ma_uint64) * g_decoderCount);
	g_pDecodersVolume = (float*)malloc(sizeof(*g_pDecodersVolume) * g_decoderCount);
	g_pStreams = (DecoderStream*)malloc(sizeof(DecoderStream) * g_decoderCount);
	memset(g_pStreams, 0, sizeof(DecoderStream) * g_decoderCount);

	ma_uint64 absoluteLengthOfSong = 0;
	decoderConfig = ma_decoder_config_init(SAMPLE_FORMAT, CHANNEL_COUNT, SAMPLE_RATE);

	for(iDecoder=0; iDecoder<g_decoderCount; iDecoder++){
		const char* path = argv[iDecoder];
		g_pDecodersVolume[iDecoder] = 1.0;
		
		result = ma_decoder_init_file(path, &decoderConfig, &g_pDecoders[iDecoder]);
		if(result != MA_SUCCESS){
			for(ma_uint32 j=0; j<iDecoder; j++) 
				ma_decoder_uninit(&g_pDecoders[j]);
			freeThingies();
			printf("Failed to load %s.\n", argv[iDecoder]);
			exists = 0;
			return;
		}
		
		ma_data_source_set_looping(&g_pDecoders[iDecoder], MA_FALSE);
		ma_decoder_get_length_in_pcm_frames(&g_pDecoders[iDecoder], &g_pDecoderLengths[iDecoder]);
		
		// Allocate PCM buffer
		g_pStreams[iDecoder].pcmBuffer = (float*)malloc(
			sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT
		);
		memset(g_pStreams[iDecoder].pcmBuffer, 0, 
		       sizeof(float) * TOTAL_BUFFER_FRAMES * CHANNEL_COUNT);
		
		// Fill initial buffer
		fillInitialBuffer(iDecoder, 0);
		
		if(g_pDecoderLengths[iDecoder] > absoluteLengthOfSong){
			absoluteLengthOfSong = g_pDecoderLengths[iDecoder];
			g_pLongestDecoderIndex = iDecoder;
		}
		exists = 1;
	}

	deviceConfig = ma_device_config_init(ma_device_type_playback);
	deviceConfig.playback.format = SAMPLE_FORMAT;
	deviceConfig.playback.channels = CHANNEL_COUNT;
	deviceConfig.sampleRate = SAMPLE_RATE;
	deviceConfig.dataCallback = data_callback;
	deviceConfig.pUserData = nullptr;
	deviceConfig.periodSizeInFrames = 256;
	deviceConfig.periods = 2;
	
	if(ma_device_init(nullptr, &deviceConfig, &device) != MA_SUCCESS){
		for(iDecoder=0; iDecoder<g_decoderCount; iDecoder++) 
			ma_decoder_uninit(&g_pDecoders[iDecoder]);
		freeThingies();
		printf("Failed to open playback device.\n");
		return;
	}
	deviceExists = MA_TRUE;
}

double getGlobalVolume(){
	return masterVolume;
}

double setGlobalVolume(double value){
	masterVolume = value;
	return masterVolume;
}

bool wearingHeadphones(){
	#if HX_WINDOWS
	return checkWindowsHeadphoneStatus();
	#else
	return false;
	#endif
}

bool wearingPlugNPlay(){
	#if HX_WINDOWS
	return checkIfPnPDevice();
	#else
	return false;
	#endif
}