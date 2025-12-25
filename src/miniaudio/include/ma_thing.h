#ifndef MA_THING_H
#define MA_THING_H
#include <vector>
#include <stdint.h>

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
#endif /* MA_THING_H */
