#define HL_NAME(n) async_kb_##n

#include <hl.h>

// Include the core implementation.
#include "AsyncKBCore.cpp"

// ============================================================================
// HL API (Haxe interface) 
// ============================================================================

HL_PRIM void HL_NAME(start)(_NO_ARG) {
    core_start();
}

HL_PRIM void HL_NAME(stop)(_NO_ARG) {
    core_stop();
}

HL_PRIM bool HL_NAME(hasEvent)(_NO_ARG) {
    return core_hasEvent();
}

HL_PRIM double HL_NAME(getScanCode)(_NO_ARG) {
    return core_getScanCode();
}

HL_PRIM double HL_NAME(getState)(_NO_ARG) {
    return core_getState();
}

HL_PRIM double HL_NAME(getTimestamp)(_NO_ARG) {
    return core_getTimestamp();
}

HL_PRIM double HL_NAME(getGlobalTimestampComparison)(_NO_ARG) {
    return core_getGlobalTimestampComparison();
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, start, _NO_ARG)
DEFINE_PRIM(_VOID, stop, _NO_ARG)
DEFINE_PRIM(_BOOL, hasEvent, _NO_ARG)
DEFINE_PRIM(_F64, getScanCode, _NO_ARG)
DEFINE_PRIM(_F64, getState, _NO_ARG)
DEFINE_PRIM(_F64, getTimestamp, _NO_ARG)
DEFINE_PRIM(_F64, getGlobalTimestampComparison, _NO_ARG)