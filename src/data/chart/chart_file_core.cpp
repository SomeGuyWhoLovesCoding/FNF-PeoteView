#include <iostream>
#include <cstdint>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <map>
#include <string>
#include <vector>
#include <iomanip>
#include <cmath>

// Fix Windows min/max macros
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#endif

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
inline uint32_t getPosition(uint64_t note) { return (note >> 0) & 0x3FFFFFFF; }
inline uint16_t getDuration(uint64_t note) { return (note >> 30) & 0xFFFF; }
inline uint8_t getIndex(uint64_t note)     { return (note >> 46) & 0xFF; }
inline uint8_t getType(uint64_t note)      { return (note >> 54) & 0x7F; }
inline bool getFlag(uint64_t note)         { return (note >> 61) & 1; }
inline bool getMissed(uint64_t note)       { return (note >> 62) & 1; }
inline bool getHeld(uint64_t note)         { return (note >> 63) & 1; }

// Convert ticks to milliseconds (1 tick = 0.25 nanoseconds = 0.00000025 ms)
inline double ticksToMs(uint32_t ticks) {
    return ticks / 4000000.0;
}

// ============================================================================
// Memory-mapped file reader with write support (Zero-copy)
// ============================================================================
class MMapFileReader {
private:
#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMapping = nullptr;
#else
    int fd = -1;
#endif
    void* mappedData = nullptr;
    size_t fileSize = 0;
    size_t noteCount = 0;
    bool modified = false;
    std::string filename;
    
public:
    ~MMapFileReader() {
        close();
    }
    
    bool open(const char* path) {
        filename = path;
        
#ifdef _WIN32
        hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, 
                            FILE_SHARE_READ, nullptr, OPEN_EXISTING, 
                            FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return false;
        
        LARGE_INTEGER li;
        if (!GetFileSizeEx(hFile, &li)) {
            CloseHandle(hFile);
            return false;
        }
        fileSize = li.QuadPart;
        
        hMapping = CreateFileMappingA(hFile, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        if (!hMapping) {
            CloseHandle(hFile);
            return false;
        }
        
        mappedData = MapViewOfFile(hMapping, FILE_MAP_ALL_ACCESS, 0, 0, fileSize);
        if (!mappedData) {
            CloseHandle(hMapping);
            CloseHandle(hFile);
            return false;
        }
#else
        fd = ::open(path, O_RDWR);
        if (fd == -1) return false;
        
        struct stat st;
        if (fstat(fd, &st) == -1) {
            ::close(fd);
            return false;
        }
        fileSize = st.st_size;
        
        mappedData = mmap(nullptr, fileSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mappedData == MAP_FAILED) {
            ::close(fd);
            return false;
        }
#endif
        
        noteCount = fileSize / sizeof(uint64_t);
        return true;
    }
    
    void close() {
        if (mappedData) {
#ifdef _WIN32
            if (modified) {
                FlushViewOfFile(mappedData, fileSize);
            }
            UnmapViewOfFile(mappedData);
#else
            if (modified) {
                msync(mappedData, fileSize, MS_ASYNC);
            }
            munmap(mappedData, fileSize);
#endif
            mappedData = nullptr;
        }
        
#ifdef _WIN32
        if (hMapping) {
            CloseHandle(hMapping);
            hMapping = nullptr;
        }
        if (hFile != INVALID_HANDLE_VALUE) {
            CloseHandle(hFile);
            hFile = INVALID_HANDLE_VALUE;
        }
#else
        if (fd != -1) {
            ::close(fd);
            fd = -1;
        }
#endif
        
        modified = false;
    }
    
    inline uint64_t get(int64_t index) const {
        return static_cast<const uint64_t*>(mappedData)[index];
    }
    
    inline void set(int64_t index, uint64_t value) {
        static_cast<uint64_t*>(mappedData)[index] = value;
        modified = true;
    }
    
    void flush() {
        if (modified && mappedData) {
#ifdef _WIN32
            FlushViewOfFile(mappedData, fileSize);
#else
            msync(mappedData, fileSize, MS_ASYNC);
#endif
            modified = false;
        }
    }
    
    inline int64_t size() const { return noteCount; }
};

// ============================================================================
// Sharded Chart Reader with Pooling System and Binary Search
// ============================================================================
class ShardedChartReader {
private:
    struct ShardInfo {
        MMapFileReader reader;
        int64_t noteCount = 0;
        uint64_t shardId = 0;
        int64_t startIndex = 0;
        int64_t endIndex = 0;
    };

