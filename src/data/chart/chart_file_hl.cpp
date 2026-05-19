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

HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) { 
    return core_getNote(atIndex); 
}

HL_PRIM void HL_NAME(setNote)(int64_t atIndex, int64_t value) { 
    //core_setNote(atIndex, value); 
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { 
    return core_getLength(); 
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) { 
    core_destroyChart(); 
}

HL_PRIM int64_t HL_NAME(getTimeCorrectionForIndex)(int64_t index) {
    if (!gReader) return 0;
    uint64_t shardId = gReader->findShardForTimeCorrection(index);
    return shardId * 4000000000LL;
}

// new shit
HL_PRIM bool HL_NAME(isNoteHit)(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return core_isNoteHit(index);
}

HL_PRIM void HL_NAME(setNoteHit)(int64_t index, bool value) {
    core_setNoteHit(index, value);
}

HL_PRIM bool HL_NAME(isNoteMissed)(int64_t index) {
    return core_isNoteMissed(index);
}

HL_PRIM void HL_NAME(setNoteMissed)(int64_t index, bool value) {
    core_setNoteMissed(index, value);
}

HL_PRIM bool HL_NAME(isNoteHeld)(int64_t index) {
    return core_isNoteHeld(index);
}

HL_PRIM void HL_NAME(setNoteHeld)(int64_t index, bool value) {
    core_setNoteHeld(index, value);
}

/// now that's how judgements should work
HL_PRIM void HL_NAME(clearJudgement)(_NO_ARG) {
    core_clearJudgement();
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_I64, getTimeCorrectionForIndex, _I64)
DEFINE_PRIM(_BOOL,  isNoteHit, _I64)
DEFINE_PRIM(_VOID,  setNoteHit, _I64 _BOOL)
DEFINE_PRIM(_BOOL,  isNoteMissed, _I64)
DEFINE_PRIM(_VOID,  setNoteMissed, _I64 _BOOL)
DEFINE_PRIM(_BOOL,  isNoteHeld, _I64)
DEFINE_PRIM(_VOID,  setNoteHeld, _I64 _BOOL)
DEFINE_PRIM(_VOID,  clearJudgement, _NO_ARG)