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

// === Judgement state (per-shard, in-RAM, flat) ===
// Every shard owns its own flat judgement bit array: allocated freshly
// zeroed when the shard opens, kept index-aligned across note
// inserts/removes, and destroyed when the shard closes — so a shard that
// leaves the LRU window and comes back is automatically un-judged.
//   getJudgement/setJudgement: the flat per-note bits (shard-relative)
// clearJudgements: zeroes the judgement bits of the ACTIVE shards only
// (closed shards have no state; they reopen freshly zeroed).
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

// === Bulk edit API (v3.5) — stage, then commit ONE call ===
// The editor's batch gestures (paste, delete-selection, undo/redo of
// either) stage their notes/ranges first, then commit with ONE call that
// crosses the FFI once instead of once per note.
//   stageNote:      queue one note's raw fields (same units as addNote).
//   addNotes:       commit every staged note in ONE locked pass, ascending
//                   by position (ties keep staging order). Returns the
//                   number added and fills the ADDED-RANGE BLOCK: the
//                   exact final global indexes of the newly added notes as
//                   inclusive, coalesced [lo..hi] ranges (see below).
//   stageRemovalRange: queue one inclusive [lo..hi] id range to remove.
//   removeNotesFromRangeArray: commit every staged range as ONE call —
//                   the ranges are normalized (sorted, touching/overlapping
//                   merged, clamped) so an id can never be removed twice,
//                   then walked highest-first. Returns the count removed.
//   clearStaged:    drop everything staged (an aborted gesture).
//
// === The exact-index guarantee of addNotes ===
// A per-note add() return id goes stale the moment a later add lands at or
// below it. addNotes() instead records, per equal-position group, the
// FIRST member's returned id r and the group size m — the group occupies
// EXACTLY [r .. r+m-1], final and unshiftable: later groups insert above,
// never into, that range (greater positions land after it; smaller
// positions land before it, and the range's ids only ever get RELATIVELY
// shifted by baseId re-centers, not invalidated). THE EXACT FINAL IDS of
// the paste are therefore knowable in advance — this is what makes
// undoing a paste 100% correct by index, no field re-resolution needed.
int32_t getAddedRangeCount(void);
int64_t getAddedRangeLo(int32_t at);
int64_t getAddedRangeHi(int32_t at);
void stageNote(int64_t position, int duration, int index, int type, int lane);
int32_t addNotes(void);
void stageRemovalRange(int64_t lo, int64_t hi);
int32_t removeNotesFromRangeArray(void);
void clearStaged(void);
#endif /* CHART_FILE_H */
