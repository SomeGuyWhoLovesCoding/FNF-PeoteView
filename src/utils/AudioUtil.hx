package utils;

// Taken from https://github.com/FunkinCrew/Funkin/blob/fe5b23b369bb9dad0d410f3ae80f53f705668301/source/funkin/util/AudioUtil.hx
import lime.media.AudioManager;

/**
 * Audio engine utilities, such as restarting audio on device change.
 */
#if (windows && cpp)

@:buildXml('
<target id="haxe">
  <lib name="ole32.lib" if="windows"/>
</target>
')
@:cppFileCode('
#include <string>
#include "mmdeviceapi.h"

bool _audioDeviceChanged = false;
class AudioFixClient : public IMMNotificationClient {
  public:

  AudioFixClient() : _refCount(1), _pDeviceEnum(nullptr) {
    HRESULT result = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator), (void**)&_pDeviceEnum);
    if (result == S_OK) _pDeviceEnum->RegisterEndpointNotificationCallback(this);
    updateCurrentDeviceID();
  }

  ~AudioFixClient() {
    if (_pDeviceEnum != nullptr) {
      _pDeviceEnum->UnregisterEndpointNotificationCallback(this);
      _pDeviceEnum->Release();
      _pDeviceEnum = nullptr;
    }
  }

  HRESULT STDMETHODCALLTYPE OnDefaultDeviceChanged(EDataFlow flow, ERole role, LPCWSTR pwstrDefaultDeviceId) {
    if (flow == eRender && role == eConsole && pwstrDefaultDeviceId != nullptr) {
      if (_currentDeviceID.compare(pwstrDefaultDeviceId) != 0) {
        _audioDeviceChanged = true;
      }
    }

    return S_OK;
  }

  ULONG STDMETHODCALLTYPE AddRef() {
    return InterlockedIncrement(&_refCount);
  }

  ULONG STDMETHODCALLTYPE Release() {
    ULONG ulRef = InterlockedDecrement(&_refCount);
    if (0 == ulRef) delete this;
    return ulRef;
  }

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, VOID** ppvInterface) {
    if (IID_IUnknown == riid) {
      AddRef();
      *ppvInterface = (IUnknown*)this;
    } else if (__uuidof(IMMNotificationClient) == riid) {
      AddRef();
      *ppvInterface = (IMMNotificationClient*)this;
    } else {
      *ppvInterface = NULL;
      return E_NOINTERFACE;
    }

    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceAdded(LPCWSTR pwstrDeviceId) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceRemoved(LPCWSTR pwstrDeviceId) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnDeviceStateChanged(LPCWSTR pwstrDeviceId, DWORD dwNewState) {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE OnPropertyValueChanged(LPCWSTR pwstrDeviceId, const PROPERTYKEY key) {
    return S_OK;
  }

  void updateCurrentDeviceID() {
    if (_pDeviceEnum == nullptr) return;
    IMMDevice* _pDevice = nullptr;
    LPWSTR _deviceId = nullptr;
    HRESULT result = _pDeviceEnum->GetDefaultAudioEndpoint(eRender, eConsole, &_pDevice);
    if (SUCCEEDED(result) && _pDevice != nullptr) {
      result = _pDevice->GetId(&_deviceId);
      if (SUCCEEDED(result) && _deviceId != nullptr) {
        _currentDeviceID = _deviceId;
        CoTaskMemFree(_deviceId);
      }

      _pDevice->Release();
    }
  }

  private:

  std::wstring _currentDeviceID;
  IMMDeviceEnumerator* _pDeviceEnum;

  LONG _refCount;
};

AudioFixClient* curAudioFix;
')
#end
@:nullSafety
class AudioUtil
{
  /**
   * Whether the current audio device has changed.
   */
  public static var audioDeviceChanged(get, set):Bool;

  public static function get_audioDeviceChanged():Bool
  {
    return #if (windows && cpp) cast untyped __cpp__('_audioDeviceChanged') #else false #end;
  }

  public static function set_audioDeviceChanged(v:Bool):Bool
  {
    #if (windows && cpp) untyped __cpp__('_audioDeviceChanged = (bool)v;'); #end
    return v;
  }

  private static var initializedAudioFix:Bool = false;

  /**
   * Initializes the audio fix client to handle audio device changes.
   * This should be called once at the start of the application.
   */
  public static function initAudioFix():Void
  {
    if (initializedAudioFix) return;

    #if (windows && cpp) untyped __cpp__('if (curAudioFix == nullptr) curAudioFix = new AudioFixClient();'); #end

    initializedAudioFix = true;
  }

  /**
   * Restarts the audio system and regenerates all sounds.
   */
  public static function restartAudio():Void
  {
    #if (windows && cpp)
    AudioManager.shutdown();
    AudioManager.init();
    #end

    audioDeviceChanged = false;
  }
}