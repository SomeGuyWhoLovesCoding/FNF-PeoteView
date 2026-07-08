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

int64_t getNote_last2(int64_t index) {
    return core_getNote_last2(index);
}

void insertNote(int64_t globalPosition, int duration, int index, int type) {
    core_insertNote(globalPosition, duration, index, type);
}

void removeNote(int64_t globalIndex) {
    core_removeNote(globalIndex);
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