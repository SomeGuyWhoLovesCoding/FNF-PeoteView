#include <iostream>
#include <cstdint>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <map>
#include <string>
#include <filesystem>
#include <vector>
#include <fstream>
#include <iomanip>
#include <cmath>

// Fix Windows min/max macros
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#undef NOMINMAX
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

namespace fs = std::filesystem;

// ============================================================================
// Time formatting function (matching Haxe behavior)
// ============================================================================
std::string formatTime(double ms, bool showMS = false) {
    if (std::isnan(ms)) {
        return "null";
    }
    
    int milliseconds = static_cast<int>(ms * 0.1) % 100;
    int seconds = static_cast<int>(ms * 0.001);
    int hours = seconds / 3600;
    seconds %= 3600;
    int minutes = seconds / 60;
    seconds %= 60;
    
    std::string time;
    
    if (hours > 0) {
        time += std::to_string(hours) + ":";
    }
    
    if (minutes < 10 && hours > 0) {
        time += "0" + std::to_string(minutes) + ":";
    } else {
        time += std::to_string(minutes) + ":";
    }
    
    if (seconds < 10) {
        time += "0";
    }
    time += std::to_string(seconds);
    
    if (showMS) {
        time += ".";
        if (milliseconds < 10) {
            time += "0";
        }
        time += std::to_string(milliseconds);
    }
    
    return time;
}

// ============================================================================
// Note unpacking helpers - POSITION IS ABSOLUTE IN TICKS
// ============================================================================
uint32_t getPosition(uint64_t note) { return (note >> 0) & 0x3FFFFFFF; }   // Absolute position in ticks
uint16_t getDuration(uint64_t note) { return (note >> 30) & 0xFFFF; }      // Duration in ms
uint8_t getIndex(uint64_t note)     { return (note >> 46) & 0xFF; }
uint8_t getType(uint64_t note)      { return (note >> 54) & 0x7F; }
bool getFlag(uint64_t note)         { return (note >> 61) & 1; }
bool getMissed(uint64_t note)       { return (note >> 62) & 1; }
bool getHeld(uint64_t note)         { return (note >> 63) & 1; }

// Convert ticks to milliseconds (1 tick = 0.25 nanoseconds = 0.00000025 ms)
double ticksToMs(uint32_t ticks) {
    return ticks / 4000000.0;  // 4,000,000 ticks per ms
}

// ============================================================================
// Simple direct file reader with write support
// ============================================================================
class DirectFileReader {
private:
    std::vector<uint64_t> data;
    std::string filename;
    bool modified = false;
    
public:
    bool open(const char* path) {
        filename = path;
        std::ifstream file(path, std::ios::binary);
        if (!file) return false;
        
        file.seekg(0, std::ios::end);
        size_t size = file.tellg();
        file.seekg(0, std::ios::beg);
        
        size_t count = size / sizeof(uint64_t);
        data.resize(count);
        file.read((char*)data.data(), size);
        file.close();
        
        return true;
    }
    
    void flush() {
        if (modified && !filename.empty()) {
            std::ofstream file(filename, std::ios::binary);
            if (file) {
                file.write((char*)data.data(), data.size() * sizeof(uint64_t));
                file.close();
                modified = false;
            }
        }
    }
    
    uint64_t get(int64_t index) const {
        if (index < 0 || index >= (int64_t)data.size()) {
            throw std::out_of_range("Index out of range");
        }
        return data[index];
    }
    
    void set(int64_t index, uint64_t value) {
        if (index < 0 || index >= (int64_t)data.size()) {
            throw std::out_of_range("Index out of range");
        }
        data[index] = value;
        modified = true;
    }
    
    int64_t size() const { return data.size(); }
};

// ============================================================================
// Sharded Chart Reader with Pooling System and Binary Search
// ============================================================================
class ShardedChartReader {
private:
    struct ShardInfo {
        DirectFileReader reader;
        int64_t noteCount;
        uint64_t shardId;
        int64_t startIndex;  // Global start index of this shard
        int64_t endIndex;    // Global end index (exclusive)
    };

