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
#include <unordered_set>
#include <cerrno>
#include <climits>
#include <queue>
#include <condition_variable>
#include <chrono>
#include <memory>

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

struct ShardHeader {
    int64_t noteCount;
    int64_t capacity;
    int64_t reserved[6];
};

struct ShardMetaEntry {
    uint64_t shardId;
    int64_t noteCount;
    int64_t capacity;
    int64_t reserved[6];
};

static int64_t getFileSize(const std::string& path) {
#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA info;
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &info)) return -1;
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
        if (!(ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) out.push_back(ffd.cFileName);
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
            if (::stat(full.c_str(), &st) == 0 && S_ISREG(st.st_mode)) out.push_back(entry->d_name);
        }
    }
    closedir(d);
#endif
}

std::string formatTime(double ms, bool showMS = false) {
    if (std::isnan(ms)) return "null";
    int milliseconds = static_cast<int>(ms * 0.1) % 100;
    int seconds = static_cast<int>(ms * 0.001);
    int hours = seconds / 3600; seconds %= 3600;
    int minutes = seconds / 60; seconds %= 60;
    std::string time;
    if (hours > 0) time += std::to_string(hours) + ":";
    if (minutes < 10 && hours > 0) time += "0" + std::to_string(minutes) + ":";
    else time += std::to_string(minutes) + ":";
    if (seconds < 10) time += "0";
    time += std::to_string(seconds);
    if (showMS) {
        time += ".";
        if (milliseconds < 10) time += "0";
        time += std::to_string(milliseconds);
    }
    return time;
}

class MappedFileReader {
private:
    std::string filename;
    uint64_t* mappedData = nullptr;
    int64_t mappedCount = 0;
    ShardHeader header;
    
    static constexpr size_t BUFFER_ELEMENTS = 4096; // 32KB
    mutable uint64_t buffer[BUFFER_ELEMENTS]; 
    mutable int64_t bufferBase = -1;
    mutable bool bufferDirty = false;

    void flushBufferToDisk() const {
        if (bufferDirty && bufferBase >= 0 && mappedData) {
            int64_t count = std::min<int64_t>((int64_t)BUFFER_ELEMENTS, mappedCount - bufferBase);
            std::memcpy(mappedData + bufferBase, buffer, count * sizeof(uint64_t));
            bufferDirty = false;
        }
    }

    void loadBufferFromDisk(int64_t baseIndex) const {
        flushBufferToDisk();
        bufferBase = baseIndex;
        int64_t count = std::min<int64_t>((int64_t)BUFFER_ELEMENTS, mappedCount - baseIndex);
        std::memcpy(buffer, mappedData + baseIndex, count * sizeof(uint64_t));
    }
    
#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap = NULL;
#else
    int fd = -1;
    size_t mapLen = 0;
#endif

public:
    void closeMap() {
        flushBufferToDisk();
#ifdef _WIN32
        if (mappedData) {
            void* headerPtr = static_cast<char*>(static_cast<void*>(mappedData)) - sizeof(ShardHeader);
            UnmapViewOfFile(headerPtr);
        }
        if (hMap != NULL) { CloseHandle(hMap); hMap = NULL; }
        if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
        if (mappedData) {
            void* headerPtr = static_cast<char*>(static_cast<void*>(mappedData)) - sizeof(ShardHeader);
            munmap(headerPtr, mapLen);
        }
        if (fd >= 0) { ::close(fd); fd = -1; }
        mapLen = 0;
#endif
        mappedData = nullptr;
        mappedCount = 0;
        bufferBase = -1;
        bufferDirty = false;
        memset(&header, 0, sizeof(header));
    }

    MappedFileReader() = default;
    ~MappedFileReader() { closeMap(); }

    MappedFileReader(const MappedFileReader&) = delete;
    MappedFileReader& operator=(const MappedFileReader&) = delete;

    MappedFileReader(MappedFileReader&& other) noexcept
        : filename(std::move(other.filename)), mappedData(other.mappedData),
          mappedCount(other.mappedCount), header(other.header),
          bufferBase(other.bufferBase), bufferDirty(other.bufferDirty)
#ifdef _WIN32
          , hFile(other.hFile), hMap(other.hMap)
#else
          , fd(other.fd), mapLen(other.mapLen)
#endif
    {
        std::memcpy(buffer, other.buffer, sizeof(buffer));
        other.mappedData = nullptr; other.mappedCount = 0;
        other.bufferBase = -1; other.bufferDirty = false;
        memset(&other.header, 0, sizeof(other.header));
#ifdef _WIN32
        other.hFile = INVALID_HANDLE_VALUE; other.hMap = NULL;
#else
        other.fd = -1; other.mapLen = 0;
#endif
    }

    MappedFileReader& operator=(MappedFileReader&& other) noexcept {
        if (this != &other) {
            closeMap();
            filename = std::move(other.filename); mappedData = other.mappedData;
            mappedCount = other.mappedCount; header = other.header;
            bufferBase = other.bufferBase; bufferDirty = other.bufferDirty;
            std::memcpy(buffer, other.buffer, sizeof(buffer));
#ifdef _WIN32
            hFile = other.hFile; hMap = other.hMap;
#else
            fd = other.fd; mapLen = other.mapLen;
#endif
            other.mappedData = nullptr; other.mappedCount = 0;
            other.bufferBase = -1; other.bufferDirty = false;
            memset(&other.header, 0, sizeof(other.header));
#ifdef _WIN32
            other.hFile = INVALID_HANDLE_VALUE; other.hMap = NULL;
#else
            other.fd = -1; other.mapLen = 0;
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

        memcpy(&header, ptr, sizeof(ShardHeader));
        mappedData = (uint64_t*)(static_cast<char*>(ptr) + sizeof(ShardHeader));
        mappedCount = (sz.QuadPart - sizeof(ShardHeader)) / sizeof(uint64_t);
#else
        fd = ::open(path, O_RDWR);
        if (fd < 0) return false;

        struct stat st;
        if (fstat(fd, &st) != 0) { closeMap(); return false; }
        if (st.st_size < (off_t)sizeof(ShardHeader)) { closeMap(); return false; }

        mapLen = static_cast<size_t>(st.st_size);
        
        #ifdef __linux__
        void* ptr = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, 0);
        #else
        void* ptr = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        #endif
        
        if (ptr == MAP_FAILED) { closeMap(); return false; }

        memcpy(&header, ptr, sizeof(ShardHeader));
        if (header.noteCount < 0 || header.capacity <= 0 || header.noteCount > header.capacity) {
            munmap(ptr, mapLen); closeMap(); return false;
        }
        
        mappedData = (uint64_t*)(static_cast<char*>(ptr) + sizeof(ShardHeader));
        mappedCount = (st.st_size - sizeof(ShardHeader)) / sizeof(uint64_t);
#endif
        return true;
    }

