/*
 * ma_thing_hl.cpp
 * HashLink binding layer — wraps ma_thing_core.h for use from Haxe/HL.
 * No standalone / plain-C++ interface here; see ma_thing_standalone.cpp.
 */

// These implementation macros must be defined in exactly one translation unit.
// signalsmith must be included first — see ma_thing_core.h for explanation.
#define SIGNALSMITH_STRETCH_IMPLEMENTATION
#include "signalsmith-stretch/signalsmith-stretch.h"

#define STB_VORBIS_IMPLEMENTATION
#define MINIAUDIO_IMPLEMENTATION

// HL header must come before any Windows headers that stb_vorbis might pull
// in, but after the implementation defines above.
#define HL_NAME(n) ma_thing_##n
#include <hl.h>

#include "ma_thing_core.h"

namespace {
    AudioSystem       g_audioSystem;
    AudioMixerManager g_mixer;
}

// ---- AudioSystem primitives ----------------------------------------------

HL_PRIM void HL_NAME(loadFiles)(varray* argv) {
    std::vector<const char*> paths;
    paths.reserve(argv->size);
    for (int i = 0; i < argv->size; i++)
        paths.push_back(hl_aptr(argv, const char*)[i]);
    g_audioSystem.loadFiles(paths);
}

HL_PRIM void HL_NAME(start)(_NO_ARG)  { g_audioSystem.start(); }
HL_PRIM void HL_NAME(stop)(_NO_ARG)   { g_audioSystem.stop(); }
HL_PRIM bool HL_NAME(stopped)(_NO_ARG){ return g_audioSystem.stopped(); }
HL_PRIM void HL_NAME(destroy)(_NO_ARG){ g_audioSystem.destroy(); }

HL_PRIM void   HL_NAME(seek_to_pcm_frame)(int64_t pos) { g_audioSystem.seekToPCMFrame(pos); }
HL_PRIM int    HL_NAME(get_mixer_state)(_NO_ARG)        { return g_audioSystem.getMixerState(); }
HL_PRIM double HL_NAME(get_playback_position)(_NO_ARG)  { return g_audioSystem.getPlaybackPosition(); }
HL_PRIM double HL_NAME(get_duration)(_NO_ARG)           { return g_audioSystem.getDuration(); }

HL_PRIM void   HL_NAME(deactivate_decoder)(int index)            { g_audioSystem.deactivate_decoder(index); }
HL_PRIM void   HL_NAME(amplify_decoder)(int index, double volume){ g_audioSystem.amplify_decoder(index, volume); }
HL_PRIM void   HL_NAME(setPlaybackRate)(float value)             { g_audioSystem.setPlaybackRate(value); }
HL_PRIM double HL_NAME(getGlobalVolume)(_NO_ARG)                 { return g_audioSystem.getGlobalVolume(); }
HL_PRIM double HL_NAME(setGlobalVolume)(double value)            { return g_audioSystem.setGlobalVolume(value); }

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

// Calls the underlying C++ functions directly — not the HL primitives above.
HL_PRIM int HL_NAME(detectLatency)(_NO_ARG) {
#if HX_WINDOWS
    int osMs = 50;
#else
    int osMs = 10;
#endif
    if (g_audioSystem.exists) {
#ifdef HX_WINDOWS
        if (!checkIfPnPDevice())          osMs += 50;
        if (checkWindowsHeadphoneStatus()) osMs += 50;
#endif
    }
    return osMs;
}

// ---- AudioMixerManager primitives ----------------------------------------

HL_PRIM int  HL_NAME(loadBackgroundTrack)(vstring* path)                   { return g_mixer.loadBackgroundTrack(hl_to_utf8(path->bytes)); }
HL_PRIM void HL_NAME(playBackgroundTrack)(int index)                       { g_mixer.playBackgroundTrack(index); }
HL_PRIM void HL_NAME(stopBackgroundTrack)(int index)                       { g_mixer.stopBackgroundTrack(index); }
HL_PRIM void HL_NAME(setBackgroundTrackVolume)(int index, float volume)    { g_mixer.setBackgroundTrackVolume(index, volume); }
HL_PRIM void HL_NAME(setBackgroundTrackLooping)(int index, bool looping)   { g_mixer.setBackgroundTrackLooping(index, looping); }
HL_PRIM bool HL_NAME(isBackgroundTrackPlaying)(int index)                  { return g_mixer.isBackgroundTrackPlaying(index); }

