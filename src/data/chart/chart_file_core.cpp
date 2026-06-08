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
// Shard Header Structure (matches chart_converter.cpp)
// ============================================================================
struct ShardHeader {
    int64_t noteCount;   // Actual number of notes in this shard
    int64_t capacity;    // Total capacity (number of note slots)
    int64_t reserved[6]; // Reserved for future use (padding to 64 bytes)
};

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
        if (entry->d_type == DT_REG) {
            out.push_back(entry->d_name);
        } else if (entry->d_type == DT_UNKNOWN) {
            struct stat st;
            std::string full = dir + "/" + entry->d_name;
            if (::stat(full.c_str(), &st) == 0 && S_ISREG(st.st_mode))
                out.push_back(entry->d_name);
        }
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
// Memory-mapped file reader with header support
// ============================================================================
class MappedFileReader {
private:
    std::string   filename;
    uint64_t*     mappedData  = nullptr;  // Points to note data (after header)
    int64_t       mappedCount = 0;        // Number of note slots (capacity)
    ShardHeader   header;                  // Header data

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap  = NULL;
#else
    int    fd     = -1;
    size_t mapLen = 0;
#endif

public:
    void closeMap() {
#ifdef _WIN32
        if (mappedData) {
            void* headerPtr = static_cast<char*>(static_cast<void*>(mappedData)) - sizeof(ShardHeader);
            UnmapViewOfFile(headerPtr);
        }
        if (hMap  != NULL)                 { CloseHandle(hMap);  hMap  = NULL; }
        if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
        if (mappedData) {
            void* headerPtr = static_cast<char*>(static_cast<void*>(mappedData)) - sizeof(ShardHeader);
            munmap(headerPtr, mapLen);
        }
        if (fd >= 0) { ::close(fd); fd = -1; }
        mapLen = 0;
#endif
        mappedData  = nullptr;
        mappedCount = 0;
        memset(&header, 0, sizeof(header));
    }

    MappedFileReader()  = default;
    ~MappedFileReader() { closeMap(); }

    // Delete copy operations
    MappedFileReader(const MappedFileReader&)            = delete;
    MappedFileReader& operator=(const MappedFileReader&) = delete;

