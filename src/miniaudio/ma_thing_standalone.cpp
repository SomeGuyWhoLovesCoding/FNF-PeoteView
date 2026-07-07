/*
 * ma_thing_standalone.cpp
 * Plain C++ global interface — links against ma_thing_core.h.
 * No HashLink dependency. 
 */

// These implementation macros must be defined in exactly one translation unit.
// signalsmith must be included first — see ma_thing_core.h for explanation.
#define SIGNALSMITH_STRETCH_IMPLEMENTATION
#include "signalsmith-stretch/signalsmith-stretch.h"

#define STB_VORBIS_IMPLEMENTATION
#define MINIAUDIO_IMPLEMENTATION

#include "ma_thing_core.h"

namespace {
    AudioSystem      g_audioSystem;
    AudioMixerManager g_mixer;
}

// ---- AudioSystem ---------------------------------------------------------

void loadFiles(std::vector<const char*> argv)  { g_audioSystem.loadFiles(argv); }
void start()                                   { g_audioSystem.start(); }
void stop()                                    { g_audioSystem.stop(); }
bool stopped()                                 { return g_audioSystem.stopped(); }
void destroy()                                 { g_audioSystem.destroy(); }
void seekToPCMFrame(int64_t pos)               { g_audioSystem.seekToPCMFrame(pos); }
int  getMixerState()                           { return g_audioSystem.getMixerState(); }
double getPlaybackPosition()                   { return g_audioSystem.getPlaybackPosition(); }
double getDuration()                           { return g_audioSystem.getDuration(); }
void deactivate_decoder(int index)             { g_audioSystem.deactivate_decoder(index); }
void amplify_decoder(int index, double volume) { g_audioSystem.amplify_decoder(index, volume); }
void setPlaybackRate(float value)              { g_audioSystem.setPlaybackRate(value); }
double getGlobalVolume()                       { return g_audioSystem.getGlobalVolume(); }
double setGlobalVolume(double value)           { return g_audioSystem.setGlobalVolume(value); }

int detectLatency() {
    int osMs = 50;
    osMs += 20; // due to buffer size
    return osMs;
}

// ---- AudioMixerManager ---------------------------------------------------

int  loadBackgroundTrack(const char* path)                    { return g_mixer.loadBackgroundTrack(path); }
void playBackgroundTrack(int index)                           { g_mixer.playBackgroundTrack(index); }
void stopBackgroundTrack(int index)                           { g_mixer.stopBackgroundTrack(index); }
void setBackgroundTrackVolume(int index, double volume)        { g_mixer.setBackgroundTrackVolume(index, volume); }
void setBackgroundTrackLooping(int index, bool looping)       { g_mixer.setBackgroundTrackLooping(index, looping); }
bool isBackgroundTrackPlaying(int index)                      { return g_mixer.isBackgroundTrackPlaying(index); }

int  loadSoundEffect(const char* path)                        { return g_mixer.loadSoundEffect(path); }
void playSoundEffect(int index, double volume)                 { g_mixer.playSoundEffect(index, volume); }
void stopSoundEffect(int index)                               { g_mixer.stopSoundEffect(index); }
bool isSoundEffectPlaying(int index)                          { return g_mixer.isSoundEffectPlaying(index); }

double setMixerMasterVolume(double volume)  { return g_mixer.setMasterVolume(volume); }
double getMixerMasterVolume()              { return g_mixer.getMasterVolume(); }
void  destroyMixer()                      { g_mixer.destroy(); }