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

// === Mirror API (v3.7) — see chart_file.h ===

HL_PRIM void HL_NAME(stageMirrorRange)(int64_t lo, int64_t hi) {
    core_stageMirrorRange(lo, hi);
}

HL_PRIM int HL_NAME(mirrorNotesFromSelectionRanges)(int indexLo, int indexHi) {
    return core_mirrorNotesFromSelectionRanges(indexLo, indexHi);
}

// === Shift API (v3.8) — see chart_file.h ===

HL_PRIM void HL_NAME(stageShiftRange)(int64_t lo, int64_t hi) {
    core_stageShiftRange(lo, hi);
}

HL_PRIM int HL_NAME(shiftNotesFromSelectionRanges)(int dIndex, int dLane,
    int mania, int strumlineCount) {
    return core_shiftNotesFromSelectionRanges(dIndex, dLane, mania, strumlineCount);
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
DEFINE_PRIM(_VOID, stageMirrorRange, _I64 _I64)
DEFINE_PRIM(_I32,  mirrorNotesFromSelectionRanges, _I32 _I32)
DEFINE_PRIM(_VOID, stageShiftRange, _I64 _I64)
DEFINE_PRIM(_I32,  shiftNotesFromSelectionRanges, _I32 _I32 _I32 _I32)

// === GTFR (v3.9.0) — see chart_file.h for the protocol contract ===

HL_PRIM void HL_NAME(gtfrStart)(int64_t startIndex, int64_t endIndex) {
    core_gtfrStart(startIndex, endIndex);
}
DEFINE_PRIM(_VOID, gtfrStart, _I64 _I64)

HL_PRIM bool HL_NAME(gtfrProgress)(int64_t start, int64_t end) {
    return core_gtfrProgress(start, end);
}
DEFINE_PRIM(_BOOL, gtfrProgress, _I64 _I64)

HL_PRIM int64_t HL_NAME(gtfrNoteThenAdvance)(_NO_ARG) {
    return core_gtfrNoteThenAdvance();
}
DEFINE_PRIM(_I64, gtfrNoteThenAdvance, _NO_ARG)

HL_PRIM int64_t HL_NAME(gtfrIndexThenAdvance)(_NO_ARG) {
    return core_gtfrIndexThenAdvance();
}
DEFINE_PRIM(_I64, gtfrIndexThenAdvance, _NO_ARG)

HL_PRIM void HL_NAME(gtfrVirtualNoteRecycle)(_NO_ARG) {
    core_gtfrVirtualNoteRecycle();
}
DEFINE_PRIM(_VOID, gtfrVirtualNoteRecycle, _NO_ARG)

HL_PRIM void HL_NAME(gtfrBindNote)(int64_t gidx, int32_t diff, int32_t sx, int32_t sy,
    double initialAlpha, double addedAlpha, double scale,
    int32_t notesInOne, bool sustainExists, bool judged,
    bool hitFlag, int32_t lane) {
    core_gtfrBindNote(gidx, diff, sx, sy, (float)initialAlpha, (float)addedAlpha,
        (float)scale, notesInOne, sustainExists, judged, hitFlag, lane);
}
DEFINE_PRIM(_VOID, gtfrBindNote, _I64 _I32 _I32 _I32 _I32 _F64 _F64 _F64 _I32 _BOOL _BOOL _BOOL _BOOL _I32)

HL_PRIM void HL_NAME(gtfrBindSustain)(int64_t gidx, int32_t diff, int32_t sx, int32_t sy,
    int32_t w, int32_t length, double alpha, double speed,
    double scale, double r) {
    core_gtfrBindSustain(gidx, diff, sx, sy, w, length, (float)alpha, (float)speed,
        (float)scale, (float)r);
}
DEFINE_PRIM(_VOID, gtfrBindSustain, _I64 _I32 _I32 _I32 _I32 _I32 _F64 _F64 _F64 _F64)

HL_PRIM int64_t HL_NAME(gtfrNoteSlots)(_NO_ARG) {
    return core_gtfrNoteSlots();
}
DEFINE_PRIM(_I64, gtfrNoteSlots, _NO_ARG)

HL_PRIM int64_t HL_NAME(gtfrSustainSlots)(_NO_ARG) {
    return core_gtfrSustainSlots();
}
DEFINE_PRIM(_I64, gtfrSustainSlots, _NO_ARG)

HL_PRIM int HL_NAME(gtfrNoteLast4)(_NO_ARG) {
    return (int)core_gtfrNoteLast4();
}
DEFINE_PRIM(_I32, gtfrNoteLast4, _NO_ARG)

HL_PRIM void HL_NAME(gtfrFrameBegin)(_NO_ARG) {
    core_gtfrFrameBegin();
}
DEFINE_PRIM(_VOID, gtfrFrameBegin, _NO_ARG)

HL_PRIM int HL_NAME(gtfrColumnHead)(int lane, int index) {
    return core_gtfrColumnHead(lane, index);
}
DEFINE_PRIM(_I32, gtfrColumnHead, _I32 _I32)

HL_PRIM int HL_NAME(gtfrSlotNext)(int slot) {
    return core_gtfrSlotNext(slot);
}
DEFINE_PRIM(_I32, gtfrSlotNext, _I32)
