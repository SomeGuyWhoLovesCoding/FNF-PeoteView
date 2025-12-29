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
void destroy(void);
void start(void);
void stop(void);
bool stopped(void);
void loadFiles(std::vector<const char*> argv);

double getGlobalVolume();
double setGlobalVolume(double value);

bool wearingHeadphones();
bool wearingPlugNPlay();

// And now the rest
int loadBackgroundTrack(const char* path, bool startPlaying);
void playBackgroundTrack(int index);
void stopBackgroundTrack(int index);
void setBackgroundTrackVolume(int index, float volume);
void setBackgroundTrackLooping(int index, bool looping);
bool isBackgroundTrackPlaying(int index);

// Sound effect functions
int loadSoundEffect(const char* path);
void playSoundEffect(int index, float volume);
void stopSoundEffect(int index);
bool isSoundEffectPlaying(int index);

// Volume control
void setMixerMasterVolume(float volume);
float getMixerMasterVolume();

void destroyMixer(void);
#endif /* MA_THING_H */