    std::string chartDir;
    std::map<uint64_t, ShardInfo> activeShards;
    std::vector<uint64_t> availableShards;
    std::vector<int64_t> shardStartIndices;  // For binary search
    uint64_t currentShardId = 0;
    int64_t totalNotes = 0;
    
    static constexpr int POOL_SIZE = 100;
    static constexpr int PRELOAD_THRESHOLD = 50;

    int64_t correctionTime = 0;
    
    void scanShards() {
        for (const auto& entry : fs::directory_iterator(chartDir)) {
            if (entry.is_regular_file() && entry.path().extension() == ".bin") {
                std::string filename = entry.path().stem().string();
                try {
                    uint64_t shardId = std::stoull(filename);
                    availableShards.push_back(shardId);
                } catch (...) {
                    std::cerr << "Warning: Invalid shard filename: " << filename << std::endl;
                }
            }
        }
        
        std::sort(availableShards.begin(), availableShards.end());
        
        int64_t cumulative = 0;
        for (uint64_t shardId : availableShards) {
            shardStartIndices.push_back(cumulative);
            
            std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
            uint64_t fileSize = fs::file_size(path);
            int64_t noteCount = fileSize / sizeof(uint64_t);
            cumulative += noteCount;
        }
        
        totalNotes = cumulative;
        
        std::cout << "[INFO] Found " << availableShards.size() << " shards, "
                  << totalNotes << " total notes" << std::endl;
    }
    
    int64_t getShardStartIndex(uint64_t shardId) const {
        // Binary search to find shard's start index
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it == availableShards.end() || *it != shardId) {
            throw std::runtime_error("Shard not found");
        }
        size_t pos = std::distance(availableShards.begin(), it);
        return shardStartIndices[pos];
    }
    
    void loadShard(uint64_t shardId) {
        if (activeShards.find(shardId) != activeShards.end()) {
            return;
        }
        
        ShardInfo info;
        info.shardId = shardId;
        info.startIndex = getShardStartIndex(shardId);
        
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        
        if (!info.reader.open(path.c_str())) {
            throw std::runtime_error("Failed to open shard: " + std::to_string(shardId));
        }
        
        info.noteCount = info.reader.size();
        info.endIndex = info.startIndex + info.noteCount;
        activeShards[shardId] = std::move(info);
        
        //std::cout << "[POOL] Loaded shard " << shardId << " (" << info.noteCount << " notes)" << std::endl;
    }
    
    void unloadShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it != activeShards.end()) {
            it->second.reader.flush();
            activeShards.erase(it);
            //std::cout << "[POOL] Unloaded shard " << shardId << std::endl;
        }
    }
    
    void managePool(uint64_t currentShard) {
        // Remove shards that are far behind
        std::vector<uint64_t> toRemove;
        for (auto& pair : activeShards) {
            uint64_t shardId = pair.first;
            if (shardId + POOL_SIZE < currentShard) {
                toRemove.push_back(shardId);
            }
        }
        
        for (uint64_t shardId : toRemove) {
            unloadShard(shardId);
        }
        
        // Preload next shards if we're near the end of loaded range
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), currentShard);
        if (it != availableShards.end()) {
            size_t currentPos = std::distance(availableShards.begin(), it);
            size_t remainingShards = availableShards.size() - currentPos;
            
            if (remainingShards <= PRELOAD_THRESHOLD) {
                size_t toLoad = (std::min)((size_t)POOL_SIZE, remainingShards);
                for (size_t i = 0; i < toLoad; i++) {
                    uint64_t nextShard = availableShards[currentPos + i];
                    if (activeShards.find(nextShard) == activeShards.end()) {
                        loadShard(nextShard);
                    }
                }
            }
        }
    }
    