    uint64_t get(int64_t index) const {
        if (index < 0 || index >= header.noteCount || index >= mappedCount) return 0;
        int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base != bufferBase) loadBufferFromDisk(base);
        return buffer[index - base];
    }

    void set(int64_t index, uint64_t value) {
        if (index < 0 || index >= mappedCount) return;
        int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base != bufferBase) loadBufferFromDisk(base);
        buffer[index - base] = value;
        bufferDirty = true;
    }

    void getRange(int64_t index, int64_t count, uint64_t* out) const {
        if (index < 0 || count <= 0 || index >= mappedCount) return;
        count = std::min<int64_t>(count, mappedCount - index);
        int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base == bufferBase && (index + count) <= (bufferBase + BUFFER_ELEMENTS)) {
            std::memcpy(out, buffer + (index - base), count * sizeof(uint64_t));
        } else {
            flushBufferToDisk();
            std::memcpy(out, mappedData + index, count * sizeof(uint64_t));
        }
    }

    void setRange(int64_t index, int64_t count, const uint64_t* in) {
        if (index < 0 || count <= 0 || index >= mappedCount) return;
        count = std::min<int64_t>(count, mappedCount - index);
        int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base == bufferBase && (index + count) <= (bufferBase + BUFFER_ELEMENTS)) {
            std::memcpy(buffer + (index - base), in, count * sizeof(uint64_t));
            bufferDirty = true;
        } else {
            flushBufferToDisk();
            std::memcpy(mappedData + index, in, count * sizeof(uint64_t));
            bufferBase = -1; 
        }
    }

    void shiftLeft(int64_t from, int64_t count) {
        if (from < 0 || count <= 0 || from + count >= mappedCount) return;
        int64_t base = (from / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base == bufferBase && (from + count) < (bufferBase + BUFFER_ELEMENTS)) {
            std::memmove(buffer + from - base, buffer + from + 1 - base, count * sizeof(uint64_t));
            bufferDirty = true;
            return;
        }
        flushBufferToDisk();
        bufferBase = -1;
        std::memmove(mappedData + from, mappedData + from + 1, count * sizeof(uint64_t));
    }

    void shiftRight(int64_t from, int64_t count) {
        if (from < 0 || count <= 0 || from + count >= mappedCount) return;
        int64_t base = (from / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base == bufferBase && (from + count) < (bufferBase + BUFFER_ELEMENTS)) {
            std::memmove(buffer + from + 1 - base, buffer + from - base, count * sizeof(uint64_t));
            bufferDirty = true;
            return;
        }
        flushBufferToDisk();
        bufferBase = -1;
        std::memmove(mappedData + from + 1, mappedData + from, count * sizeof(uint64_t));
    }

    int64_t size() const { return mappedCount; }
    int64_t getNoteCount() const { return header.noteCount; }
    int64_t getCapacity() const { return header.capacity; }
    
    void flushHeader() {
        if (!mappedData) return;
        flushBufferToDisk();
        void* headerPtr = static_cast<char*>(static_cast<void*>(mappedData)) - sizeof(ShardHeader);
        memcpy(headerPtr, &header, sizeof(ShardHeader));
#ifdef _WIN32
        FlushViewOfFile(headerPtr, sizeof(ShardHeader));
#else
        msync(headerPtr, sizeof(ShardHeader), MS_ASYNC); 
#endif
    }

    void setNoteCount(int64_t count) { header.noteCount = count; }
    void setCapacity(int64_t cap) { header.capacity = cap; }

    void prefaultRange(int64_t startIndex, int64_t count) {
        if (!mappedData || startIndex < 0 || count <= 0) return;
        count = std::min<int64_t>(count, mappedCount - startIndex);
        void* addr = static_cast<char*>(static_cast<void*>(mappedData + startIndex));
        size_t byteCount = count * sizeof(uint64_t);
#ifdef __linux__
        madvise(addr, byteCount, MADV_WILLNEED);
#else
        volatile uint8_t* p = reinterpret_cast<volatile uint8_t*>(mappedData + startIndex);
        for (size_t i = 0; i < byteCount; i += 4096) (void)p[i];
        if (byteCount > 0) (void)p[byteCount - 1];
#endif
    }
};

class ShardedChartReader {
private:
    struct ShardInfo {
        std::mutex mtx; // PER-SHARD LOCK! Prevents global stalls during sorting.
        MappedFileReader reader;
        int64_t noteCount = 0, capacity = 0, startIndex = 0, endIndex = 0;
        uint64_t shardId = 0;
        int64_t prefaultedUpTo = 0;
        uint64_t lastAccessMs = 0;
        bool isPinned = false;
        std::vector<uint64_t> overflowNotes;