HL_PRIM int  HL_NAME(loadSoundEffect)(vstring* path)                       { return g_mixer.loadSoundEffect(hl_to_utf8(path->bytes)); }
HL_PRIM void HL_NAME(playSoundEffect)(int index, float volume)             { g_mixer.playSoundEffect(index, volume); }
HL_PRIM void HL_NAME(stopSoundEffect)(int index)                           { g_mixer.stopSoundEffect(index); }
HL_PRIM bool HL_NAME(isSoundEffectPlaying)(int index)                      { return g_mixer.isSoundEffectPlaying(index); }

HL_PRIM void  HL_NAME(setMixerMasterVolume)(float volume)  { g_mixer.setMasterVolume(volume); }
HL_PRIM float HL_NAME(getMixerMasterVolume)(_NO_ARG)       { return g_mixer.getMasterVolume(); }
HL_PRIM void  HL_NAME(destroyMixer)(_NO_ARG)               { g_mixer.destroy(); }

// ---- DEFINE_PRIM declarations --------------------------------------------

DEFINE_PRIM(_VOID, loadFiles,              _ARR)
DEFINE_PRIM(_VOID, start,                  _NO_ARG)
DEFINE_PRIM(_VOID, stop,                   _NO_ARG)
DEFINE_PRIM(_BOOL, stopped,                _NO_ARG)
DEFINE_PRIM(_VOID, destroy,                _NO_ARG)
DEFINE_PRIM(_VOID, seek_to_pcm_frame,      _I64)
DEFINE_PRIM(_I32,  get_mixer_state,        _NO_ARG)
DEFINE_PRIM(_F64,  get_playback_position,  _NO_ARG)
DEFINE_PRIM(_F64,  get_duration,           _NO_ARG)
DEFINE_PRIM(_VOID, deactivate_decoder,     _I32)
DEFINE_PRIM(_VOID, amplify_decoder,        _I32 _F64)
DEFINE_PRIM(_VOID, setPlaybackRate,        _F32)
DEFINE_PRIM(_F64,  getGlobalVolume,        _NO_ARG)
DEFINE_PRIM(_F64,  setGlobalVolume,        _F64)
DEFINE_PRIM(_BOOL, wearingHeadphones,      _NO_ARG)
DEFINE_PRIM(_BOOL, wearingPlugNPlay,       _NO_ARG)
DEFINE_PRIM(_I32,  detectLatency,          _NO_ARG)

DEFINE_PRIM(_I32,  loadBackgroundTrack,       _STRING)
DEFINE_PRIM(_VOID, playBackgroundTrack,       _I32)
DEFINE_PRIM(_VOID, stopBackgroundTrack,       _I32)
DEFINE_PRIM(_VOID, setBackgroundTrackVolume,  _I32 _F32)
DEFINE_PRIM(_VOID, setBackgroundTrackLooping, _I32 _BOOL)
DEFINE_PRIM(_BOOL, isBackgroundTrackPlaying,  _I32)
DEFINE_PRIM(_I32,  loadSoundEffect,           _STRING)
DEFINE_PRIM(_VOID, playSoundEffect,           _I32 _F32)
DEFINE_PRIM(_VOID, stopSoundEffect,           _I32)
DEFINE_PRIM(_BOOL, isSoundEffectPlaying,      _I32)
DEFINE_PRIM(_VOID, setMixerMasterVolume,      _F32)
DEFINE_PRIM(_F32,  getMixerMasterVolume,      _NO_ARG)
DEFINE_PRIM(_VOID, destroyMixer,              _NO_ARG)