public:
    ShardedChartReader(const char* path) : chartDir(path) {
        scanShards();
        if (availableShards.empty()) {
            throw std::runtime_error("No shards found in directory");
        }
        
        // Initial load: load first POOL_SIZE shards
        size_t initialLoad = (std::min)((size_t)POOL_SIZE, availableShards.size());
        for (size_t i = 0; i < initialLoad; i++) {
            loadShard(availableShards[i]);
        }
    }
    
    ~ShardedChartReader() {
        for (auto& pair : activeShards) {
            pair.second.reader.flush();
        }
        activeShards.clear();
    }
    
    // Binary search to find which shard contains the global index
    uint64_t findShardForGlobalIndex(int64_t globalIndex) const {
        if (globalIndex < 0 || globalIndex >= totalNotes) {
            throw std::out_of_range("Global index out of range");
        }
        
        // Binary search on shardStartIndices
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        if (it == shardStartIndices.begin()) {
            throw std::runtime_error("Invalid shard lookup");
        }
        
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        return availableShards[shardPos];
    }
    
    uint64_t getNote(int64_t globalIndex) {
        uint64_t shardId = findShardForGlobalIndex(globalIndex);
        correctionTime = shardId * 1000000000;
        
        // Cache the current shard for sequential access
        if (shardId != currentShardId) {
            currentShardId = shardId;
            managePool(currentShardId);
        }
        
        // Ensure shard is loaded
        if (activeShards.find(shardId) == activeShards.end()) {
            loadShard(shardId);
        }
        
        ShardInfo& info = activeShards[shardId];
        int64_t localIndex = globalIndex - info.startIndex;
        
        return info.reader.get(localIndex);
    }
    
    void setNote(int64_t globalIndex, uint64_t value) {
        uint64_t shardId = findShardForGlobalIndex(globalIndex);
        
        if (shardId != currentShardId) {
            currentShardId = shardId;
            managePool(currentShardId);
        }
        
        if (activeShards.find(shardId) == activeShards.end()) {
            loadShard(shardId);
        }
        
        ShardInfo& info = activeShards[shardId];
        int64_t localIndex = globalIndex - info.startIndex;
        
        info.reader.set(localIndex, value);
    }
    
    void printNoteInfo(int64_t globalIndex) {
        uint64_t note = getNote(globalIndex);
        
        uint32_t positionTicks = getPosition(note);
        uint16_t durationMs = getDuration(note);
        uint8_t index = getIndex(note);
        uint8_t type = getType(note);
        bool flag = getFlag(note);
        bool missed = getMissed(note);
        bool held = getHeld(note);
        
        // Convert absolute position ticks to milliseconds
        double timeMs = ticksToMs(positionTicks);
        
        std::cout << "  Note " << globalIndex << ": "
                  << "time=" << formatTime(timeMs, true)
                  << " pos=" << positionTicks << "ticks"
                  << " dur=" << durationMs << "ms"
                  << " idx=" << (int)index
                  << " type=" << (int)type
                  << " flags=[" << (flag ? "F" : "") << (missed ? "M" : "") << (held ? "H" : "") << "]"
                  << " raw=0x" << std::hex << note << std::dec << std::endl;
    }
    
    int64_t getLength() const {
        return totalNotes;
    }
    
    size_t getShardCount() const {
        return availableShards.size();
    }
    
    void printPoolStats() const {
        std::cout << "[POOL] Active shards: " << activeShards.size() << " / " << availableShards.size() << std::endl;
        int count = 0;
        for (const auto& pair : activeShards) {
            if (count++ >= 10) {
                std::cout << "  ... and " << (activeShards.size() - 10) << " more" << std::endl;
                break;
            }
            std::cout << "  Shard " << pair.first << ": " << pair.second.noteCount << " notes" << std::endl;
        }
    }
    
    void flushAll() {
        for (auto& pair : activeShards) {
            pair.second.reader.flush();
        }
    }
};

// ============================================================================
// Global API
// ============================================================================
static ShardedChartReader* gReader = nullptr;

void core_loadChart(const char* path) {
    if (gReader) {
        delete gReader;
        gReader = nullptr;
    }
    gReader = new ShardedChartReader(path);
}

void core_destroyChart() {
    if (gReader) {
        delete gReader;
        gReader = nullptr;
    }
}

uint64_t core_getNote(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->getNote(index);
}

void core_setNote(int64_t index, uint64_t value) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->setNote(index, value);
}

void core_printNoteInfo(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->printNoteInfo(index);
}

int64_t core_getLength() {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->getLength();
}

size_t core_getShardCount() {
    if (!gReader) return 0;
    return gReader->getShardCount();
}

void core_printPoolStats() {
    if (gReader) gReader->printPoolStats();
}

void core_flushChart() {
    if (gReader) gReader->flushAll();
}