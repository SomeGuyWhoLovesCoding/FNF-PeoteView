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
#endif /* CHART_FILE_H */