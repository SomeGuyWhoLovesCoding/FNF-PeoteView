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
    core_setNote(index, value);
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

int64_t getTimeCorrectionForIndex(int64_t index) {
    if (!gReader) return 0;
    uint64_t shardId = gReader->findShardForGlobalIndex(index);
    return shardId * 2000000000LL;
}

/*void allocJudgementSlot(int slot, int64_t noteCount) {
    if (!gReader) return;
    gReader->core_allocJudgementSlot(slot, noteCount);
}

void clearJudgementSlot(int slot) {
    if (!gReader) return;
    gReader->core_clearJudgementSlot(slot);
}

void setActiveJudgementSlot(int slot) {
    if (!gReader) return;
    gReader->core_setActiveJudgementSlot(slot);
}

int getActiveJudgementSlot() {
    if (!gReader) return 0;
    return gReader->core_getActiveJudgementSlot();
}..*/

bool getJudgement(int64_t globalIndex) {
    if (!gReader) return false;
    return gReader->core_getJudgement(globalIndex);
}

void setJudgement(int64_t globalIndex, bool value) {
    if (!gReader) return;
    gReader->core_setJudgement(globalIndex, value);
}

/*void destroyAllJudgements() {
    if (!gReader) return;
    gReader->core_destroyAllJudgements();
}*/