    // Move operations
    MappedFileReader(MappedFileReader&& other) noexcept
        : filename(std::move(other.filename))
        , mappedData(other.mappedData)
        , mappedCount(other.mappedCount)
        , header(other.header)
#ifdef _WIN32
        , hFile(other.hFile)
        , hMap(other.hMap)
#else
        , fd(other.fd)
        , mapLen(other.mapLen)
#endif
    {
        other.mappedData = nullptr;
        other.mappedCount = 0;
        memset(&other.header, 0, sizeof(other.header));
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
            header = other.header;
#ifdef _WIN32
            hFile = other.hFile;
            hMap = other.hMap;
#else
            fd = other.fd;
            mapLen = other.mapLen;
#endif

            other.mappedData = nullptr;
            other.mappedCount = 0;
            memset(&other.header, 0, sizeof(other.header));
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
        hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return false;

        LARGE_INTEGER sz;
        if (!GetFileSizeEx(hFile, &sz)) { closeMap(); return false; }
        if (sz.QuadPart < sizeof(ShardHeader)) { closeMap(); return false; }

        hMap = CreateFileMappingA(hFile, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        if (!hMap) { closeMap(); return false; }

        void* ptr = MapViewOfFile(hMap, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
        if (!ptr) { closeMap(); return false; }

        // Read header from beginning of file
        memcpy(&header, ptr, sizeof(ShardHeader));
        
        // Data starts after header
        mappedData = (uint64_t*)(static_cast<char*>(ptr) + sizeof(ShardHeader));
        mappedCount = (sz.QuadPart - sizeof(ShardHeader)) / sizeof(uint64_t);
#else
        fd = ::open(path, O_RDWR);
        if (fd < 0) return false;

        struct stat st;
        if (fstat(fd, &st) != 0) { closeMap(); return false; }
        if (st.st_size < sizeof(ShardHeader)) { closeMap(); return false; }

        mapLen = static_cast<size_t>(st.st_size);
        void* ptr = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (ptr == MAP_FAILED) { closeMap(); return false; }

        // Read header from beginning of file
        memcpy(&header, ptr, sizeof(ShardHeader));
        
        // Data starts after header
        mappedData = (uint64_t*)(static_cast<char*>(ptr) + sizeof(ShardHeader));
        mappedCount = (st.st_size - sizeof(ShardHeader)) / sizeof(uint64_t);
#endif
        return true;
    }

    uint64_t get(int64_t index) const {
        if (index < 0 || index >= header.noteCount || index >= mappedCount)
            throw std::out_of_range("MappedFileReader::get out of range");
        return mappedData[index];
    }

    void set(int64_t index, uint64_t value) {
        if (index < 0 || index >= mappedCount)
            throw std::out_of_range("MappedFileReader::set out of range");
        mappedData[index] = value;
    }

    int64_t size() const { return mappedCount; }      // Returns capacity
    int64_t getNoteCount() const { return header.noteCount; }
    int64_t getCapacity() const { return header.capacity; }
    
    void setNoteCount(int64_t count) {
        header.noteCount = count;
        // Write header back to mapped memory
        void* headerPtr = static_cast<char*>(static_cast<void*>(mappedData)) - sizeof(ShardHeader);
        memcpy(headerPtr, &header, sizeof(ShardHeader));
#ifdef _WIN32
        FlushViewOfFile(headerPtr, sizeof(ShardHeader));
#else
        msync(headerPtr, sizeof(ShardHeader), MS_ASYNC);
#endif
    }
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
    std::unordered_map<uint64_t, ShardInfo> activeShards;
    std::vector<uint64_t> availableShards;
    std::vector<int64_t>  shardStartIndices;
    uint64_t currentShardId = 0;
    int64_t  totalNotes     = 0;

    static constexpr int    POOL_SIZE          = 10;
    static constexpr int    PRELOAD_THRESHOLD  = 5;
    static constexpr size_t INITIAL_BYTE_BUDGET = 524288;
    static constexpr int64_t DEFAULT_SHARD_CAPACITY = 32;

    int64_t correctionTime = 0;

    std::mutex pendingMutex;
    std::unordered_map<uint64_t, std::future<ShardInfo*>> pendingLoads;

    struct AccessCache {
        uint64_t   shardId    = UINT64_MAX;
        ShardInfo* info       = nullptr;
        int64_t    localIndex = -1;
        int64_t    globalIndex = -1;
    };
    AccessCache readCache;
    AccessCache judgeCache;

    int64_t getShardStartIndex(uint64_t shardId) const {
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it == availableShards.end() || *it != shardId) {
            throw std::runtime_error("Shard not found: " + std::to_string(shardId));
        }
        size_t idx = std::distance(availableShards.begin(), it);
        if (idx >= shardStartIndices.size()) {
            // This shouldn't happen if createShardFile updated both vectors
            throw std::runtime_error("Shard start index out of range for shard " + std::to_string(shardId));
        }
        return shardStartIndices[idx];
    }

        // Lightweight function to read just the header
    ShardHeader readHeaderOnly(uint64_t shardId) const {
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        std::ifstream file(path, std::ios::binary);
        if (!file) {
            throw std::runtime_error("Cannot open shard: " + path);
        }
        
        ShardHeader header;
        file.read(reinterpret_cast<char*>(&header), sizeof(ShardHeader));
        file.close();  // Close immediately - don't keep open
        
        return header;
    }
    
    void scanShards() {
        std::vector<std::string> files;
        listFiles(chartDir, files);
        
        struct TempInfo {
            uint64_t shardId;
            int64_t noteCount;
        };
        std::vector<TempInfo> tempInfos;
        tempInfos.reserve(files.size());
        
        for (const auto& name : files) {
            if (getExtension(name) != ".bin") continue;
            
            std::string stem = getStem(name);
            uint64_t shardId;
            try {
                shardId = std::stoull(stem);
            } catch (...) {
                std::cerr << "Warning: Invalid shard filename: " << name << std::endl;
                continue;
            }
            
            // Read ONLY the header, then close the file
            ShardHeader header = readHeaderOnly(shardId);
            tempInfos.push_back({shardId, header.noteCount});
        }
        
        // Sort by shard ID
        std::sort(tempInfos.begin(), tempInfos.end(),
                  [](const TempInfo& a, const TempInfo& b) { return a.shardId < b.shardId; });
        
        // Build indices
        availableShards.clear();
        shardStartIndices.clear();
        int64_t cumulative = 0;
        
        for (const auto& info : tempInfos) {
            availableShards.push_back(info.shardId);
            shardStartIndices.push_back(cumulative);
            cumulative += info.noteCount;
        }
        totalNotes = cumulative;
    }
    
    // Keep loadShard() for actual note access (memory-mapped, stays open)
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
        
        ShardInfo info;
        info.shardId    = shardId;
        info.startIndex = getShardStartIndex(shardId);
        
        // This now does the full memory-mapped open (expensive, but only when needed)
        if (!info.reader.open(path.c_str())) {
            throw std::runtime_error("Failed to open shard: " + std::to_string(shardId));
        }
        
        info.noteCount = info.reader.getNoteCount();
        info.endIndex  = info.startIndex + info.noteCount;
        
        activeShards.emplace(shardId, std::move(info));
    }

