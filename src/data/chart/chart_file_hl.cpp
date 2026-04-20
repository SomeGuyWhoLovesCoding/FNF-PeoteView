#define HL_NAME(n) chart_file_##n

#include <hl.h>

// Include the core implementation
#include "chart_file_core.cpp"

// ============================================================================
// HL API (Haxe interface)
// ============================================================================

HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);
    if (!core_loadChart(path))
        throw std::runtime_error("Failed to open chart file");
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) { 
    return core_getNote(atIndex); 
}

HL_PRIM void HL_NAME(setNote)(int64_t atIndex, int64_t value) { 
    core_setNote(atIndex, value); 
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { 
    return core_getLength(); 
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) { 
    core_destroyChart(); 
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)