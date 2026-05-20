#ifndef CHART_FILE_H
#define CHART_FILE_H
#include <iostream>
#include <vector>
#include <cstdio>
#include <cstdint>

void loadChart(const char* inFile);
int64_t getNote(int64_t atIndex);
int64_t getLength(void);
void destroyChart();
void setNote(int64_t index, int64_t value); // glad I found a use for this stupid function already
int64_t getTimeCorrectionForIndex(int64_t index);
bool isNoteHit(int64_t atIndex);
void setNoteHit(int64_t atIndex, bool value);
bool isNoteMissed(int64_t atIndex);
void setNoteMissed(int64_t atIndex, bool value);
bool isNoteHeld(int64_t atIndex);
void setNoteHeld(int64_t atIndex, bool value);
void clearJudgement(void);
#endif /* CHART_FILE_H */