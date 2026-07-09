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

HL_PRIM int64_t HL_NAME(getNote_last2)(int64_t atIndex) { 
    return core_getNote_last2(atIndex);
}

HL_PRIM void HL_NAME(insertNote)(int64_t globalPosition, int duration, int index, int type) {
    core_insertNote(globalPosition, duration, index, type);
}

HL_PRIM void HL_NAME(removeNote)(int64_t globalIndex) {
    core_removeNote(globalIndex);
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

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote_first8, _I64)
DEFINE_PRIM(_I32,  getNote_last2, _I64)
DEFINE_PRIM(_VOID,  insertNote, _I64 _I32 _I32 _I32)
DEFINE_PRIM(_VOID, removeNote, _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_BOOL, getJudgement, _I64)
DEFINE_PRIM(_VOID, setJudgement, _I64 _BOOL)
DEFINE_PRIM(_BOOL, getHitFlag, _I64)
DEFINE_PRIM(_VOID, setHitFlag, _I64 _BOOL)
DEFINE_PRIM(_VOID, setEditorMode, _BOOL)