        ShardInfo() = default;
        ShardInfo(ShardInfo&& other) noexcept
            : reader(std::move(other.reader)), noteCount(other.noteCount), capacity(other.capacity),
              startIndex(other.startIndex), endIndex(other.endIndex), shardId(other.shardId),
              prefaultedUpTo(other.prefaultedUpTo), lastAccessMs(other.lastAccessMs), isPinned(other.isPinned),
              overflowNotes(std::move(other.overflowNotes)) {}
        
        ShardInfo& operator=(ShardInfo&& other) noexcept {
            if (this != &other) {
                reader = std::move(other.reader);
                noteCount = other.noteCount; capacity = other.capacity;
                startIndex = other.startIndex; endIndex = other.endIndex;
                shardId = other.shardId; prefaultedUpTo = other.prefaultedUpTo;
                lastAccessMs = other.lastAccessMs; isPinned = other.isPinned;
                overflowNotes = std::move(other.overflowNotes);
            }
            return *this;
        }
    };

    std::string chartDir;
    mutable std::mutex shardsMutex;
    // Changed to unique_ptr so memory addresses of ShardInfo remain stable!
    std::unordered_map<uint64_t, std::unique_ptr<ShardInfo>> activeShards;
    
    std::vector<uint64_t> availableShards;
    std::vector<int64_t> shardStartIndices;
    std::vector<ShardMetaEntry> shardMeta;
    uint64_t currentShardId = 0;
    int64_t totalNotes = 0;

    static constexpr int POOL_SIZE = 20;
    static constexpr int64_t DEFAULT_SHARD_CAPACITY = 32;
    static constexpr int64_t PREFAULT_CHUNK_SIZE = 8192;
    int64_t correctionTime = 0;

    bool editorMode = false;

    bool isApplyingNotes = false;
    std::chrono::steady_clock::time_point lastInsertTime;
    int insertsInLast10ms = 0;
    bool pendingSortAfterApply = false;
    std::chrono::steady_clock::time_point applyEndTime;
    std::unordered_set<uint64_t> dirtyShards;

    std::mutex pendingMutex;
    std::unordered_set<uint64_t> pendingLoads;
    
    std::thread workerThread;
    std::queue<uint64_t> loadQueue;
    std::mutex queueMutex;
    std::condition_variable queueCV;
    std::unordered_map<uint64_t, ShardInfo*> completedLoads;
    bool canStopWorker = false;

    std::thread maintenanceThread;
    std::mutex maintenanceMutex;
    std::condition_variable maintenanceCV;
    bool stopMaintenance = false;

    void startWorker() {
        workerThread = std::thread([this] {
            while (true) {
                uint64_t shardId;
                {
                    std::unique_lock<std::mutex> lk(queueMutex);
                    queueCV.wait(lk, [this] { return canStopWorker || !loadQueue.empty(); });
                    if (canStopWorker && loadQueue.empty()) return;
                    shardId = loadQueue.front();
                    loadQueue.pop();
                }

                ShardInfo* info = new ShardInfo();
                info->shardId = shardId;
                info->startIndex = getShardStartIndex(shardId);
                size_t idx = findShardArrayIndex(shardId);
                if (idx < shardMeta.size()) info->capacity = shardMeta[idx].capacity;

                std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
                if (!info->reader.open(path.c_str())) {
                    delete info; info = nullptr;
                } else {
                    info->noteCount = info->reader.getNoteCount();
                    info->endIndex = info->startIndex + info->noteCount;
                    info->prefaultedUpTo = 0;
                    auto now = std::chrono::steady_clock::now().time_since_epoch();
                    info->lastAccessMs = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
                }

                {
                    std::lock_guard<std::mutex> lk(pendingMutex);
                    completedLoads[shardId] = info;
                    pendingLoads.erase(shardId);
                }
            }
        });
    }

    void stopWorker() {
        {
            std::lock_guard<std::mutex> lk(queueMutex);
            canStopWorker = true;
        }
        queueCV.notify_one();
        if (workerThread.joinable()) workerThread.join();
        std::lock_guard<std::mutex> lk(pendingMutex);
        for (auto& pair : completedLoads) delete pair.second;
        completedLoads.clear();
    }

