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
#include <thread>
#include <mutex>
#include <future>
#include <unordered_map>

// Fix Windows min/max macros
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#undef NOMINMAX
#else
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#endif

// ============================================================================
// Portable filesystem helpers (no std::filesystem / C++17 required)
// ============================================================================

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

static std::string getStem(const std::string& filename) {
    size_t dot = filename.rfind('.');
    return (dot == std::string::npos) ? filename : filename.substr(0, dot);
}

static std::string getExtension(const std::string& filename) {
    size_t dot = filename.rfind('.');
    return (dot == std::string::npos) ? "" : filename.substr(dot);
}

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
    if (std::isnan(ms)) return "null";

    int milliseconds = static_cast<int>(ms * 0.1) % 100;
    int seconds = static_cast<int>(ms * 0.001);
    int hours = seconds / 3600;
    seconds %= 3600;
    int minutes = seconds / 60;
    seconds %= 60;

    std::string time;
    if (hours > 0) time += std::to_string(hours) + ":";
    if (minutes < 10 && hours > 0)
        time += "0" + std::to_string(minutes) + ":";
    else
        time += std::to_string(minutes) + ":";
    if (seconds < 10) time += "0";
    time += std::to_string(seconds);
    if (showMS) {
        time += ".";
        if (milliseconds < 10) time += "0";
        time += std::to_string(milliseconds);
    }
    return time;
}

// ============================================================================
// Memory-mapped file reader — read-only map, OS handles paging
// No explicit flush: the map is MAP_PRIVATE / PAGE_READONLY; writes go to
// an in-RAM dirty overlay and are never written back to disk.  The caller is
// responsible for any persistence it needs via its own mechanism.
// ============================================================================
class MappedFileReader {
private:
    std::string   filename;
    uint64_t*     mappedData  = nullptr;
    int64_t       mappedCount = 0;

    // Sparse dirty overlay - only stores modified entries
    std::unordered_map<int64_t, uint64_t> dirtyMap;
    bool hasDirty = false;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap  = NULL;
#else
    int    fd     = -1;
    size_t mapLen = 0;
#endif

