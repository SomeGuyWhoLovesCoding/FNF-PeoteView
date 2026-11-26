// Include the core implementation.
#include "chart_file_core.cpp"

// ============================================================================
// Global API (C++ interface)
// ============================================================================

void loadChart(const char* path) {
    core_loadChart(path);
}

void destroyChart() {
    core_destroyChart();
}

int64_t getNote_first8(int64_t index) {
    return core_getNote_first8(index);
}

int64_t getNote_last4(int64_t index) {
    return (int64_t)core_getNote_last4(index);
}

int64_t addNote(int64_t position, int duration, int index, int type, int lane) {
    return core_addNote(position, duration, index, type, lane);
}

void insertNote(int64_t globalPosition, int duration, int index, int type) {
    core_insertNote(globalPosition, duration, index, type);
}

void removeNote(int64_t globalIndex) {
    core_removeNote(globalIndex);
}

bool saveChart() {
    return core_saveChart();
}

int64_t getLength() {
    return core_getLength();
}

bool getJudgement(int64_t globalIndex) {
    return core_getJudgement(globalIndex);
}

void setJudgement(int64_t globalIndex, bool value) {
    core_setJudgement(globalIndex, value);
}

bool getHitFlag(int64_t globalIndex) {
    return core_getHitFlag(globalIndex);
}

void setHitFlag(int64_t globalIndex, bool value) {
    core_setHitFlag(globalIndex, value);
}

void setEditorMode(bool value) {
    core_setEditorMode(value);
}

// === Judgement state (per-shard, in-RAM, flat) — see chart_file.h ===

void clearJudgements(void) {
    core_clearJudgements();
}

// === getNotesFromRange (persistent result block + custom length) ===

int32_t getNotesFromRange(int32_t strumlineCount, int32_t lane, int32_t index,
    int64_t fromIndex, int64_t toIndex) {
    return core_getNotesFromRange(strumlineCount, lane, index, fromIndex, toIndex);
}

int64_t getRangeNoteAt(int32_t at) {
    return core_getRangeNoteAt(at);
}

// === Bulk edit API (v3.5) — stage notes/ranges, then commit once ===
// See chart_file.h for the contract (the exact-index guarantee of addNotes).

void stageNote(int64_t position, int duration, int index, int type, int lane) {
    core_stageNote(position, duration, index, type, lane);
}

int32_t addNotes(void) {
    return core_addNotes();
}

void stageRemovalRange(int64_t lo, int64_t hi) {
    core_stageRemovalRange(lo, hi);
}

int32_t removeNotesFromRangeArray(void) {
    return core_removeNotesFromRangeArray();
}

// === Mirror API (v3.7) — in-place column flip, undo = same call again ===

void stageMirrorRange(int64_t lo, int64_t hi) {
    core_stageMirrorRange(lo, hi);
}

int32_t mirrorNotesFromSelectionRanges(int32_t indexLo, int32_t indexHi) {
    return core_mirrorNotesFromSelectionRanges(indexLo, indexHi);
}

// === Shift API (v3.8) — in-place column/lane move (Alt+arrows) ===

void stageShiftRange(int64_t lo, int64_t hi) {
    core_stageShiftRange(lo, hi);
}

int32_t shiftNotesFromSelectionRanges(int32_t dIndex, int32_t dLane,
    int32_t mania, int32_t strumlineCount) {
    return core_shiftNotesFromSelectionRanges(dIndex, dLane, mania, strumlineCount);
}

void clearStaged(void) {
    core_clearStaged();
}

int32_t getAddedRangeCount(void) {
    return core_getAddedRangeCount();
}

int64_t getAddedRangeLo(int32_t at) {
    return core_getAddedRangeLo(at);
}

int64_t getAddedRangeHi(int32_t at) {
    return core_getAddedRangeHi(at);
}

// === GTFR (v3.9.0) — see chart_file.h for the protocol contract ===

void gtfrStart(int64_t startIndex, int64_t endIndex) {
    core_gtfrStart(startIndex, endIndex);
}

bool gtfrProgress(int64_t start, int64_t end) {
    return core_gtfrProgress(start, end);
}

int64_t gtfrNoteThenAdvance() {
    return core_gtfrNoteThenAdvance();
}

int64_t gtfrIndexThenAdvance() {
    return core_gtfrIndexThenAdvance();
}

void gtfrVirtualNoteRecycle() {
    core_gtfrVirtualNoteRecycle();
}

void gtfrBindNote(int64_t gidx, int32_t diff, int32_t sx, int32_t sy,
    float initialAlpha, float addedAlpha, float scale,
    int32_t notesInOne, bool sustainExists, bool judged,
    bool hitFlag, int32_t lane) {
    core_gtfrBindNote(gidx, diff, sx, sy, initialAlpha, addedAlpha, scale,
        notesInOne, sustainExists, judged, hitFlag, lane);
}

void gtfrBindSustain(int64_t gidx, int32_t diff, int32_t sx, int32_t sy,
    int32_t w, int32_t length, float alpha, float speed,
    float scale, float r) {
    core_gtfrBindSustain(gidx, diff, sx, sy, w, length, alpha, speed, scale, r);
}

int64_t gtfrNoteSlots() {
    return core_gtfrNoteSlots();
}

int64_t gtfrSustainSlots() {
    return core_gtfrSustainSlots();
}

const int64_t* gtfrNoteData() {
    return core_gtfrNoteData();
}

const int64_t* gtfrSustainData() {
    return core_gtfrSustainData();
}

uint32_t gtfrNoteLast4() {
    return core_gtfrNoteLast4();
}

void gtfrFrameBegin() {
    core_gtfrFrameBegin();
}

int32_t gtfrColumnHead(int32_t lane, int32_t index) {
    return core_gtfrColumnHead(lane, index);
}

int32_t gtfrSlotNext(int32_t slot) {
    return core_gtfrSlotNext(slot);
}
