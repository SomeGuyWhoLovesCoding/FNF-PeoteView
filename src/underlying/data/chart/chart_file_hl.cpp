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

// === Two-dimensional judgement system (N lane rows x M note-index bits) ===

HL_PRIM bool HL_NAME(getJudgement2D)(int lane, int64_t index) {
    return core_getJudgement2D(lane, index);
}

HL_PRIM void HL_NAME(setJudgement2D)(int lane, int64_t index, bool value) {
    core_setJudgement2D(lane, index, value);
}

HL_PRIM void HL_NAME(registerJudgementRange)(int lane, int64_t fromIndex, int64_t toIndex, bool value) {
    core_registerJudgementRange(lane, fromIndex, toIndex, value);
}

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
DEFINE_PRIM(_BOOL, getJudgement2D, _I32 _I64)
DEFINE_PRIM(_VOID, setJudgement2D, _I32 _I64 _BOOL)
DEFINE_PRIM(_VOID, registerJudgementRange, _I32 _I64 _I64 _BOOL)
DEFINE_PRIM(_VOID, clearJudgements, _NO_ARG)
DEFINE_PRIM(_I32,  getNotesFromRange, _I32 _I32 _I32 _I64 _I64)
DEFINE_PRIM(_I64,  getRangeNoteAt, _I32)
