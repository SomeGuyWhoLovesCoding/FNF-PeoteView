#include <stdexcept>

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

int64_t getNote(int64_t index) {
    return core_getNote(index);
}

void setNote(int64_t index, int64_t value) {
    //core_setNote(index, value);
}

int64_t getLength() {
    return core_getLength();
}

int64_t getTimeCorrectionForIndex(int64_t index) {
    if (!gReader) return 0;
    uint64_t shardId = gReader->findShardForTimeCorrection(index);
    return shardId * 4000000000LL;
}

// new shit
bool isNoteHit(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return core_isNoteHit(index);
}

void setNoteHit(int64_t index, bool value) {
    core_setNoteHit(index, value);
}

bool isNoteMissed(int64_t index) {
    return core_isNoteMissed(index);
}

void setNoteMissed(int64_t index, bool value) {
    core_setNoteMissed(index, value);
}

bool isNoteHeld(int64_t index) {
    return core_isNoteHeld(index);
}

void setNoteHeld(int64_t index, bool value) {
    core_setNoteHeld(index, value);
}

// Clears all judgement state.
// Call this from Haxe's resetNotes() with the lowerBound seek target.
void clearJudgement() {
    core_clearJudgement();
}