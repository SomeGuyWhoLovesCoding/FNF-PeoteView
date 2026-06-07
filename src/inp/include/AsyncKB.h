#ifndef ASYNC_KB_H
#define ASYNC_KB_H

#ifdef __cplusplus
extern "C" {
#endif

void start(void);
void stop(void);
bool hasEvent(void);
int getScanCode(void);
int getState(void);
double getTimestamp(void);
double getGlobalTimestampComparison(void);

#ifdef __cplusplus
}
#endif

#endif