    void closeMap() {
        if (!mappedData) return;
#ifdef _WIN32
        UnmapViewOfFile(mappedData);
        if (hMap  != NULL)                { CloseHandle(hMap);  hMap  = NULL; }
        if (hFile != INVALID_HANDLE_VALUE){ CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
        munmap(mappedData, mapLen);
        if (fd >= 0) { ::close(fd); fd = -1; }
        mapLen = 0;
#endif
        mappedData  = nullptr;
        mappedCount = 0;
    }

public:
    MappedFileReader()  = default;
    ~MappedFileReader() { closeMap(); }

    // Delete copy operations
    MappedFileReader(const MappedFileReader&)            = delete;
    MappedFileReader& operator=(const MappedFileReader&) = delete;

    // Add move operations
    MappedFileReader(MappedFileReader&& other) noexcept
        : filename(std::move(other.filename))
        , mappedData(other.mappedData)
        , mappedCount(other.mappedCount)
        , dirtyMap(std::move(other.dirtyMap))
        , hasDirty(other.hasDirty)
#ifdef _WIN32
        , hFile(other.hFile)
        , hMap(other.hMap)
#else
        , fd(other.fd)
        , mapLen(other.mapLen)
#endif
    {
        // Reset the source object
        other.mappedData = nullptr;
        other.mappedCount = 0;
        other.hasDirty = false;
#ifdef _WIN32
        other.hFile = INVALID_HANDLE_VALUE;
        other.hMap = NULL;
#else
        other.fd = -1;
        other.mapLen = 0;
#endif
    }

    MappedFileReader& operator=(MappedFileReader&& other) noexcept {
        if (this != &other) {
            closeMap();
            
            filename = std::move(other.filename);
            mappedData = other.mappedData;
            mappedCount = other.mappedCount;
            dirtyMap = std::move(other.dirtyMap);
            hasDirty = other.hasDirty;
#ifdef _WIN32
            hFile = other.hFile;
            hMap = other.hMap;
#else
            fd = other.fd;
            mapLen = other.mapLen;
#endif

            // Reset the source object
            other.mappedData = nullptr;
            other.mappedCount = 0;
            other.hasDirty = false;
#ifdef _WIN32
            other.hFile = INVALID_HANDLE_VALUE;
            other.hMap = NULL;
#else
            other.fd = -1;
            other.mapLen = 0;
#endif
        }
        return *this;
    }

    bool open(const char* path) {
        closeMap();
        filename = path;

#ifdef _WIN32
        hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return false;

        LARGE_INTEGER sz;
        if (!GetFileSizeEx(hFile, &sz) || sz.QuadPart == 0) { closeMap(); return false; }

        hMap = CreateFileMappingA(hFile, nullptr, PAGE_READONLY, 0, 0, nullptr);
        if (!hMap) { closeMap(); return false; }

        void* ptr = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
        if (!ptr) { closeMap(); return false; }

        mappedData  = static_cast<uint64_t*>(ptr);
        mappedCount = sz.QuadPart / sizeof(uint64_t);
#else
        fd = ::open(path, O_RDONLY);
        if (fd < 0) return false;

        struct stat st;
        if (fstat(fd, &st) != 0 || st.st_size == 0) { closeMap(); return false; }

        mapLen = static_cast<size_t>(st.st_size);
        void* ptr = mmap(nullptr, mapLen, PROT_READ, MAP_PRIVATE, fd, 0);
        if (ptr == MAP_FAILED) { closeMap(); return false; }

        madvise(ptr, mapLen, MADV_SEQUENTIAL);

        mappedData  = static_cast<uint64_t*>(ptr);
        mappedCount = static_cast<int64_t>(st.st_size) / sizeof(uint64_t);
#endif
        return true;
    }

    uint64_t get(int64_t index) const {
        if (index < 0 || index >= mappedCount)
            throw std::out_of_range("MappedFileReader::get out of range");
        
        // Check sparse dirty map first
        auto it = dirtyMap.find(index);
        if (it != dirtyMap.end()) return it->second;
        
        return mappedData[index];
    }

    void set(int64_t index, uint64_t value) {
        if (index < 0 || index >= mappedCount)
            throw std::out_of_range("MappedFileReader::set out of range");
        
        // If setting back to original value, remove from dirty map
        if (value == mappedData[index]) {
            auto it = dirtyMap.find(index);
            if (it != dirtyMap.end()) {
                dirtyMap.erase(it);
            }
            return;
        }
        
        // Store only the modification
        dirtyMap[index] = value;
    }

    int64_t size() const { return mappedCount; }
};

// ============================================================================
// Sharded Chart Reader with Pooling System, Binary Search, and Async Preload
// ============================================================================
class ShardedChartReader {
private:
    struct ShardInfo {
        MappedFileReader reader;
        int64_t  noteCount  = 0;
        uint64_t shardId    = 0;
        int64_t  startIndex = 0;
        int64_t  endIndex   = 0;
    };

    std::string chartDir;
    // Changed from std::map to std::unordered_map for O(1) lookup
    std::unordered_map<uint64_t, ShardInfo> activeShards;
    std::vector<uint64_t> availableShards;
    std::vector<int64_t>  shardStartIndices;
    uint64_t currentShardId = 0;
    int64_t  totalNotes     = 0;

    static constexpr int    POOL_SIZE          = 10;
    static constexpr int    PRELOAD_THRESHOLD  = 5;
    static constexpr size_t INITIAL_BYTE_BUDGET = 524288;

    int64_t correctionTime = 0;

    std::mutex pendingMutex;
    std::unordered_map<uint64_t, std::future<ShardInfo*>> pendingLoads;

    // ---- Sequential access optimization ----
    // Cache the last accessed shard info to avoid lookups
    struct AccessCache {
        uint64_t   shardId    = UINT64_MAX;
        ShardInfo* info       = nullptr;
        int64_t    localIndex = -1;
        int64_t    globalIndex = -1;
    };
    AccessCache readCache;   // For getNote
    AccessCache judgeCache;  // For judgement operations

