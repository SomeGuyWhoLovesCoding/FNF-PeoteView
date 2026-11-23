#ifndef CHART_FILE_H
#define CHART_FILE_H
#include <iostream>
#include <vector>
#include <cstdio>
#include <cstdint>

void loadChart(const char* inFile);
int64_t getNote_first8(int64_t atIndex);
int64_t getNote_last4(int64_t atIndex);
int64_t getLength(void);
void destroyChart();
// Primary add API: addNote(position, duration, index, type, lane).
//   position: 100ns ticks (the unit MetaNote.position uses)
//   duration: 1ms ticks (24-bit field, max 16,777,215 ms)
//   index:    column index within the strumline (0..1023, 10-bit field)
//   type:     note type (0..255, still routed through the skin table)
//   lane:     strumline id stored ON the note (0..63, 6-bit field)
// Returns the new note's global chart index — pass it to removeNote().
int64_t addNote(int64_t position, int duration, int index, int type, int lane);
// Legacy alias: the lane is derived from the type (0 → strumline 0, else 1).
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
// The note's precomputed overlap-group size — the 4 extra bytes per chart
// note (runtime-only; the on-disk format is unchanged). 1 = stands alone,
// otherwise the number of notes its merged sprite represents (same
// strumline, receptor column, notetype, duration and quantized speed-2
// timing row). Every group member carries the same value.
int getNoteOverlapCount(int64_t globalIndex);
// Bulk accessor for the note spawner: a pointer into the persistent
// per-note overlap-count block, covering notes [startIndex, endIndex).
// The block is allocated for the whole chart lifetime and freed on chart
// destroy; entries are uint32 (4 bytes per note). The pointer is valid
// until the next chart mutation (addNote/removeNote) — refetch per pass.
uint32_t* getNotesFromRange(int64_t startIndex, int64_t endIndex);
//void destroyAllJudgements(void);
#endif /* CHART_FILE_H */
