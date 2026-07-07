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
    core_setNote(atIndex, value); 
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

HL_PRIM int64_t HL_NAME(getTimeCorrectionForIndex)(int64_t index) {
    if (!gReader) return 0;
    uint64_t shardId = gReader->findShardForGlobalIndex(index);
    return shardId * 2000000000LL;
}

/*HL_PRIM void HL_NAME(allocJudgementSlot)(int slot, int64_t noteCount) {
    if (!gReader) return;
    gReader->core_allocJudgementSlot(slot, noteCount);
}

HL_PRIM void HL_NAME(clearJudgementSlot)(int slot) {
    if (!gReader) return;
    gReader->core_clearJudgementSlot(slot);
}

HL_PRIM void HL_NAME(setActiveJudgementSlot)(int slot) {
    if (!gReader) return;
    gReader->core_setActiveJudgementSlot(slot);
}

HL_PRIM int HL_NAME(getActiveJudgementSlot)(_NO_ARG) {
    if (!gReader) return 0;
    return gReader->core_getActiveJudgementSlot();
}..*/

HL_PRIM bool HL_NAME(getJudgement)(int64_t globalIndex) {
    if (!gReader) return false;
    return gReader->core_getJudgement(globalIndex);
}

HL_PRIM void HL_NAME(setJudgement)(int64_t globalIndex, bool value) {
    if (!gReader) return;
    gReader->core_setJudgement(globalIndex, value);
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_VOID,  insertNote, _I64 _I32 _I32 _I32)
DEFINE_PRIM(_VOID, removeNote, _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_I64, getTimeCorrectionForIndex, _I64)
/*DEFINE_PRIM(_VOID, allocJudgementSlot, _I32 _I64)
DEFINE_PRIM(_VOID, setActiveJudgementSlot, _I32)
DEFINE_PRIM(_VOID, clearJudgementSlot, _I32)
DEFINE_PRIM(_I32, getActiveJudgementSlot, _NO_ARG)*/
DEFINE_PRIM(_BOOL, getJudgement, _I64)
DEFINE_PRIM(_VOID, setJudgement, _I64 _BOOL)
//DEFINE_PRIM(_VOID, destroyAllJudgements, _NO_ARG)