    void startMaintenance() {
        maintenanceThread = std::thread([this] {
            while (true) {
                {
                    std::unique_lock<std::mutex> lk(maintenanceMutex);
                    if (maintenanceCV.wait_for(lk, std::chrono::milliseconds(10), [this] { return stopMaintenance; })) break;
                }
                
                auto now = std::chrono::steady_clock::now();
                std::vector<ShardInfo*> shardsToSort;

                bool shouldSort = false;
                if (pendingSortAfterApply) {
                    if (std::chrono::duration_cast<std::chrono::milliseconds>(now - applyEndTime).count() >= 10) {
                        shouldSort = true;
                        pendingSortAfterApply = false;
                    }
                } else if (!editorMode) {
                    if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastInsertTime).count() >= 10) {
                        shouldSort = true;
                    }
                }

                if (shouldSort) {
                    {
                        std::lock_guard<std::mutex> lk(shardsMutex);
                        for (uint64_t sid : dirtyShards) {
                            auto it = activeShards.find(sid);
                            if (it != activeShards.end()) shardsToSort.push_back(it->second.get());
                        }
                        dirtyShards.clear();
                    }

                    // LOCK-FREE SORTING STRATEGY
                    for (ShardInfo* s : shardsToSort) {
                        std::vector<uint64_t> notes;
                        {
                            std::lock_guard<std::mutex> slk(s->mtx);
                            if (s->noteCount <= 1) continue;
                            if (!s->overflowNotes.empty()) flushOverflowInternal(s);
                            notes.resize(s->noteCount);
                            s->reader.getRange(0, s->noteCount, notes.data());
                        } // UNLOCKED! Main thread can access this shard now.

                        radixSortShardInPlace(notes); // Heavy sort happens with ZERO locks!

                        {
                            std::lock_guard<std::mutex> slk(s->mtx);
                            s->reader.setRange(0, s->noteCount, notes.data());
                        }
                    }
                }

                if (editorMode) {
                    uint64_t nowMs = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
                    std::lock_guard<std::mutex> lk(shardsMutex);
                    for (auto& pair : activeShards) {
                        ShardInfo& info = *pair.second;
                        if (info.isPinned && nowMs - info.lastAccessMs >= 500) {
                            std::lock_guard<std::mutex> slk(info.mtx);
                            info.reader.flushHeader();
                            info.isPinned = false;
                        }
                    }
                }
            }
        });
    }

    void stopMaintenanceThread() {
        {
            std::lock_guard<std::mutex> lk(maintenanceMutex);
            stopMaintenance = true;
        }
        maintenanceCV.notify_one();
        if (maintenanceThread.joinable()) maintenanceThread.join();
    }

    struct AccessCache {
        uint64_t shardId = UINT64_MAX;
        ShardInfo* info = nullptr;
        int64_t localIndex = -1, globalIndex = -1;
    };
    AccessCache readCache, judgeCache;

    static inline uint32_t getLocalPos(uint64_t note) { return static_cast<uint32_t>(note & 0x7FFFFFFF); }

    size_t findShardArrayIndex(uint64_t shardId) const {
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it != availableShards.end() && *it == shardId) return static_cast<size_t>(std::distance(availableShards.begin(), it));
        return availableShards.size();
    }

    int64_t getShardStartIndex(uint64_t shardId) const {
        size_t idx = findShardArrayIndex(shardId);
        if (idx >= shardStartIndices.size()) throw std::runtime_error("Shard not found: " + std::to_string(shardId));
        return shardStartIndices[idx];
    }

    bool loadMetadataFromFile() {
        std::string metaPath = chartDir + "/shardMeta.bin";
        std::ifstream metaFile(metaPath, std::ios::binary);
        if (!metaFile) return false;
        uint64_t entryCount;
        metaFile.read(reinterpret_cast<char*>(&entryCount), sizeof(entryCount));
        if (!metaFile) return false;
        std::vector<ShardMetaEntry> entries(entryCount);
        metaFile.read(reinterpret_cast<char*>(entries.data()), entryCount * sizeof(ShardMetaEntry));
        if (!metaFile) return false;
        metaFile.close();

        availableShards.clear(); shardStartIndices.clear(); shardMeta.clear();
        availableShards.reserve(entryCount); shardStartIndices.reserve(entryCount); shardMeta.reserve(entryCount);
        int64_t cumulative = 0;
        for (size_t i = 0; i < entryCount; i++) {
            availableShards.push_back(entries[i].shardId);
            shardStartIndices.push_back(cumulative);
            shardMeta.push_back(entries[i]);
            cumulative += entries[i].noteCount;
        }
        totalNotes = cumulative;
        return true;
    }

    void scanShardsFallback() {
        std::vector<std::string> files;
        listFiles(chartDir, files);
        struct TempInfo { uint64_t shardId; int64_t noteCount, capacity; };
        std::vector<TempInfo> tempInfos; tempInfos.reserve(files.size());
        for (const auto& name : files) {
            if (getExtension(name) != ".bin" || name == "shardMeta.bin") continue;
            std::string stem = getStem(name);
            uint64_t shardId; try { shardId = std::stoull(stem); } catch (...) { continue; }
            ShardHeader hdr = readHeaderOnly(shardId);
            tempInfos.push_back({shardId, hdr.noteCount, hdr.capacity});
        }
        std::sort(tempInfos.begin(), tempInfos.end(), [](const TempInfo& a, const TempInfo& b) { return a.shardId < b.shardId; });
        availableShards.clear(); shardStartIndices.clear(); shardMeta.clear();
        int64_t cumulative = 0;
        for (const auto& info : tempInfos) {
            availableShards.push_back(info.shardId);
            shardStartIndices.push_back(cumulative);
            cumulative += info.noteCount;
            ShardMetaEntry entry; entry.shardId = info.shardId; entry.noteCount = info.noteCount; entry.capacity = info.capacity;
            memset(entry.reserved, 0, sizeof(entry.reserved));
            shardMeta.push_back(entry);
        }
        totalNotes = cumulative;
    }

    ShardHeader readHeaderOnly(uint64_t shardId) const {
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        std::ifstream file(path, std::ios::binary);
        if (!file) throw std::runtime_error("Cannot open shard: " + path);
        ShardHeader header;
        file.read(reinterpret_cast<char*>(&header), sizeof(ShardHeader));
        return header;
    }

    void scanShards() {
        if (loadMetadataFromFile()) return;
        std::cout << "[ShardedChartReader] shardMeta.bin not found, scanning shard files...\n";
        scanShardsFallback();
        writeMetadataFile();
    }

    void writeMetadataFile() {
        std::string metaPath = chartDir + "/shardMeta.bin";
        std::ofstream metaOut(metaPath, std::ios::binary);
        if (!metaOut) return;
        uint64_t entryCount = availableShards.size();
        metaOut.write(reinterpret_cast<const char*>(&entryCount), sizeof(entryCount));
        for (size_t i = 0; i < shardMeta.size(); i++) metaOut.write(reinterpret_cast<const char*>(&shardMeta[i]), sizeof(ShardMetaEntry));
    }

    void loadShard(uint64_t shardId) {
        if (activeShards.find(shardId) != activeShards.end()) return;
        {
            std::lock_guard<std::mutex> lk(pendingMutex);
            auto it = completedLoads.find(shardId);
            if (it != completedLoads.end()) {
                ShardInfo* info = it->second;
                if (info) {
                    std::lock_guard<std::mutex> slk(shardsMutex);
                    activeShards.emplace(shardId, std::unique_ptr<ShardInfo>(info));
                } else {
                    delete info;
                }
                completedLoads.erase(it); pendingLoads.erase(shardId);
                return;
            }
            pendingLoads.erase(shardId);
        }
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        auto info = std::make_unique<ShardInfo>();
        info->shardId = shardId;
        info->startIndex = getShardStartIndex(shardId);
        size_t idx = findShardArrayIndex(shardId);
        if (idx < shardMeta.size()) info->capacity = shardMeta[idx].capacity;
        if (!info->reader.open(path.c_str())) throw std::runtime_error("Failed to open shard: " + std::to_string(shardId));
        info->noteCount = info->reader.getNoteCount();
        info->endIndex = info->startIndex + info->noteCount;
        info->prefaultedUpTo = 0;
        auto now = std::chrono::steady_clock::now().time_since_epoch();
        info->lastAccessMs = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
        std::lock_guard<std::mutex> slk(shardsMutex);
        activeShards.emplace(shardId, std::move(info));
    }

    void prefetchShards(uint64_t currentShardId) {
        size_t idx = findShardArrayIndex(currentShardId);
        if (idx >= availableShards.size()) return;
        for (int i = 1; i <= 5; i++) {
            size_t nextIdx = idx + i;
            if (nextIdx < availableShards.size()) asyncLoadShard(availableShards[nextIdx]);
        }
    }

    void drainPending() {
        std::lock_guard<std::mutex> lk(pendingMutex);
        if (completedLoads.empty()) return;
        std::lock_guard<std::mutex> slk(shardsMutex);
        for (auto it = completedLoads.begin(); it != completedLoads.end(); ) {
            ShardInfo* info = it->second;
            if (info && activeShards.find(it->first) == activeShards.end()) {
                activeShards.emplace(it->first, std::unique_ptr<ShardInfo>(info));
            } else { delete info; }
            it = completedLoads.erase(it);
        }
    }

    void rebuildShardStartIndices() {
        shardStartIndices.clear();
        int64_t cumulative = 0;
        std::lock_guard<std::mutex> lk(shardsMutex);
        for (size_t i = 0; i < availableShards.size(); i++) {
            shardStartIndices.push_back(cumulative);
            auto activeIt = activeShards.find(availableShards[i]);
            cumulative += (activeIt != activeShards.end()) ? activeIt->second->noteCount : shardMeta[i].noteCount;
        }
        totalNotes = cumulative;
        for (auto& pair : activeShards) {
            size_t idx = findShardArrayIndex(pair.first);
            if (idx < shardStartIndices.size()) {
                pair.second->startIndex = shardStartIndices[idx];
                pair.second->endIndex = pair.second->startIndex + pair.second->noteCount;
            }
        }
    }

    inline void touchShard(ShardInfo* info) {
        if (editorMode) {
            info->isPinned = true;
            auto now = std::chrono::steady_clock::now().time_since_epoch();
            info->lastAccessMs = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
        }
    }

    ShardInfo* getShardInfoFast(int64_t globalIndex, AccessCache& cache) {
        if (cache.info && globalIndex >= cache.info->startIndex && globalIndex < cache.info->endIndex) {
            touchShard(cache.info); return cache.info;
        }
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && cachedShardInfo) {
            touchShard(cachedShardInfo); cache.info = cachedShardInfo; cache.shardId = cachedShardId; return cachedShardInfo;
        }
        drainPending();
        if (globalIndex < 0 || globalIndex >= totalNotes) return nullptr;
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1);
        uint64_t shardId = availableShards[shardPos];
        if (shardId != currentShardId && (shardId / 10 != currentShardId / 10)) {
            currentShardId = shardId; managePool(currentShardId);
        }
        ShardInfo* result = nullptr;
        {
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) { touchShard(mapIt->second.get()); result = mapIt->second.get(); }
        }
        if (!result) { asyncLoadShard(shardId); prefetchShards(shardId); return nullptr; }
        
        {
            std::lock_guard<std::mutex> slk(result->mtx);
            int64_t localIndex = globalIndex - result->startIndex;
            if (localIndex >= result->prefaultedUpTo) {
                int64_t prefaultStart = result->prefaultedUpTo;
                int64_t prefaultCount = std::min<int64_t>(PREFAULT_CHUNK_SIZE * 4, result->noteCount - prefaultStart);
                if (prefaultCount > 0) {
                    result->reader.prefaultRange(prefaultStart, prefaultCount);
                    result->prefaultedUpTo = prefaultStart + prefaultCount;
                }
            }
        }

        cachedShardId = shardId; cachedShardStart = shardStartIndices[shardPos];
        cachedShardEnd = result->endIndex; cachedShardInfo = result;
        cache.shardId = shardId; cache.info = cachedShardInfo;
        return cachedShardInfo;
    }

    void asyncLoadShard(uint64_t shardId) {
        if (activeShards.find(shardId) != activeShards.end()) return;
        {
            std::lock_guard<std::mutex> lk(pendingMutex);
            if (completedLoads.find(shardId) != completedLoads.end()) return;
            if (pendingLoads.find(shardId) != pendingLoads.end()) return;
            pendingLoads.insert(shardId);
        }
        std::lock_guard<std::mutex> lk(queueMutex);
        loadQueue.push(shardId); queueCV.notify_one();
    }

    void unloadShard(uint64_t shardId) {
        std::lock_guard<std::mutex> lk(shardsMutex);
        auto it = activeShards.find(shardId);
        if (it != activeShards.end()) {
            std::lock_guard<std::mutex> slk(it->second->mtx);
            it->second->reader.flushHeader();
            activeShards.erase(it);
            if (shardId == cachedShardId) { cachedShardInfo = nullptr; cachedShardStart = -1; cachedShardEnd = -1; }
        }
    }

    void managePool(uint64_t currentShard) {
        drainPending();
        std::vector<uint64_t> toRemove;
        {
            std::lock_guard<std::mutex> lk(shardsMutex);
            for (auto& pair : activeShards) {
                if (editorMode && pair.second->isPinned) continue;
                int64_t first = static_cast<int64_t>(pair.first);
                int64_t dist = (first > static_cast<int64_t>(currentShard)) ? (first - static_cast<int64_t>(currentShard)) : (static_cast<int64_t>(currentShard) - first);
                if (dist > POOL_SIZE) toRemove.push_back(pair.first);
            }
        }
        for (size_t i = 0; i < toRemove.size(); i++) unloadShard(toRemove[i]);
    }

    void createShardFile(uint64_t shardId, int64_t initialCapacity = DEFAULT_SHARD_CAPACITY) {
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        ShardHeader header; header.noteCount = 0; header.capacity = initialCapacity;
        memset(header.reserved, 0, sizeof(header.reserved));
        std::vector<uint64_t> zeros(static_cast<size_t>(initialCapacity), 0);
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        if (!file) throw std::runtime_error("Failed to create shard: " + path);
        file.write(reinterpret_cast<const char*>(&header), sizeof(ShardHeader));
        file.write(reinterpret_cast<const char*>(zeros.data()), static_cast<size_t>(initialCapacity) * sizeof(uint64_t));
        size_t insertPos = findShardArrayIndex(shardId);
        if (insertPos == availableShards.size() || availableShards[insertPos] != shardId) {
            ShardMetaEntry entry; entry.shardId = shardId; entry.noteCount = 0; entry.capacity = initialCapacity;
            memset(entry.reserved, 0, sizeof(entry.reserved));
            availableShards.insert(availableShards.begin() + insertPos, shardId);
            shardMeta.insert(shardMeta.begin() + insertPos, entry);
            rebuildShardStartIndices();
        }
    }

    void remapShardInternal(ShardInfo* s, int64_t newCapacity) {
        int64_t oldDiskNoteCount = s->reader.getNoteCount(); 
        s->reader.closeMap();
        std::string path = chartDir + "/" + std::to_string(s->shardId) + ".bin";
        int64_t newFileSize = sizeof(ShardHeader) + newCapacity * sizeof(uint64_t);
#ifdef _WIN32
        HANDLE hFile = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return;
        LARGE_INTEGER li; li.QuadPart = newFileSize; SetFilePointerEx(hFile, li, nullptr, FILE_BEGIN);
        if (!SetEndOfFile(hFile)) { CloseHandle(hFile); return; }
        CloseHandle(hFile);
#else
        if (truncate(path.c_str(), newFileSize) != 0) return;
#endif
        if (!s->reader.open(path.c_str())) return;
        s->reader.setNoteCount(oldDiskNoteCount);
        s->reader.setCapacity(newCapacity);
        s->capacity = newCapacity;
        size_t idx = findShardArrayIndex(s->shardId);
        if (idx < shardMeta.size()) shardMeta[idx].capacity = newCapacity;
    }

    void flushOverflowInternal(ShardInfo* s) {
        if (s->overflowNotes.empty()) return;
        int64_t diskCount = s->reader.getNoteCount();
        int64_t currentCap = s->reader.size();
        int64_t neededCap = diskCount + s->overflowNotes.size();
        if (neededCap > currentCap) {
            int64_t newCap = std::max<int64_t>(neededCap, currentCap * 2);
            remapShardInternal(s, newCap);
        }
        if (!s->overflowNotes.empty()) {
            s->reader.setRange(diskCount, s->overflowNotes.size(), s->overflowNotes.data());
            s->overflowNotes.clear();
        }
        s->reader.setNoteCount(s->noteCount);
    }

    void radixSortShardInPlace(std::vector<uint64_t>& notes) {
        if (notes.size() <= 1) return;
        uint32_t maxPos = 0;
        for (size_t i = 0; i < notes.size(); i++) { uint32_t p = getLocalPos(notes[i]); if (p > maxPos) maxPos = p; }
        if (maxPos == 0) return;
        int maxBits = 0; while (maxPos > 0) { maxBits++; maxPos >>= 1; }
        int passes = (maxBits + 7) / 8;
        static thread_local std::vector<uint64_t> buffer;
        buffer.resize(notes.size());
        for (int shift = 0; shift < passes * 8; shift += 8) {
            int counts[256] = {0};
            for (size_t i = 0; i < notes.size(); i++) counts[(getLocalPos(notes[i]) >> shift) & 0xFF]++;
            for (int i = 1; i < 256; i++) counts[i] += counts[i - 1];
            for (int i = static_cast<int>(notes.size()) - 1; i >= 0; i--)
                buffer[--counts[(getLocalPos(notes[i]) >> shift) & 0xFF]] = notes[i];
            notes.swap(buffer);
        }
    }

