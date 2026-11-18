#ifndef CHART_FILE_H
#define CHART_FILE_H
#include <iostream>
#include <vector>
#include <cstdio>
#include <cstdint>

void loadChart(const char* inFile);
int64_t getNote_first8(int64_t atIndex);
int64_t getNote_last2(int64_t atIndex);
int64_t getLength(void);
void destroyChart();
// Primary add API: addNote(position, duration, index, type).
//   position: 100ns ticks (the unit MetaNote.position uses)
//   duration: 1ms ticks
//   index:    column index within the strumline (0..mania-1)
//   type:     note type (gameplay maps type % strumlineCount to a strumline)
// Returns the new note's global chart index — pass it to removeNote().
int64_t addNote(int64_t position, int duration, int index, int type);
// Legacy alias for addNote(position, duration, index, type).
void insertNote(int64_t globalPosition, int duration, int index, int type);
// Remove by global chart index (the id addNote returned).
void removeNote(int64_t id);
bool saveChart(void);
int64_t getTimeCorrectionForIndex(int64_t index);
bool getJudgement(int64_t globalIndex);
void setJudgement(int64_t globalIndex, bool value);
bool getHitFlag(int64_t globalIndex);
void setHitFlag(int64_t globalIndex, bool value);
void setEditorMode(bool value);
//void destroyAllJudgements(void);
#endif /* CHART_FILE_H */
