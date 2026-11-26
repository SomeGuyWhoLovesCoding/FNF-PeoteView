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

// === Mirror API (v3.7) — in-place column flip, undo = same call again ===
// mirrorNotesFromSelectionRanges rewrites the 10-bit column index of
// every note whose global id sits in a staged mirror range: index :=
// indexLo + indexHi - index (an INVOLUTION — running it twice returns
// every note to its original column). In-place: no note is added or
// removed, ids never move (the store orders by position only), so the
// selection (a set of ids) survives untouched and UNDO/REDO simply
// replay the same call on the same ranges — "mirror the notes back".
//   stageMirrorRange: queue one inclusive [lo..hi] id range to mirror.
//   mirrorNotesFromSelectionRanges: commit every staged range as ONE
//                  locked pass (ranges are NOT normalized — mirror is
//                  an involution per note, so double-staging an id
//                  flips it twice = back to the original column; and
//                  ranges are clamped to the store bounds only).
//                  Returns the number of notes flipped.
//   indexLo/indexHi: the SELECTION's column-index bounds — the mirror
//                  axis pair (e.g. a 4K selection over columns 1..4
//                  flips 1<->4, 2<->3; pass the full mania for a
//                  whole-strumline mirror).
int32_t mirrorNotesFromSelectionRanges(int32_t indexLo, int32_t indexHi);
void stageMirrorRange(int64_t lo, int64_t hi);

// === Shift API (v3.8) — in-place column/lane move (Alt+arrows) ===
// shiftNotesFromSelectionRanges rewrites the 10-bit column index and the
// 6-bit lane of every note whose global id sits in a staged shift
// range: column := wrapMod(column + dIndex, mania), lane :=
// wrapMod(lane + dLane, strumlineCount) — the exact landing discipline
// of the paste (non-negative modulo wrap, "wrap it around the same way
// you'd bulk-add for paste"). In place: no note is added or removed,
// ids never move, so the selection survives untouched; UNDO/REDO
// replay the inverse delta (-dIndex, -dLane) on the same ranges.
//   stageShiftRange: queue one inclusive [lo..hi] id range to shift.
//   Returns the number of notes shifted.
int32_t shiftNotesFromSelectionRanges(int32_t dIndex, int32_t dLane,
    int32_t mania, int32_t strumlineCount);
void stageShiftRange(int64_t lo, int64_t hi);

// === GTFR — Generate Notes From Range (v3.9.0 note-spawn protocol) ===
// The virtual-note render state lives in the chart extern (packed,
// grow-only arenas — see chart_file_core.cpp). The host drives an
// exactly-once loop; NOTE returns the packed first8 (the bits MetaNote
// decodes), INDEX the store id of that same note, RECYCLE the drop of
// that id's dead bindings. head/tail live here — the host's start/end
// loop variables are loop decoration.
void   gtfrStart(int64_t startIndex, int64_t endIndex);
// The render frame boundary: resets the touched column chains (the
// next sweep's binds re-thread). Bindings and the free list are kept.
void   gtfrFrameBegin(void);
bool   gtfrProgress(int64_t start, int64_t end);
int64_t gtfrNoteThenAdvance(void);
int64_t gtfrIndexThenAdvance(void);
// The last4 of the note NOTE handed out this body — read WITHOUT
// advancing, so the host builds the MetaNote decode struct from the
// same note (position|duration-low16 from NOTE, duration-high8|index|
// type|lane from here).
uint32_t gtfrNoteLast4(void);
void   gtfrVirtualNoteRecycle(void);
// Host-side bind of computed render state (slot keyed by the note's
// global id; reused in place, popped from the free list, or grown).
void   gtfrBindNote(int64_t gidx, int32_t diff, int32_t sx, int32_t sy,
    float initialAlpha, float addedAlpha, float scale,
    int32_t notesInOne, bool sustainExists, bool judged,
    bool hitFlag, int32_t lane);
void   gtfrBindSustain(int64_t gidx, int32_t diff, int32_t sx, int32_t sy,
    int32_t w, int32_t length, float alpha, float speed,
    float scale, float r);
// Arena reads: capacity + raw word pointers (packed 4-word note slots,
// 6-word sustain slots; -1 in the gidx word marks a free slot).
int64_t  gtfrNoteSlots(void);
int64_t  gtfrSustainSlots(void);
const int64_t* gtfrNoteData(void);
const int64_t* gtfrSustainData(void);
// Column-chain access for the AO fold walk: head slot of a (lane,
// index) column and the next-slot link of any slot (chained at bind
// time; chains reset per frame by gtfrFrameBegin).
int32_t gtfrColumnHead(int32_t lane, int32_t index);
int32_t gtfrSlotNext(int32_t slot);
#endif /* CHART_FILE_H */