    std::string chartDir;
    std::map<uint64_t, ShardInfo> activeShards;
    std::vector<uint64_t> availableShards;
    std::vector<int64_t> shardStartIndices;
    
    // Fast path cache for sequential access
    ShardInfo* currentShard = nullptr;
    int64_t totalNotes = 0;
    
    static constexpr int POOL_SIZE = 100;
    
    void scanShards() {
#ifdef _WIN32
        std::string pattern = chartDir + "\\*.bin";
        WIN32_FIND_DATAA findData;
        HANDLE hFind = FindFirstFileA(pattern.c_str(), &findData);
        
        if (hFind != INVALID_HANDLE_VALUE) {
            do {
                std::string filename = findData.cFileName;
                size_t dotPos = filename.find_last_of('.');
                if (dotPos != std::string::npos) {
                    filename = filename.substr(0, dotPos);
                }
                
                try {
                    uint64_t shardId = std::stoull(filename);
                    availableShards.push_back(shardId);
                    
                    LARGE_INTEGER fileSize;
                    fileSize.LowPart = findData.nFileSizeLow;
                    fileSize.HighPart = findData.nFileSizeHigh;
                    
                    int64_t noteCount = fileSize.QuadPart / sizeof(uint64_t);
                    shardStartIndices.push_back(totalNotes);
                    totalNotes += noteCount;
                } catch (...) {
                    // Skip invalid filenames
                }
            } while (FindNextFileA(hFind, &findData));
            
            FindClose(hFind);
        }
#else
        DIR* dir = opendir(chartDir.c_str());
        if (!dir) return;
        
        struct dirent* entry;
        while ((entry = readdir(dir)) != nullptr) {
            std::string filename = entry->d_name;
            if (filename.length() < 5 || filename.substr(filename.length() - 4) != ".bin") {
                continue;
            }
            
            filename = filename.substr(0, filename.length() - 4);
            
            try {
                uint64_t shardId = std::stoull(filename);
                availableShards.push_back(shardId);
                
                std::string fullPath = chartDir + "/" + entry->d_name;
                struct stat st;
                if (stat(fullPath.c_str(), &st) == 0) {
                    int64_t noteCount = st.st_size / sizeof(uint64_t);
                    shardStartIndices.push_back(totalNotes);
                    totalNotes += noteCount;
                }
            } catch (...) {
                // Skip invalid filenames
            }
        }
        
        closedir(dir);
#endif
        
        // Sort shards by ID
        std::vector<std::pair<uint64_t, int64_t>> paired;
        for (size_t i = 0; i < availableShards.size(); ++i) {
            paired.emplace_back(availableShards[i], shardStartIndices[i]);
        }
        
        std::sort(paired.begin(), paired.end());
        
        availableShards.clear();
        shardStartIndices.clear();
        
        int64_t runningTotal = 0;
        for (const auto& p : paired) {
            availableShards.push_back(p.first);
            shardStartIndices.push_back(runningTotal);
            runningTotal += (p.second - runningTotal);
        }
        totalNotes = runningTotal;
        
        std::cout << "[INFO] Found " << availableShards.size() << " shards, "
                  << totalNotes << " total notes" << std::endl;
    }
    
    int64_t getShardStartIndex(uint64_t shardId) const {
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it == availableShards.end() || *it != shardId) {
            throw std::runtime_error("Shard not found: " + std::to_string(shardId));
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
    }
    
