#include <iostream>
#include <cstdint>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <map>
#include <string>
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
#include <sys/types.h>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#endif

// ============================================================================
// Portable filesystem helpers (no std::filesystem / C++17 required)
// ============================================================================

// Returns file size in bytes, or -1 on failure
static int64_t getFileSize(const std::string& path) {
#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA info;
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &info))
        return -1;
    return ((int64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
#else
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return -1;
    return (int64_t)st.st_size;
#endif
}

// Strips directory and extension, returning just the stem (e.g. "42" from "42.bin")
static std::string getStem(const std::string& filename) {
    size_t dot = filename.rfind('.');
    return (dot == std::string::npos) ? filename : filename.substr(0, dot);
}

static std::string getExtension(const std::string& filename) {
    size_t dot = filename.rfind('.');
    return (dot == std::string::npos) ? "" : filename.substr(dot);
}

// Fills `out` with filenames (not full paths) of regular files in `dir`
static void listFiles(const std::string& dir, std::vector<std::string>& out) {
#ifdef _WIN32
    WIN32_FIND_DATAA ffd;
    std::string pattern = dir + "\\*";
    HANDLE hFind = FindFirstFileA(pattern.c_str(), &ffd);
    if (hFind == INVALID_HANDLE_VALUE) return;
    do {
        if (!(ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY))
            out.push_back(ffd.cFileName);
    } while (FindNextFileA(hFind, &ffd));
    FindClose(hFind);
#else
    DIR* d = opendir(dir.c_str());
    if (!d) return;
    struct dirent* entry;
    while ((entry = readdir(d)) != nullptr) {
        if (entry->d_type == DT_REG)
            out.push_back(entry->d_name);
    }
    closedir(d);
#endif
}

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
        // Judgement buffer — sized to noteCount, zero-initialized at shard load
        std::vector<uint8_t> judgement;
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
        std::vector<std::string> files;
        listFiles(chartDir, files);

        for (const auto& name : files) {
            if (getExtension(name) != ".bin") continue;
            std::string stem = getStem(name);
            try {
                uint64_t shardId = std::stoull(stem);
                availableShards.push_back(shardId);
            } catch (...) {
                std::cerr << "Warning: Invalid shard filename: " << name << std::endl;
            }
        }
        
        std::sort(availableShards.begin(), availableShards.end());
        
        int64_t cumulative = 0;
        for (uint64_t shardId : availableShards) {
            shardStartIndices.push_back(cumulative);
            
            std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
            int64_t fileSize = getFileSize(path);
            if (fileSize < 0) throw std::runtime_error("Cannot stat shard: " + path);
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
        if (activeShards.find(shardId) != activeShards.end()) return;

        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";

        ShardInfo& info = activeShards[shardId];  // construct in-place
        info.shardId    = shardId;
        info.startIndex = getShardStartIndex(shardId);

        if (!info.reader.open(path.c_str())) {
            activeShards.erase(shardId);
            throw std::runtime_error("Failed to open shard: " + std::to_string(shardId));
        }

        info.noteCount = info.reader.size();
        info.endIndex  = info.startIndex + info.noteCount;

        int64_t byteCount = (info.noteCount + 7) >> 3;
        info.judgement.assign(byteCount, 0);

        /*std::cout << "[JDG] Allocated " << byteCount << " bytes for shard " << shardId 
                << " (" << info.noteCount << " notes)" << std::endl;*/
    }
    
    void unloadShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it != activeShards.end()) {
            it->second.reader.flush();
            activeShards.erase(it);
            if (shardId == cachedShardId) {  // invalidate cache
                cachedShardInfo  = nullptr;
                cachedShardStart = -1;
                cachedShardEnd   = -1;
            }
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
    
    // Hot path cache — avoids binary search on sequential/repeated access
    int64_t cachedShardStart = -1;
    int64_t cachedShardEnd   = -1;   // exclusive
    uint64_t cachedShardId   = 0;
    ShardInfo* cachedShardInfo = nullptr;  // add this

    uint64_t findShardForGlobalIndex(int64_t globalIndex) const {
        // Range check first — O(1), covers sequential and repeated access
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd) {
            return cachedShardId;
        }

        if (globalIndex < 0 || globalIndex >= totalNotes) {
            throw std::out_of_range("Global index out of range");
        }

        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        return availableShards[shardPos];
    }
    
    ShardInfo* getShardInfo(int64_t globalIndex) {
        // O(1) hot path
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && cachedShardInfo) {
            return cachedShardInfo;
        }

        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");

        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        uint64_t shardId = availableShards[shardPos];

        if (shardId != currentShardId) {
            currentShardId = shardId;
            managePool(currentShardId);
        }

        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) {
            loadShard(shardId);
            mapIt = activeShards.find(shardId);
        }

        cachedShardId    = shardId;
        cachedShardStart = shardStartIndices[shardPos];
        cachedShardEnd   = (shardPos + 1 < shardStartIndices.size())
                        ? shardStartIndices[shardPos + 1]
                        : totalNotes;
        cachedShardInfo  = &mapIt->second;

        return cachedShardInfo;
    }

    // ============================================================================
    // Judgement Slot System
    // ============================================================================
    static constexpr int MAX_JUDGEMENT_SLOTS = 16;

    struct JudgementSlot {
        uint8_t* data = nullptr;
        int64_t byteCount = 0;
        bool active = false;
    };

    JudgementSlot judgementSlots[MAX_JUDGEMENT_SLOTS];
    int activeJudgementSlot = 0;

    /*void core_allocJudgementSlot(int slot, int64_t noteCount) {
        if (slot < 0 || slot >= MAX_JUDGEMENT_SLOTS) return;
        auto& s = judgementSlots[slot];
        delete[] s.data;
        int64_t byteCount = (noteCount + 7) >> 3;
        s.data = new uint8_t[byteCount]();
        s.byteCount = byteCount;
        s.active = true;
    }

    void core_clearJudgementSlot(int slot) {
        if (slot < 0 || slot >= MAX_JUDGEMENT_SLOTS) return;
        auto& s = judgementSlots[slot];
        delete[] s.data;
        s.data = new uint8_t[1]();
        s.byteCount = 1;
        s.active = false;
    }

    void core_setActiveJudgementSlot(int slot) {
        if (slot < 0 || slot >= MAX_JUDGEMENT_SLOTS) return;
        activeJudgementSlot = slot;
    }

    int core_getActiveJudgementSlot() {
        return activeJudgementSlot;
    }*/

    bool core_getJudgement(int64_t globalIndex) {
        ShardInfo* info = getShardInfo(globalIndex);
        if (!info) return false;
        int64_t localIndex = globalIndex - info->startIndex;
        int64_t byteIndex  = localIndex >> 3;
        int     bitIndex   = localIndex & 7;
        if (byteIndex >= (int64_t)info->judgement.size()) return false;
        return (info->judgement[byteIndex] >> bitIndex) & 1;
    }

    void core_setJudgement(int64_t globalIndex, bool value) {
        ShardInfo* info = getShardInfo(globalIndex);
        if (!info) {
            std::cout << "[JDG] getShardInfo returned null for " << globalIndex << std::endl;
            return;
        }
        int64_t localIndex = globalIndex - info->startIndex;
        int64_t byteIndex  = localIndex >> 3;
        int     bitIndex   = localIndex & 7;
        //std::cout << "[JDG] set " << globalIndex << " local=" << localIndex << " byte=" << byteIndex << " bit=" << bitIndex << " bufsize=" << info->judgement.size() << std::endl;
        if (byteIndex >= (int64_t)info->judgement.size()) { std::cout << "[JDG] OUT OF BOUNDS" << std::endl; return; }
        if (value)
            info->judgement[byteIndex] |= (1 << bitIndex);
        else
            info->judgement[byteIndex] &= ~(1 << bitIndex);
    }

    /*void core_destroyAllJudgements() {
        for (int i = 0; i < MAX_JUDGEMENT_SLOTS; i++) {
            delete[] judgementSlots[i].data;
            judgementSlots[i].data = nullptr;
            judgementSlots[i].byteCount = 0;
            judgementSlots[i].active = false;
        }
        activeJudgementSlot = 0;
    }*/
    
    uint64_t getNote(int64_t globalIndex) {
        ShardInfo* info = getShardInfo(globalIndex);
        correctionTime = info->shardId * 1000000000;
        return info->reader.get(globalIndex - info->startIndex);
    }

    void setNote(int64_t globalIndex, uint64_t value) {
        ShardInfo* info = getShardInfo(globalIndex);
        info->reader.set(globalIndex - info->startIndex, value);
    }
    
    void printNoteInfo(int64_t globalIndex) {
        uint64_t note = getNote(globalIndex);

        uint32_t positionTicks = (note >> 0)  & 0x7FFFFFFF;  // 31 bits
        uint32_t durationHalfMs = (note >> 31) & 0x1FFFF;    // 17 bits, unit = 0.5ms
        uint8_t  index          = (note >> 48) & 0xFF;
        uint8_t  type           = (note >> 56) & 0x7F;
        bool     missed         = (note >> 63) & 1;
        bool     judged         = core_getJudgement(globalIndex);

        double timeMs     = positionTicks / 4000000.0;
        double durationMs = durationHalfMs * 0.5;

        std::cout << "  Note " << globalIndex << ": "
                << "time="     << formatTime(timeMs, true)
                << " pos="     << positionTicks  << "ticks"
                << " dur="     << durationMs     << "ms"
                << " idx="     << (int)index
                << " type="    << (int)type
                << " judged="  << (judged  ? "Y" : "N")
                << " missed="  << (missed  ? "Y" : "N")
                << " raw=0x"   << std::hex << note << std::dec << std::endl;
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