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
#endif /* CHART_FILE_H */