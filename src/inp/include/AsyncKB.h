#ifndef ASYNC_KB_H
#define ASYNC_KB_H

#ifdef __cplusplus
extern "C" {
#endif

void start(void);
void stop(void);
bool hasEvent(void);
double getScanCode(void);
double getState(void);
double getTimestamp(void);

#ifdef __cplusplus
}
#endif

#endif