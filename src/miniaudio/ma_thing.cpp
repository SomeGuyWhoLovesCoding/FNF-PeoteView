/*
	* Full audio engine with time-stretching.
	* Threading removed; everything synchronous.
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

signalsmith::stretch::SignalsmithStretch* stretch = nullptr;

ma_uint32   g_decoderCount;
ma_decoder* g_pDecoders;
ma_bool32*  g_pDecodersActive;
ma_uint64*  g_pDecoderLengths;
int         g_pLongestDecoderIndex;
float*      g_pDecodersVolume;
float       playbackRate = 1;
double      masterVolume = 1;

int MIXER_STATE = 3;
int exists = 0;

ma_result result;
ma_decoder_config decoderConfig;
ma_device_config  deviceConfig;
ma_device         device;
ma_bool32 deviceExists = MA_FALSE;
ma_uint32 iDecoder;

ma_mutex decoderMutex;
ma_bool32 decoderMutexInitialized = MA_FALSE;

static inline void ensure_mutex() {
	if(!decoderMutexInitialized){ma_mutex_init(&decoderMutex);decoderMutexInitialized=MA_TRUE;}
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
	ma_uint64 pos=0; ensure_mutex(); ma_mutex_lock(&decoderMutex);
	if(g_pDecodersActive[g_pLongestDecoderIndex]==MA_TRUE) ma_decoder_get_cursor_in_pcm_frames(&g_pDecoders[g_pLongestDecoderIndex],&pos);
	else pos=g_pDecoderLengths[g_pLongestDecoderIndex];
	ma_mutex_unlock(&decoderMutex);
	return ((double)pos/(SAMPLE_RATE*0.001));
}
double getDuration(){ return (double)g_pDecoderLengths[g_pLongestDecoderIndex]/(SAMPLE_RATE*0.001); }

void seekToPCMFrame(int64_t pos){
	if(exists==0) return; ensure_mutex(); ma_mutex_lock(&decoderMutex);
	bool anyActive=false;
	for(iDecoder=0;iDecoder<g_decoderCount;iDecoder++){
		ma_uint64 len=g_pDecoderLengths[iDecoder]; ma_uint64 target=0;
		if(pos<=0) target=0;
		else if((ma_uint64)pos>=len) target=len;
		else target=(ma_uint64)pos;
		ma_decoder_seek_to_pcm_frame(&g_pDecoders[iDecoder],target);
		g_pDecodersActive[iDecoder]=(target<len)?MA_TRUE:MA_FALSE;
		if(target<len) anyActive=true;
	}
	ma_mutex_unlock(&decoderMutex);
	MIXER_STATE=anyActive?2:3;
}

void freeThingies(){free(g_pDecoders); free(g_pDecodersActive); free(g_pDecoderLengths); free(g_pDecodersVolume);}

ma_uint32 read_pcm_frames_f32(ma_uint32 index,float* pBuffer,ma_uint32 frameCount){
	ma_decoder* pDecoder=&g_pDecoders[index]; float temp[4096]; ma_uint32 tempCapInFrames=4096/CHANNEL_COUNT; ma_uint32 totalFramesRead=0; memset(temp,0,sizeof(temp));
	while(totalFramesRead<frameCount){
		ma_uint64 framesReadThisIteration; ma_uint32 totalFramesRemaining=frameCount-totalFramesRead; ma_uint32 framesToReadThisIteration=(totalFramesRemaining<tempCapInFrames)?totalFramesRemaining:tempCapInFrames;
		ma_result result=ma_decoder_read_pcm_frames(pDecoder,temp,framesToReadThisIteration,&framesReadThisIteration);
		if(result!=MA_SUCCESS || framesReadThisIteration==0) break;
		for(ma_uint64 i=0;i<framesReadThisIteration*CHANNEL_COUNT;i++) pBuffer[totalFramesRead*CHANNEL_COUNT+i]+=(temp[i]*g_pDecodersVolume[index])*masterVolume;
		totalFramesRead+=(ma_uint32)framesReadThisIteration;
		if(framesReadThisIteration<framesToReadThisIteration) break;
	}
	return totalFramesRead;
}

static inline bool any_active(){for(ma_uint32 i=0;i<g_decoderCount;i++) if(g_pDecodersActive[i]) return true; return false;}

void data_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount){
	float* pOutputF32=(float*)pOutput; MA_ASSERT(pDevice->playback.format==SAMPLE_FORMAT);
	if(!any_active()){memset(pOutputF32,0,sizeof(float)*frameCount*CHANNEL_COUNT); MIXER_STATE=3; (void)pInput; return;}

	if(playbackRate==1.0f){
		memset(pOutputF32,0,sizeof(float)*frameCount*CHANNEL_COUNT);
		for(ma_uint32 i=0;i<g_decoderCount;i++){if(!g_pDecodersActive[i]) continue; ensure_mutex(); ma_mutex_lock(&decoderMutex); ma_uint32 framesRead=read_pcm_frames_f32(i,pOutputF32,frameCount); ma_mutex_unlock(&decoderMutex); if(framesRead==0) g_pDecodersActive[i]=MA_FALSE;}
	}else{
		float inputMix[4096*CHANNEL_COUNT]={0}; float stretchedOutput[4096*CHANNEL_COUNT]={0};
		ma_uint32 maxFramesToRead=(ma_uint32)(frameCount*playbackRate); if(maxFramesToRead>4096) maxFramesToRead=4096;
		for(ma_uint32 i=0;i<g_decoderCount;i++){if(!g_pDecodersActive[i]) continue; ensure_mutex(); ma_mutex_lock(&decoderMutex); ma_uint32 framesRead=read_pcm_frames_f32(i,inputMix,maxFramesToRead); ma_mutex_unlock(&decoderMutex); if(framesRead==0) g_pDecodersActive[i]=MA_FALSE;}
		if(any_active()){if(stretch==nullptr){stretch=new signalsmith::stretch::SignalsmithStretch(); stretch->presetCheaper(CHANNEL_COUNT,SAMPLE_RATE);}
			stretch->process(inputMix,maxFramesToRead,stretchedOutput,frameCount); memcpy(pOutputF32,stretchedOutput,sizeof(float)*frameCount*CHANNEL_COUNT);}
		else memset(pOutputF32,0,sizeof(float)*frameCount*CHANNEL_COUNT);
	}

	if(!any_active()) MIXER_STATE=3;
	MIXER_STATE=1;
	(void)pInput;
}

void deactivate_decoder(int index){if(index<g_decoderCount) g_pDecodersActive[index]=MA_FALSE;}
void amplify_decoder(int index,double volume){g_pDecodersVolume[index]=volume;}
void setPlaybackRate(float value){playbackRate=value;} // simplified, no stretching adjustment
void start(){if(exists==0) return; if(MIXER_STATE==3) seekToPCMFrame(0); ma_device_start(&device);}
void stop(){if(exists==0) return; ma_device_stop(&device); MIXER_STATE=2;}
bool stopped(){return MIXER_STATE==3;}
void destroy(){
	if(exists==0) return; exists=0;
	ma_device_uninit(&device);
	for(iDecoder=0;iDecoder<g_decoderCount;iDecoder++) ma_decoder_uninit(&g_pDecoders[iDecoder]);
	freeThingies();
	if(stretch){delete stretch; stretch=nullptr;}
	if(decoderMutexInitialized){ma_mutex_uninit(&decoderMutex); decoderMutexInitialized=MA_FALSE;}
	deviceExists=MA_FALSE;
}

void loadFiles(std::vector<const char*> argv){
	if(argv.empty()){printf("No input files.\n"); return;}
	g_decoderCount=argv.size(); g_pDecoders=(ma_decoder*)malloc(sizeof(*g_pDecoders)*g_decoderCount);
	g_pDecodersActive=(ma_bool32*)malloc(sizeof(ma_bool32)*g_decoderCount);
	g_pDecoderLengths=(ma_uint64*)malloc(sizeof(ma_uint64)*g_decoderCount);
	g_pDecodersVolume=(float*)malloc(sizeof(*g_pDecodersVolume)*g_decoderCount);

	ma_uint64 absoluteLengthOfSong=0;
	decoderConfig=ma_decoder_config_init(SAMPLE_FORMAT,CHANNEL_COUNT,SAMPLE_RATE);

	for(iDecoder=0;iDecoder<g_decoderCount;iDecoder++){
		const char* path=argv[iDecoder]; g_pDecodersVolume[iDecoder]=1.0;
		result=ma_decoder_init_file(path,&decoderConfig,&g_pDecoders[iDecoder]);
		if(result!=MA_SUCCESS){ for(ma_uint32 j=0;j<iDecoder;j++) ma_decoder_uninit(&g_pDecoders[j]); freeThingies(); printf("Failed to load %s.\n",argv[iDecoder]); exists=0; return;}
		ma_data_source_set_looping(&g_pDecoders[iDecoder],MA_FALSE); g_pDecodersActive[iDecoder]=MA_TRUE;
		ma_decoder_get_length_in_pcm_frames(&g_pDecoders[iDecoder],&g_pDecoderLengths[iDecoder]);
		if(g_pDecoderLengths[iDecoder]>absoluteLengthOfSong){absoluteLengthOfSong=g_pDecoderLengths[iDecoder]; g_pLongestDecoderIndex=iDecoder;}
		exists=1;
	}

	deviceConfig=ma_device_config_init(ma_device_type_playback);
	deviceConfig.playback.format=SAMPLE_FORMAT; deviceConfig.playback.channels=CHANNEL_COUNT; deviceConfig.sampleRate=SAMPLE_RATE;
	deviceConfig.dataCallback=data_callback; deviceConfig.pUserData=nullptr; deviceConfig.periodSizeInFrames=256; deviceConfig.periods=2;
	if(ma_device_init(nullptr,&deviceConfig,&device)!=MA_SUCCESS){for(iDecoder=0;iDecoder<g_decoderCount;iDecoder++) ma_decoder_uninit(&g_pDecoders[iDecoder]); freeThingies(); printf("Failed to open playback device.\n"); return;}
	deviceExists=MA_TRUE;
}

double getGlobalVolume(){return masterVolume;}
double setGlobalVolume(double value){masterVolume=value; return masterVolume;}
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