public:
    std::vector<uint8_t> globalJudgement;
    bool globalJudgementInitialized = false;

    void initGlobalJudgement() {
        if (globalJudgementInitialized) return;
        size_t initialSize = static_cast<size_t>((totalNotes + 7) >> 3);
        globalJudgement.reserve(std::max<size_t>(initialSize * 2, static_cast<size_t>(1024))); 
        globalJudgement.assign(initialSize, 0);
        globalJudgementInitialized = true;
    }

    ShardedChartReader(const char* path) : chartDir(path) {
        scanShards(); initGlobalJudgement();
        startWorker(); startMaintenance();
    }

    ~ShardedChartReader() {
        setEditorMode(false); writeMetadataFile();
        stopMaintenanceThread(); stopWorker();
        std::lock_guard<std::mutex> lk(shardsMutex);
        for (auto& pair : activeShards) {
            std::lock_guard<std::mutex> slk(pair.second->mtx);
            pair.second->reader.flushHeader();
        }
        activeShards.clear();
    }

    void setEditorMode(bool enabled) {
        editorMode = enabled;
        if (!enabled) {
            std::lock_guard<std::mutex> lk(shardsMutex);
            for (auto& pair : activeShards) {
                std::lock_guard<std::mutex> slk(pair.second->mtx);
                if (pair.second->isPinned) { pair.second->reader.flushHeader(); pair.second->isPinned = false; }
            }
        }
    }

    void setApplyingNotes(bool enabled) {
        isApplyingNotes = enabled;
        if (!enabled) {
            pendingSortAfterApply = true;
            applyEndTime = std::chrono::steady_clock::now();
        }
    }

    int64_t cachedShardStart = -1, cachedShardEnd = -1;
    uint64_t cachedShardId = 0;
    ShardInfo* cachedShardInfo = nullptr;

    uint64_t findShardForGlobalIndex(int64_t globalIndex) {
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd) return cachedShardId;
        if (globalIndex < 0 || globalIndex >= totalNotes) return UINT64_MAX;
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        return availableShards[static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1)];
    }

    ShardInfo* getShardInfo(int64_t globalIndex) {
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && cachedShardInfo) return cachedShardInfo;
        drainPending();
        if (globalIndex < 0 || globalIndex >= totalNotes) return nullptr;
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1);
        uint64_t shardId = availableShards[shardPos];
        if (shardId != currentShardId) { currentShardId = shardId; managePool(currentShardId); }
        ShardInfo* result = nullptr;
        {
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) { touchShard(mapIt->second.get()); result = mapIt->second.get(); }
        }
        if (!result) { 
            loadShard(shardId); 
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) { touchShard(mapIt->second.get()); result = mapIt->second.get(); }
        }
        if (result) {
            cachedShardId = shardId; cachedShardStart = shardStartIndices[shardPos];
            cachedShardEnd = (shardPos + 1 < shardStartIndices.size()) ? shardStartIndices[shardPos + 1] : totalNotes;
            cachedShardInfo = result;
        }
        return cachedShardInfo;
    }

    uint64_t getNote(int64_t globalIndex) {
        if (globalIndex < 0 || globalIndex >= totalNotes) return 0;
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        if (!info) return 0; 
        
        std::lock_guard<std::mutex> slk(info->mtx);
        int64_t localIndex = globalIndex - info->startIndex;
        if (localIndex < 0 || localIndex >= info->noteCount) return 0;
        
        int64_t diskCount = info->reader.getNoteCount();
        if (localIndex < diskCount) {
            return info->reader.get(localIndex);
        } else {
            return info->overflowNotes[localIndex - diskCount];
        }
    }

    void setNote(int64_t globalIndex, uint64_t value) {
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        if (!info) return; 
        touchShard(info);
        
        std::lock_guard<std::mutex> slk(info->mtx);
        int64_t localIndex = globalIndex - info->startIndex;
        if (localIndex < 0 || localIndex >= info->noteCount) return;
        
        int64_t diskCount = info->reader.getNoteCount();
        if (localIndex < diskCount) {
            info->reader.set(localIndex, value);
        } else {
            info->overflowNotes[localIndex - diskCount] = value;
        }
    }

    bool core_getJudgement(int64_t globalIndex) {
        if (!globalJudgementInitialized) initGlobalJudgement();
        if (globalIndex < 0 || globalIndex >= totalNotes) return false;
        int64_t byteIndex = globalIndex >> 3; int bitIndex = globalIndex & 7;
        if (byteIndex >= static_cast<int64_t>(globalJudgement.size())) return false;
        return (globalJudgement[static_cast<size_t>(byteIndex)] >> bitIndex) & 1;
    }

    void core_setJudgement(int64_t globalIndex, bool value) {
        if (globalIndex < 0) return;
        int64_t byteIndex = globalIndex >> 3; 
        if (byteIndex >= static_cast<int64_t>(globalJudgement.size())) {
            size_t needed = static_cast<size_t>(byteIndex + 1);
            if (needed > globalJudgement.capacity()) globalJudgement.reserve(std::max<size_t>(needed, globalJudgement.capacity() * 2));
            globalJudgement.resize(needed, 0);
            globalJudgementInitialized = true;
        }
        int bitIndex = globalIndex & 7;
        if (value) globalJudgement[static_cast<size_t>(byteIndex)] |=  (1 << bitIndex);
        else       globalJudgement[static_cast<size_t>(byteIndex)] &= ~(1 << bitIndex);
    }

    void insertNote(int64_t globalPosition, int duration, int index, int type) {
        int64_t shardId  = globalPosition / 2000000000;
        int64_t localPos = globalPosition % 2000000000;
        uint64_t packedNote = ((uint64_t)(localPos & 0x7FFFFFFF) << 0)  | ((uint64_t)(duration & 0x1FFFF) << 31) | ((uint64_t)(index & 0xFF) << 48) | ((uint64_t)(type & 0x7F) << 56);
        
        cachedShardInfo = nullptr; cachedShardStart = -1; cachedShardEnd = -1;
        readCache.info = nullptr; judgeCache.info = nullptr;

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - lastInsertTime).count() > 10) {
            insertsInLast10ms = 0;
        }
        lastInsertTime = now;
        insertsInLast10ms++;

        ShardInfo* s_ptr = nullptr;
        {
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) s_ptr = mapIt->second.get();
        }

        if (!s_ptr) {
            std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
            if (getFileSize(path) < 0) createShardFile(shardId, DEFAULT_SHARD_CAPACITY);
            loadShard(shardId); 
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) s_ptr = mapIt->second.get();
        }
        if (!s_ptr) return;

        size_t shardPos = 0;
        {
            std::lock_guard<std::mutex> slk(s_ptr->mtx);
            touchShard(s_ptr); 
            
            int64_t currentCap = s_ptr->reader.size();
            if (editorMode && s_ptr->noteCount + 1 > currentCap) {
                s_ptr->overflowNotes.push_back(packedNote);
            } else {
                if (!s_ptr->overflowNotes.empty()) {
                    flushOverflowInternal(s_ptr);
                }
                if (s_ptr->noteCount + 1 > s_ptr->reader.size()) {
                    int64_t newCap = std::max<int64_t>(s_ptr->reader.size() * 2, s_ptr->reader.size() + 4096);
                    remapShardInternal(s_ptr, newCap);
                }
                s_ptr->reader.set(s_ptr->noteCount, packedNote);
            }
            
            s_ptr->noteCount++;
            s_ptr->endIndex++;
            totalNotes++;

            shardPos = findShardArrayIndex(shardId);
            if (shardPos < shardMeta.size()) {
                shardMeta[shardPos].noteCount = s_ptr->noteCount;
            }
            
            for (size_t i = shardPos + 1; i < shardStartIndices.size(); i++) {
                shardStartIndices[i]++;
            }
            
            dirtyShards.insert(shardId);
        }

        if (!editorMode) {
            if (insertsInLast10ms <= 256) {
                std::vector<ShardInfo*> toSort;
                {
                    std::lock_guard<std::mutex> lk(shardsMutex);
                    for (uint64_t sid : dirtyShards) {
                        auto it = activeShards.find(sid);
                        if (it != activeShards.end()) toSort.push_back(it->second.get());
                    }
                    dirtyShards.clear();
                }
                for (ShardInfo* s : toSort) {
                    std::vector<uint64_t> notes;
                    {
                        std::lock_guard<std::mutex> lk2(s->mtx);
                        if (s->noteCount <= 1) continue;
                        if (!s->overflowNotes.empty()) flushOverflowInternal(s);
                        notes.resize(s->noteCount);
                        s->reader.getRange(0, s->noteCount, notes.data());
                    }
                    radixSortShardInPlace(notes);
                    {
                        std::lock_guard<std::mutex> lk2(s->mtx);
                        s->reader.setRange(0, s->noteCount, notes.data());
                    }
                }
            }
        }
    }

    void removeNote(int64_t globalIndex) {
        if (globalIndex < 0 || globalIndex >= totalNotes) return;
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1);
        uint64_t shardId = availableShards[shardPos];
        
        ShardInfo* s_ptr = nullptr;
        {
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) s_ptr = mapIt->second.get();
        }
        if (!s_ptr) { 
            loadShard(shardId); 
            std::lock_guard<std::mutex> lk(shardsMutex);
            auto mapIt = activeShards.find(shardId);
            if (mapIt != activeShards.end()) s_ptr = mapIt->second.get();
        }
        if (!s_ptr) return;

        {
            std::lock_guard<std::mutex> slk(s_ptr->mtx);
            touchShard(s_ptr);

            if (!s_ptr->overflowNotes.empty()) {
                flushOverflowInternal(s_ptr);
            }

            int64_t localIndex = globalIndex - s_ptr->startIndex;
            int64_t remaining = s_ptr->noteCount - localIndex - 1;
            if (remaining > 0) s_ptr->reader.shiftLeft(localIndex, remaining);
            
            s_ptr->noteCount--; 
            s_ptr->reader.setNoteCount(s_ptr->noteCount);
            totalNotes--;

            size_t shardPos_ = findShardArrayIndex(shardId);
            if (shardPos_ < shardMeta.size()) shardMeta[shardPos_].noteCount = s_ptr->noteCount;
            
            for (size_t i = shardPos_ + 1; i < shardStartIndices.size(); i++) {
                shardStartIndices[i]--;
            }
            
            dirtyShards.insert(shardId);
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
                  << "time="   << formatTime(timeMs, true) << " pos="   << positionTicks  << "ticks"
                  << " dur="   << durationMs     << "ms" << " idx="   << (int)index
                  << " type="  << (int)type << " judged="<< (judged ? "Y" : "N")
                  << " missed="<< (missed ? "Y" : "N") << " raw=0x" << std::hex << note << std::dec << std::endl;
    }

    int64_t getLength() const { return totalNotes; }
    size_t getShardCount() const { return availableShards.size(); }

    void printPoolStats() const {
        std::lock_guard<std::mutex> lk(shardsMutex);
        std::cout << "[POOL] Active shards: " << activeShards.size() << " / " << availableShards.size() << std::endl;
        int count = 0;
        for (auto& pair : activeShards) {
            if (count++ >= 10) { std::cout << "  ... and " << (activeShards.size() - 10) << " more" << std::endl; break; }
            std::cout << "  Shard " << pair.first << ": " << pair.second->noteCount << " notes" 
                      << (pair.second->isPinned ? " [PINNED]" : "") << std::endl;
        }
    }
};

