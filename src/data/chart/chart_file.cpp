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

int64_t getLength() {
    return core_getLength();
}

int64_t getTimeCorrectionForIndex(int64_t index) {
    if (!gReader) return 0;
    uint64_t shardId = gReader->findShardForGlobalIndex(index); // thumbsup
    return shardId * 1000000000LL;
}