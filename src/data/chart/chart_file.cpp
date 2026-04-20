#include <stdexcept>

// Include the core implementation
#include "chart_file_core.cpp"

// ============================================================================
// Global API (C++ interface)
// ============================================================================

void loadChart(const char* path) {
    if (!core_loadChart(path))
        throw std::runtime_error("Failed to open chart file");
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