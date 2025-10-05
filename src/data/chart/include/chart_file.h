#ifndef CHART_FILE_H
#define CHART_FILE_H
#include <iostream>
#include <vector>
#include <cstdio>
#include <cstdint>

bool remap(int64_t newLength);
void loadChart(const char* inFile);
int64_t getNote(int64_t atIndex);
int64_t getLength(void);
void destroyChart();
void insertNote(int64_t index, int64_t value);
void removeNote(int64_t index);
void setNote(int64_t index, int64_t value); // glad I found a use for this stupid function already
void insertNotes(std::vector<int64_t> index);
void removeNotes(std::vector<int64_t> index);
void resetGetNoteLookup(void);
#endif /* CHART_FILE_H */