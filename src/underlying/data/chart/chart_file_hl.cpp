#define HL_NAME(n) chart_file_##n

#include <hl.h>

// Include the core implementation
#include "chart_file_core.cpp"

// ============================================================================
// HL API (Haxe interface)
// ============================================================================

HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);
    core_loadChart(path);
}

HL_PRIM int64_t HL_NAME(getNote_first8)(int64_t atIndex) {
    return core_getNote_first8(atIndex);
}

HL_PRIM int64_t HL_NAME(getNote_last4)(int64_t atIndex) {
    return (int64_t)core_getNote_last4(atIndex);
}

HL_PRIM int64_t HL_NAME(addNote)(int64_t position, int duration, int index, int type, int lane) {
    return core_addNote(position, duration, index, type, lane);
}

HL_PRIM void HL_NAME(insertNote)(int64_t globalPosition, int duration, int index, int type) {
    core_insertNote(globalPosition, duration, index, type);
}

HL_PRIM void HL_NAME(removeNote)(int64_t globalIndex) {
    core_removeNote(globalIndex);
}

HL_PRIM bool HL_NAME(saveChart)(_NO_ARG) {
    return core_saveChart();
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) {
    return core_getLength();
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
    core_destroyChart();
}

HL_PRIM bool HL_NAME(getJudgement)(int64_t globalIndex) {
    return core_getJudgement(globalIndex);
}

HL_PRIM void HL_NAME(setJudgement)(int64_t globalIndex, bool value) {
    core_setJudgement(globalIndex, value);
}

HL_PRIM bool HL_NAME(getHitFlag)(int64_t globalIndex) {
    return core_getHitFlag(globalIndex);
}

HL_PRIM void HL_NAME(setHitFlag)(int64_t globalIndex, bool value) {
    core_setHitFlag(globalIndex, value);
}

HL_PRIM void HL_NAME(setEditorMode)(bool value) {
    core_setEditorMode(value);
}

// === Judgement state (per-shard, in-RAM, flat) — see chart_file.h ===

HL_PRIM void HL_NAME(clearJudgements)(_NO_ARG) {
    core_clearJudgements();
}

// === getNotesFromRange (persistent result block + custom length) ===

HL_PRIM int HL_NAME(getNotesFromRange)(int strumlineCount, int lane, int index,
    int64_t fromIndex, int64_t toIndex) {
    return core_getNotesFromRange(strumlineCount, lane, index, fromIndex, toIndex);
}

HL_PRIM int64_t HL_NAME(getRangeNoteAt)(int at) {
    return core_getRangeNoteAt(at);
}

// === Bulk edit API (v3.5) — stage notes/ranges, then commit once ===

HL_PRIM void HL_NAME(stageNote)(int64_t position, int duration, int index, int type, int lane) {
    core_stageNote(position, duration, index, type, lane);
}

HL_PRIM int HL_NAME(addNotes)(_NO_ARG) {
    return core_addNotes();
}

HL_PRIM void HL_NAME(stageRemovalRange)(int64_t lo, int64_t hi) {
    core_stageRemovalRange(lo, hi);
}

HL_PRIM int HL_NAME(removeNotesFromRangeArray)(_NO_ARG) {
    return core_removeNotesFromRangeArray();
}

HL_PRIM void HL_NAME(clearStaged)(_NO_ARG) {
    core_clearStaged();
}

HL_PRIM int HL_NAME(getAddedRangeCount)(_NO_ARG) {
    return core_getAddedRangeCount();
}

HL_PRIM int64_t HL_NAME(getAddedRangeLo)(int at) {
    return core_getAddedRangeLo(at);
}

HL_PRIM int64_t HL_NAME(getAddedRangeHi)(int at) {
    return core_getAddedRangeHi(at);
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote_first8, _I64)
DEFINE_PRIM(_I64,  getNote_last4, _I64)
DEFINE_PRIM(_I64,  addNote, _I64 _I32 _I32 _I32 _I32)
DEFINE_PRIM(_VOID,  insertNote, _I64 _I32 _I32 _I32)
DEFINE_PRIM(_VOID, removeNote, _I64)
DEFINE_PRIM(_BOOL, saveChart, _NO_ARG)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_BOOL, getJudgement, _I64)
DEFINE_PRIM(_VOID, setJudgement, _I64 _BOOL)
DEFINE_PRIM(_BOOL, getHitFlag, _I64)
DEFINE_PRIM(_VOID, setHitFlag, _I64 _BOOL)
DEFINE_PRIM(_VOID, setEditorMode, _BOOL)
DEFINE_PRIM(_VOID, clearJudgements, _NO_ARG)
DEFINE_PRIM(_I32,  getNotesFromRange, _I32 _I32 _I32 _I64 _I64)
DEFINE_PRIM(_I64,  getRangeNoteAt, _I32)
DEFINE_PRIM(_VOID, stageNote, _I64 _I32 _I32 _I32 _I32)
DEFINE_PRIM(_I32,  addNotes, _NO_ARG)
DEFINE_PRIM(_VOID, stageRemovalRange, _I64 _I64)
DEFINE_PRIM(_I32,  removeNotesFromRangeArray, _NO_ARG)
DEFINE_PRIM(_VOID, clearStaged, _NO_ARG)
DEFINE_PRIM(_I32,  getAddedRangeCount, _NO_ARG)
DEFINE_PRIM(_I64,  getAddedRangeLo, _I32)
DEFINE_PRIM(_I64,  getAddedRangeHi, _I32)
