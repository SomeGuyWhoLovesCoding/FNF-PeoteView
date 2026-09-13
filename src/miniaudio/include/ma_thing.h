#ifndef MA_THING_H
#define MA_THING_H
#include <vector>
#include <stdint.h>

// Main stuff
int detectLatency(void);
int getMixerState(void);
double getPlaybackPosition(void);
double getDuration(void);
void seekToPCMFrame(int64_t pos);
void deactivate_decoder(int index);
void amplify_decoder(int index, double volume);
void setPlaybackRate(float value);
void setStretchEnabled(bool enabled);

// Surround sound system (AudioSampleUnified).  Toggles the song mixer
// between stereo (2 channels) and Surround Sound 3.1 (4 channels:
// FL/FR/C/LFE) and routes decoder streams (inst, voices, ...) into the
// channel buses identified by MaThingAudioChannel in ma_thing_core.h.
void setSurroundEnabled(bool enabled);
bool isSurroundEnabled(void);
void setStreamChannel(int index, int channel);
int  getStreamChannel(int index);
void destroy(void);
void start(void);
void stop(void);
bool stopped(void);
void loadFiles(std::vector<const char*> argv);

double getGlobalVolume();
double setGlobalVolume(double value);

// And now the rest
int loadBackgroundTrack(const char* path);
void playBackgroundTrack(int index);
void stopBackgroundTrack(int index);
void setBackgroundTrackVolume(int index, double volume);
void setBackgroundTrackLooping(int index, bool looping);
bool isBackgroundTrackPlaying(int index);

// Sound effect functions
int loadSoundEffect(const char* path);
void playSoundEffect(int index, double volume);
void stopSoundEffect(int index);
bool isSoundEffectPlaying(int index);

// Volume control
double setMixerMasterVolume(double volume);
double getMixerMasterVolume();

void destroyMixer(void);
#endif /* MA_THING_H */