    void unloadShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it != activeShards.end()) {
            it->second.reader.flush();
            if (currentShard && currentShard->shardId == shardId) {
                currentShard = nullptr;
            }
            activeShards.erase(it);
        }
    }
    
    void managePool(uint64_t currentShardId) {
        // Remove shards that are far behind
        std::vector<uint64_t> toRemove;
        for (const auto& pair : activeShards) {
            if (pair.first + POOL_SIZE < currentShardId) {
                toRemove.push_back(pair.first);
            }
        }
        
        for (uint64_t shardId : toRemove) {
            unloadShard(shardId);
        }
        
        // Preload next shards
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), currentShardId);
        if (it != availableShards.end()) {
            size_t pos = std::distance(availableShards.begin(), it);
            size_t toLoad = std::min(size_t(POOL_SIZE - activeShards.size()), 
                                    availableShards.size() - pos);
            
            for (size_t i = 0; i < toLoad; ++i) {
                uint64_t nextShard = availableShards[pos + i];
                if (activeShards.find(nextShard) == activeShards.end()) {
                    loadShard(nextShard);
                }
            }
        }
    }
    
    uint64_t findShardForGlobalIndex(int64_t globalIndex) const {
        if (globalIndex < 0 || globalIndex >= totalNotes) {
            throw std::out_of_range("Global index out of range: " + std::to_string(globalIndex));
        }
        
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        if (it == shardStartIndices.begin()) {
            throw std::runtime_error("Invalid shard lookup");
        }
        
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        return availableShards[shardPos];
    }
    
public:
    ShardedChartReader(const char* path) : chartDir(path) {
        scanShards();
        if (availableShards.empty()) {
            throw std::runtime_error("No shards found in directory: " + chartDir);
        }
        
        // Load first few shards
        size_t initialLoad = std::min(size_t(10), availableShards.size());
        for (size_t i = 0; i < initialLoad; ++i) {
            loadShard(availableShards[i]);
        }
    }
    
    ~ShardedChartReader() {
        for (auto& pair : activeShards) {
            pair.second.reader.flush();
        }
        activeShards.clear();
        currentShard = nullptr;
    }
    
    inline uint64_t getNote(int64_t globalIndex) {
        // Fast path: same shard as last access
        if (currentShard && globalIndex >= currentShard->startIndex && 
            globalIndex < currentShard->endIndex) {
            return currentShard->reader.get(globalIndex - currentShard->startIndex);
        }
        
        // Slow path: need to find or load shard
        uint64_t shardId = findShardForGlobalIndex(globalIndex);
        
        if (activeShards.find(shardId) == activeShards.end()) {
            loadShard(shardId);
        }
        
        currentShard = &activeShards[shardId];
        managePool(shardId);
        
        return currentShard->reader.get(globalIndex - currentShard->startIndex);
    }
    
    inline void setNote(int64_t globalIndex, uint64_t value) {
        // Fast path: same shard
        if (currentShard && globalIndex >= currentShard->startIndex && 
            globalIndex < currentShard->endIndex) {
            currentShard->reader.set(globalIndex - currentShard->startIndex, value);
            return;
        }
        
        // Slow path
        uint64_t shardId = findShardForGlobalIndex(globalIndex);
        
        if (activeShards.find(shardId) == activeShards.end()) {
            loadShard(shardId);
        }
        
        currentShard = &activeShards[shardId];
        managePool(shardId);
        
        currentShard->reader.set(globalIndex - currentShard->startIndex, value);
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
    
    inline int64_t getLength() const {
        return totalNotes;
    }
    
    inline size_t getShardCount() const {
        return availableShards.size();
    }
    
    void printPoolStats() const {
        std::cout << "[POOL] Active shards: " << activeShards.size() 
                  << " / " << availableShards.size() << std::endl;
        if (currentShard) {
            std::cout << "[POOL] Current shard: " << currentShard->shardId << std::endl;
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