static ShardedChartReader* gReader = nullptr;

void core_loadChart(const char* path) {
    if (gReader) { delete gReader; gReader = nullptr; }
    gReader = new ShardedChartReader(path);
}
void core_destroyChart() { ShardedChartReader* old = gReader; gReader = nullptr; delete old; }
void core_setEditorMode(bool enabled) { if (gReader) gReader->setEditorMode(enabled); }
void core_setApplyingNotes(bool enabled) { if (gReader) gReader->setApplyingNotes(enabled); }

uint64_t core_getNote(int64_t index) { if (!gReader) return 0; return gReader->getNote(index); }
void core_setNote(int64_t index, uint64_t value) { if (!gReader) return; gReader->setNote(index, value); }
void core_insertNote(int64_t globalPosition, int duration, int index, int type) { if (!gReader) return; gReader->insertNote(globalPosition, duration, index, type); }
void core_removeNote(int64_t globalIndex) { if (!gReader) return; gReader->removeNote(globalIndex); }
void core_printNoteInfo(int64_t index) { if (!gReader) return; gReader->printNoteInfo(index); }
int64_t core_getLength() { if (!gReader) return 0; return gReader->getLength(); }
size_t core_getShardCount() { if (!gReader) return 0; return gReader->getShardCount(); }
void core_printPoolStats() { if (gReader) gReader->printPoolStats(); }