    ShardInfo* getShardInfoFast(int64_t globalIndex, AccessCache& cache) {
        if (cache.info && globalIndex >= cache.info->startIndex && 
            globalIndex < cache.info->endIndex) {
            return cache.info;
        }
        
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && 
            cachedShardInfo) {
            cache.info = cachedShardInfo;
            cache.shardId = cachedShardId;
            return cachedShardInfo;
        }

        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");
        
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        uint64_t shardId = availableShards[shardPos];

        if (shardId != currentShardId && (shardId / 10 != currentShardId / 10)) {
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
        cachedShardEnd   = mapIt->second.endIndex;
        cachedShardInfo  = &mapIt->second;
        
        cache.shardId = shardId;
        cache.info = cachedShardInfo;
        
        return cachedShardInfo;
    }

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
            info->noteCount = info->reader.getNoteCount();
            info->endIndex  = info->startIndex + info->noteCount;
            return info;
        });
    }

    void drainPending() {
        std::lock_guard<std::mutex> lk(pendingMutex);
        for (auto it = pendingLoads.begin(); it != pendingLoads.end(); ) {
            if (it->second.wait_for(std::chrono::seconds(0)) == std::future_status::ready) {
                ShardInfo* info = it->second.get();
                if (info && activeShards.find(it->first) == activeShards.end()) {
                    activeShards.emplace(
                        std::piecewise_construct,
                        std::forward_as_tuple(it->first),
                        std::forward_as_tuple()
                    );
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
        drainPending();

        std::vector<uint64_t> toRemove;
        for (auto& pair : activeShards) {
            if (pair.first + POOL_SIZE < currentShard)
                toRemove.push_back(pair.first);
        }
        for (uint64_t id : toRemove) unloadShard(id);
    }

    void rebuildShardStartIndices() {
        shardStartIndices.clear();
        int64_t cumulative = 0;
        
        for (uint64_t shardId : availableShards) {
            shardStartIndices.push_back(cumulative);
            
            // Get note count from activeShards if loaded, otherwise read from file header
            auto it = activeShards.find(shardId);
            if (it != activeShards.end()) {
                cumulative += it->second.noteCount;
            } else {
                // Read header from file
                std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
                std::ifstream file(path, std::ios::binary);
                if (file) {
                    ShardHeader header;
                    file.read(reinterpret_cast<char*>(&header), sizeof(ShardHeader));
                    cumulative += header.noteCount;
                }
            }
        }
        totalNotes = cumulative;
        
        // Also update all loaded shards' startIndex and endIndex
        for (auto& pair : activeShards) {
            auto idxIt = std::lower_bound(availableShards.begin(), availableShards.end(), pair.first);
            if (idxIt != availableShards.end()) {
                size_t pos = std::distance(availableShards.begin(), idxIt);
                pair.second.startIndex = shardStartIndices[pos];
                pair.second.endIndex = pair.second.startIndex + pair.second.noteCount;
            }
        }
    }

    void createShardFile(uint64_t shardId, int64_t initialCapacity = DEFAULT_SHARD_CAPACITY) {
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        
        std::cout << "  Creating shard file: " << path << " with capacity " << initialCapacity << std::endl;
        
        ShardHeader header;
        header.noteCount = 0;
        header.capacity = initialCapacity;
        memset(header.reserved, 0, sizeof(header.reserved));
        
        std::vector<uint64_t> zeros(initialCapacity, 0);
        
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        if (!file) {
            throw std::runtime_error("Failed to create shard: " + path);
        }
        file.write(reinterpret_cast<const char*>(&header), sizeof(ShardHeader));
        file.write(reinterpret_cast<const char*>(zeros.data()), initialCapacity * sizeof(uint64_t));
        file.close();
        
        // Add to availableShards if not already present
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it == availableShards.end() || *it != shardId) {
            availableShards.insert(it, shardId);
            rebuildShardStartIndices();  // Rebuild all indices after adding new shard
        }
    }

    void remapShard(uint64_t shardId, int64_t newCapacity) {
        auto it = activeShards.find(shardId);
        if (it == activeShards.end()) return;
        
        ShardInfo& shard = it->second;
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        
        int64_t oldNoteCount = shard.noteCount;
        
        // Close old mapping FIRST
        shard.reader.closeMap();
        
        // Resize the file (header + newCapacity notes)
        int64_t newFileSize = sizeof(ShardHeader) + newCapacity * sizeof(uint64_t);
#ifdef _WIN32
        HANDLE hFile = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) {
            throw std::runtime_error("Failed to open shard for resize: " + path);
        }
        
        LARGE_INTEGER li;
        li.QuadPart = newFileSize;
        SetFilePointerEx(hFile, li, nullptr, FILE_BEGIN);
        if (!SetEndOfFile(hFile)) {
            CloseHandle(hFile);
            throw std::runtime_error("Failed to resize shard: " + path);
        }
        CloseHandle(hFile);
#else
        if (truncate(path.c_str(), newFileSize) != 0) {
            throw std::runtime_error("Failed to resize shard: " + path);
        }
#endif
        
        // Reopen with new size
        if (!shard.reader.open(path.c_str())) {
            throw std::runtime_error("Failed to remap shard: " + path);
        }
        
        // Update header with new capacity, preserve noteCount
        shard.reader.setNoteCount(oldNoteCount);
        
        shard.noteCount = oldNoteCount;
        shard.endIndex = shard.startIndex + shard.noteCount;
    }

public:
    std::vector<uint8_t> globalJudgement;
    bool globalJudgementInitialized = false;

    void initGlobalJudgement() {
        if (globalJudgementInitialized) return;
        globalJudgement.assign((totalNotes + 7) >> 3, 0);
        globalJudgementInitialized = true;
    }

    ShardedChartReader(const char* path) : chartDir(path) {
        auto start = std::chrono::steady_clock::now();
        
        scanShards();
        auto scanTime = std::chrono::steady_clock::now();
        
        initGlobalJudgement();
        auto initTime = std::chrono::steady_clock::now();
        
        size_t bytesLoaded = 0;
        for (size_t i = 0; i < availableShards.size() && bytesLoaded < INITIAL_BYTE_BUDGET; i++) {
            uint64_t shardId = availableShards[i];
            loadShard(shardId);
            bytesLoaded += shardStartIndices[i + 1] - shardStartIndices[i];
        }
        auto loadTime = std::chrono::steady_clock::now();
        
        /*std::cout << "Scan time: " << std::chrono::duration_cast<std::chrono::milliseconds>(scanTime - start).count() << "ms\n";
        std::cout << "Init time: " << std::chrono::duration_cast<std::chrono::milliseconds>(initTime - scanTime).count() << "ms\n";
        std::cout << "Load time: " << std::chrono::duration_cast<std::chrono::milliseconds>(loadTime - initTime).count() << "ms\n";*/
    }

    ~ShardedChartReader() {
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

    uint64_t getNote(int64_t globalIndex) {
        if (globalIndex < 0 || globalIndex >= totalNotes) {
            std::cout << "ERROR: getNote(" << globalIndex << ") but totalNotes=" << totalNotes << std::endl;
            throw std::out_of_range("getNote: globalIndex out of range");
        }
        
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        int64_t localIndex = globalIndex - info->startIndex;
        
        if (localIndex < 0 || localIndex >= info->noteCount) {
            std::cout << "ERROR: localIndex=" << localIndex << " but noteCount=" << info->noteCount 
                    << " (globalIndex=" << globalIndex << ", startIndex=" << info->startIndex << ")" << std::endl;
            throw std::out_of_range("getNote: localIndex out of range");
        }
        
        correctionTime = info->shardId * 1000000000;
        return info->reader.get(localIndex);
    }

    void setNote(int64_t globalIndex, uint64_t value) {
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        info->reader.set(globalIndex - info->startIndex, value);
    }

    bool core_getJudgement(int64_t globalIndex) {
        if (!globalJudgementInitialized) initGlobalJudgement();
        if (globalIndex < 0 || globalIndex >= totalNotes) return false;
        
        int64_t byteIndex = globalIndex >> 3;
        int     bitIndex  = globalIndex & 7;
        
        if (byteIndex >= (int64_t)globalJudgement.size()) return false;
        return (globalJudgement[byteIndex] >> bitIndex) & 1;
    }

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

    void insertNote(int64_t globalPosition, int duration, int index, int type) {
        int64_t shardId = globalPosition / 2000000000;
        int64_t localPos = globalPosition % 2000000000;
        
        uint64_t packedNote = 
            ((uint64_t)(localPos & 0x7FFFFFFF) << 0) |
            ((uint64_t)(duration & 0x1FFFF) << 31) |
            ((uint64_t)(index & 0xFF) << 48) |
            ((uint64_t)(type & 0x7F) << 56) |
            ((uint64_t)(0) << 63);
        
        // Invalidate caches
        cachedShardInfo = nullptr;
        cachedShardStart = -1;
        cachedShardEnd = -1;
        readCache.info = nullptr;
        judgeCache.info = nullptr;
        
        // Get or create shard
        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) {
            std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
            std::ifstream test(path);
            bool exists = test.good();
            test.close();
            
            if (!exists) {
                createShardFile(shardId, DEFAULT_SHARD_CAPACITY);
            }
            loadShard(shardId);
            mapIt = activeShards.find(shardId);
            if (mapIt == activeShards.end())
                throw std::runtime_error("Failed to load shard: " + std::to_string(shardId));
        }
        
        ShardInfo& shard = mapIt->second;
        
        // Check capacity and grow if needed
        int64_t currentCapacity = shard.reader.size();
        if (shard.noteCount + 1 > currentCapacity) {
            int64_t newCapacity = std::max<int64_t>(currentCapacity + 64, (int64_t)(currentCapacity * 1.5));
            remapShard(shardId, newCapacity);
            mapIt = activeShards.find(shardId);
        }
        
        ShardInfo& refreshedShard = mapIt->second;
        
        // SIMPLY APPEND at the end (O(1))
        refreshedShard.reader.set(refreshedShard.noteCount, packedNote);
        refreshedShard.noteCount++;
        refreshedShard.endIndex++;
        refreshedShard.reader.setNoteCount(refreshedShard.noteCount);
        
        totalNotes++;
        
        // Sort this shard (O(n) radix sort)
        sortShard(shardId);
        
        // Update global indices
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), (uint64_t)shardId);
        if (it != availableShards.end() && *it == (uint64_t)shardId) {
            size_t shardPos = std::distance(availableShards.begin(), it);
            
            // Update shardStartIndices for this and subsequent shards
            for (size_t i = shardPos; i < shardStartIndices.size(); i++) {
                shardStartIndices[i]++;
            }
            
            // Update activeShards for this and subsequent shards
            for (auto& pair : activeShards) {
                if (pair.first >= (uint64_t)shardId) {
                    pair.second.startIndex++;
                    pair.second.endIndex++;
                }
            }
        }
    }

    void sortShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it == activeShards.end()) return;
        
        ShardInfo& shard = it->second;
        if (shard.noteCount <= 1) return;
        
        // Read all notes into a vector
        std::vector<uint64_t> notes(shard.noteCount);
        for (int64_t i = 0; i < shard.noteCount; i++) {
            notes[i] = shard.reader.get(i);
        }
        
        // Radix sort by local position (31 bits)
        radixSortShardInPlace(notes);
        
        // Write back sorted notes
        for (int64_t i = 0; i < shard.noteCount; i++) {
            shard.reader.set(i, notes[i]);
        }
    }

    void radixSortShardInPlace(std::vector<uint64_t>& notes) {
        if (notes.size() <= 1) return;
        
        auto getLocalPos = [](uint64_t note) -> uint32_t {
            return (note >> 0) & 0x7FFFFFFF;
        };
        
        // Find max value to determine number of passes
        uint32_t maxPos = 0;
        for (uint64_t note : notes) {
            uint32_t pos = getLocalPos(note);
            if (pos > maxPos) maxPos = pos;
        }
        
        // Count number of passes needed (based on maxPos bits)
        int maxBits = 0;
        while (maxPos > 0) {
            maxBits++;
            maxPos >>= 1;
        }
        int passes = (maxBits + 7) / 8;  // Number of byte passes needed
        
        // Temporary buffer (reuse to avoid reallocation)
        static thread_local std::vector<uint64_t> buffer;
        buffer.resize(notes.size());
        
        // LSD radix sort by bytes
        for (int shift = 0; shift < passes * 8; shift += 8) {
            int counts[256] = {0};
            
            // Count
            for (uint64_t note : notes) {
                uint32_t pos = getLocalPos(note);
                counts[(pos >> shift) & 0xFF]++;
            }
            
            // Prefix sum
            for (int i = 1; i < 256; i++) {
                counts[i] += counts[i-1];
            }
            
            // Sort (stable, in-place using buffer)
            for (int i = (int)notes.size() - 1; i >= 0; i--) {
                uint32_t pos = getLocalPos(notes[i]);
                buffer[--counts[(pos >> shift) & 0xFF]] = notes[i];
            }
            
            notes.swap(buffer);
        }
    }

    void removeNote(int64_t globalIndex) {
        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");
        
        // Find which shard contains this global index
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = std::distance(shardStartIndices.begin(), it) - 1;
        uint64_t shardId = availableShards[shardPos];
        
        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) {
            loadShard(shardId);
            mapIt = activeShards.find(shardId);
        }
        
        ShardInfo& shard = mapIt->second;
        int64_t localIndex = globalIndex - shard.startIndex;
        
        // Shift all notes after localIndex left by 1
        for (int64_t i = localIndex; i < shard.noteCount - 1; i++) {
            uint64_t nextNote = shard.reader.get(i + 1);
            shard.reader.set(i, nextNote);
        }
        
        // Update shard metadata
        shard.noteCount--;
        shard.endIndex--;
        shard.reader.setNoteCount(shard.noteCount);
        
        // Update totalNotes globally
        totalNotes--;
        
        // Update shardStartIndices for all subsequent shards
        for (size_t i = shardPos + 1; i < availableShards.size(); i++) {
            shardStartIndices[i]--;
        }
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

void core_insertNote(int64_t globalPosition, int duration, int index, int type) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->insertNote(globalPosition, duration, index, type);
}

void core_removeNote(int64_t globalIndex) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->removeNote(globalIndex);
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