    void scanShards() {
        std::vector<std::string> files;
        listFiles(chartDir, files);

        for (const auto& name : files) {
            if (getExtension(name) != ".bin") continue;
            std::string stem = getStem(name);
            try {
                availableShards.push_back(std::stoull(stem));
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
            cumulative += fileSize / sizeof(uint64_t);
        }
        totalNotes = cumulative;

        std::cout << "[INFO] Found " << availableShards.size() << " shards, "
                  << totalNotes << " total notes" << std::endl;
    }

    int64_t getShardStartIndex(uint64_t shardId) const {
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it == availableShards.end() || *it != shardId)
            throw std::runtime_error("Shard not found");
        return shardStartIndices[std::distance(availableShards.begin(), it)];
    }

    // Synchronous shard load — always called on the main thread for shards
    // that are needed immediately.
        void loadShard(uint64_t shardId) {
        {
            std::lock_guard<std::mutex> lk(pendingMutex);
            auto it = pendingLoads.find(shardId);
            if (it != pendingLoads.end()) {
                ShardInfo* info = it->second.get();
                pendingLoads.erase(it);
                if (info) {
                    if (activeShards.find(shardId) == activeShards.end()) {
                        activeShards.emplace(shardId, std::move(*info));
                    }
                    delete info;
                }
                return;
            }
        }
        if (activeShards.find(shardId) != activeShards.end()) return;

        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        
        // Pre-allocate and construct in-place
        ShardInfo info;
        info.shardId    = shardId;
        info.startIndex = getShardStartIndex(shardId);

        if (!info.reader.open(path.c_str())) {
            throw std::runtime_error("Failed to open shard: " + std::to_string(shardId));
        }

        info.noteCount = info.reader.size();
        info.endIndex  = info.startIndex + info.noteCount;
        
        activeShards.emplace(shardId, std::move(info));
    }

    // Optimized: Try sequential access first, fall back to search
    ShardInfo* getShardInfoFast(int64_t globalIndex, AccessCache& cache) {
        // Check if we can use sequential access (next note in same shard)
        if (cache.info && globalIndex >= cache.info->startIndex && 
            globalIndex < cache.info->endIndex) {
            return cache.info;
        }
        
        // Check cached shard range (from main cache)
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && 
            cachedShardInfo) {
            cache.info = cachedShardInfo;
            cache.shardId = cachedShardId;
            return cachedShardInfo;
        }

        // Fall through to full lookup
        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");

        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        uint64_t shardId = availableShards[shardPos];

        // Only do pool management on actual shard transitions
        if (shardId != currentShardId && (shardId / 10 != currentShardId / 10)) {
            currentShardId = shardId;
            managePool(currentShardId);
        }

        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) {
            loadShard(shardId);
            mapIt = activeShards.find(shardId);
        }

        // Update all caches
        cachedShardId    = shardId;
        cachedShardStart = shardStartIndices[shardPos];
        cachedShardEnd   = mapIt->second.endIndex;
        cachedShardInfo  = &mapIt->second;
        
        cache.shardId = shardId;
        cache.info = cachedShardInfo;
        
