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
//void destroyAllJudgements(void);

// === Two-dimensional judgement system (N lane rows x M note-index bits) ===
// 1 bit per (lane, global note index), packed 64 indexes per word, persistent
// for the chart's lifetime and grown geometrically (never per call).
//   lane:  strumline row — the note's stored lane, clamped by the caller
//   index: global chart note index
bool getJudgement2D(int32_t lane, int64_t index);
void setJudgement2D(int32_t lane, int64_t index, bool value);
// Bulk set/clear of an index RANGE on one lane's row (word-aligned fills).
// Other lanes' notes interleaved inside the span keep their own bits.
void registerJudgementRange(int32_t lane, int64_t fromIndex, int64_t toIndex, bool value);
// Clears every judgement bit (fresh judgement state).
void clearJudgements(void);

// === getNotesFromRange (persistent result block + custom length) ===
// Collects the global indexes in [fromIndex .. toIndex] whose note belongs
// to (lane, index) — the exact member list of an ambient-occluded visual
// note. Results are written into a PERSISTENT memory block (reused across
// calls, grown geometrically) that tracks its own custom length variable;
// the return value is that length and getRangeNoteAt() reads entries back
// with zero allocation. strumlineCount clamps stored lanes like the engine.
int32_t getNotesFromRange(int32_t strumlineCount, int32_t lane, int32_t index,
    int64_t fromIndex, int64_t toIndex);
int64_t getRangeNoteAt(int32_t at);
#endif /* CHART_FILE_H */