        return cachedShardInfo;
    }

    // Fire-and-forget async preload — maps the file on a background thread so
    // the virtual address range (and first pages) are warm before the main
    // thread needs them.
    void asyncLoadShard(uint64_t shardId) {
        if (activeShards.find(shardId) != activeShards.end()) return;

        std::lock_guard<std::mutex> lk(pendingMutex);
        if (pendingLoads.find(shardId) != pendingLoads.end()) return;

        std::string path     = chartDir + "/" + std::to_string(shardId) + ".bin";
        int64_t     startIdx = getShardStartIndex(shardId);

        pendingLoads[shardId] = std::async(std::launch::async, [shardId, path, startIdx]() -> ShardInfo* {
            ShardInfo* info = new ShardInfo();
            info->shardId    = shardId;
            info->startIndex = startIdx;
            if (!info->reader.open(path.c_str())) { delete info; return nullptr; }
            info->noteCount = info->reader.size();
            info->endIndex  = info->startIndex + info->noteCount;
            return info;
        });
    }

    // Collect any completed async loads into activeShards
    void drainPending() {
        std::lock_guard<std::mutex> lk(pendingMutex);
        for (auto it = pendingLoads.begin(); it != pendingLoads.end(); ) {
            if (it->second.wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
                ShardInfo* info = it->second.get();
                if (info && activeShards.find(it->first) == activeShards.end()) {
                    // Adopt via piecewise_construct — works with non-copyable MappedFileReader
                    activeShards.emplace(
                        std::piecewise_construct,
                        std::forward_as_tuple(it->first),
                        std::forward_as_tuple()  // default-construct ShardInfo slot...
                    );
                    // ...then move the heap result in
                    activeShards[it->first] = std::move(*info);
                    delete info;
                } else {
                    delete info;
                }
                it = pendingLoads.erase(it);
            } else {
                ++it;
            }
        }
    }

    void unloadShard(uint64_t shardId) {
        // Cancel any pending async load for this shard
        {
            std::lock_guard<std::mutex> lk(pendingMutex);
            auto pit = pendingLoads.find(shardId);
            if (pit != pendingLoads.end()) {
                pit->second.wait();
                pendingLoads.erase(pit);
            }
        }

        auto it = activeShards.find(shardId);
        if (it != activeShards.end()) {
            activeShards.erase(it);
            if (shardId == cachedShardId) {
                cachedShardInfo  = nullptr;
                cachedShardStart = -1;
                cachedShardEnd   = -1;
            }
        }
    }

   void managePool(uint64_t currentShard) {
        // Only drain pending loads periodically
        drainPending();

        // Batch eviction
        std::vector<uint64_t> toRemove;
        for (auto& pair : activeShards) {
            if (pair.first + POOL_SIZE < currentShard)
                toRemove.push_back(pair.first);
        }
        for (uint64_t id : toRemove) unloadShard(id);
    }

public:
    std::vector<uint8_t> globalJudgement;
    bool globalJudgementInitialized = false;

    void initGlobalJudgement() {
        if (globalJudgementInitialized) return;
        // Allocate enough bytes for totalNotes bits
        globalJudgement.assign((totalNotes + 7) >> 3, 0);
        globalJudgementInitialized = true;
    }

    ShardedChartReader(const char* path) : chartDir(path) {
        scanShards();
        if (availableShards.empty())
            throw std::runtime_error("No shards found in directory");
        
        // Initialize global judgement buffer immediately
        initGlobalJudgement();

        // Load synchronously up to INITIAL_BYTE_BUDGET bytes worth of shards
        size_t bytesLoaded = 0;
        for (size_t i = 0; i < availableShards.size() && bytesLoaded < INITIAL_BYTE_BUDGET; i++) {
            uint64_t shardId  = availableShards[i];
            size_t   shardPos = i;
            int64_t  end      = (shardPos + 1 < shardStartIndices.size())
                              ? shardStartIndices[shardPos + 1]
                              : totalNotes;
            int64_t  noteCount = end - shardStartIndices[shardPos];
            size_t   shardBytes = static_cast<size_t>(noteCount) * sizeof(uint64_t);

            loadShard(shardId);
            bytesLoaded += shardBytes;
        }
    }

    ~ShardedChartReader() {
        // Wait for all pending async loads to finish before tearing down
        std::lock_guard<std::mutex> lk(pendingMutex);
        for (auto& pair : pendingLoads) pair.second.wait();
        pendingLoads.clear();
        activeShards.clear();
    }

    // Hot path cache
    int64_t    cachedShardStart = -1;
    int64_t    cachedShardEnd   = -1;
    uint64_t   cachedShardId    = 0;
    ShardInfo* cachedShardInfo  = nullptr;

    uint64_t findShardForGlobalIndex(int64_t globalIndex) const {
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd)
            return cachedShardId;
        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        return availableShards[std::distance(shardStartIndices.begin(), it) - 1];
    }

    ShardInfo* getShardInfo(int64_t globalIndex) {
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && cachedShardInfo)
            return cachedShardInfo;

        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");

        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t   shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        uint64_t shardId  = availableShards[shardPos];

        if (shardId != currentShardId) {
            currentShardId = shardId;
            managePool(currentShardId);
        }

        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) {
            loadShard(shardId);   // synchronous fallback if async hasn't landed yet
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
        uint8_t* data      = nullptr;
        int64_t  byteCount = 0;
        bool     active    = false;
    };

    JudgementSlot judgementSlots[MAX_JUDGEMENT_SLOTS];
    int activeJudgementSlot = 0;

    // Optimized getNote with sequential access
    uint64_t getNote(int64_t globalIndex) {
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        correctionTime = info->shardId * 1000000000;
        return info->reader.get(globalIndex - info->startIndex);
    }

    void setNote(int64_t globalIndex, uint64_t value) {
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        info->reader.set(globalIndex - info->startIndex, value);
    }

    // UPDATED: Use global buffer instead of shard-local vector
    bool core_getJudgement(int64_t globalIndex) {
        if (!globalJudgementInitialized) initGlobalJudgement();
        if (globalIndex < 0 || globalIndex >= totalNotes) return false;
        
        int64_t byteIndex = globalIndex >> 3;
        int     bitIndex  = globalIndex & 7;
        
        if (byteIndex >= (int64_t)globalJudgement.size()) return false;
        return (globalJudgement[byteIndex] >> bitIndex) & 1;
    }

    // UPDATED: Use global buffer
    void core_setJudgement(int64_t globalIndex, bool value) {
        if (!globalJudgementInitialized) initGlobalJudgement();
        if (globalIndex < 0 || globalIndex >= totalNotes) return;

        int64_t byteIndex = globalIndex >> 3;
        int     bitIndex  = globalIndex & 7;
        
        if (byteIndex >= (int64_t)globalJudgement.size()) return;
        
        if (value) 
            globalJudgement[byteIndex] |=  (1 << bitIndex);
        else       
            globalJudgement[byteIndex] &= ~(1 << bitIndex);
    }

    void printNoteInfo(int64_t globalIndex) {
        uint64_t note = getNote(globalIndex);

        uint32_t positionTicks  = (note >>  0) & 0x7FFFFFFF;
        uint32_t durationHalfMs = (note >> 31) & 0x1FFFF;
        uint8_t  index          = (note >> 48) & 0xFF;
        uint8_t  type           = (note >> 56) & 0x7F;
        bool     missed         = (note >> 63) & 1;
        bool     judged         = core_getJudgement(globalIndex);

        double timeMs     = positionTicks / 4000000.0;
        double durationMs = durationHalfMs * 0.5;

        std::cout << "  Note " << globalIndex << ": "
                  << "time="   << formatTime(timeMs, true)
                  << " pos="   << positionTicks  << "ticks"
                  << " dur="   << durationMs     << "ms"
                  << " idx="   << (int)index
                  << " type="  << (int)type
                  << " judged="<< (judged ? "Y" : "N")
                  << " missed="<< (missed ? "Y" : "N")
                  << " raw=0x" << std::hex << note << std::dec << std::endl;
    }

    int64_t getLength()     const { return totalNotes; }
    size_t  getShardCount() const { return availableShards.size(); }

    void printPoolStats() const {
        std::cout << "[POOL] Active shards: " << activeShards.size()
                  << " / " << availableShards.size() << std::endl;
        int count = 0;
        for (const auto& pair : activeShards) {
            if (count++ >= 10) {
                std::cout << "  ... and " << (activeShards.size() - 10) << " more" << std::endl;
                break;
            }
            std::cout << "  Shard " << pair.first << ": " << pair.second.noteCount << " notes" << std::endl;
        }
    }
};

// ============================================================================
// Global API
// ============================================================================
static ShardedChartReader* gReader = nullptr;

void core_loadChart(const char* path) {
    if (gReader) { delete gReader; gReader = nullptr; }
    gReader = new ShardedChartReader(path);
}

void core_destroyChart() {
    ShardedChartReader* old = gReader;
    gReader = nullptr;
    std::thread([old]{ delete old; }).detach();
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