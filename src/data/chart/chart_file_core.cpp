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

#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#undef NOMINMAX
#else
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <dirent.h>
#endif

// ============================================================================
// Shard Header Structure
// ============================================================================
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

// ============================================================================
// Portable filesystem helpers
// ============================================================================
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

// ============================================================================
// Optimized File Reader
// ============================================================================
class MappedFileReader {
private:
    std::string filename;
    std::vector<uint64_t> data;
    ShardHeader header;
    bool headerModified = false;
    bool isOpen = false;
    int64_t dirtyMin = INT64_MAX, dirtyMax = -1;
    bool dataDirty = false;
    int64_t diskElementCount = 0;
    std::fstream fileHandle;

    void markDirty(int64_t index) {
        if (index < dirtyMin) dirtyMin = index;
        if (index > dirtyMax) dirtyMax = index;
        dataDirty = true;
    }
    void markDirtyRange(int64_t start, int64_t count) {
        if (count <= 0) return;
        if (start < dirtyMin) dirtyMin = start;
        int64_t end = start + count - 1;
        if (end > dirtyMax) dirtyMax = end;
        dataDirty = true;
    }
    void flushHeader() {
        if (!isOpen || !headerModified) return;
        if (!fileHandle.is_open()) {
            fileHandle.open(filename, std::ios::binary | std::ios::in | std::ios::out);
            if (!fileHandle) return;
        }
        fileHandle.seekp(0, std::ios::beg);
        fileHandle.write(reinterpret_cast<const char*>(&header), sizeof(ShardHeader));
        if (fileHandle) headerModified = false;
    }
    void flushFull() {
        if (!isOpen) return;
        if (fileHandle.is_open()) fileHandle.close();
        std::ofstream file(filename, std::ios::binary | std::ios::trunc);
        if (!file) return;
        file.write(reinterpret_cast<const char*>(&header), sizeof(ShardHeader));
        if (!data.empty()) file.write(reinterpret_cast<const char*>(data.data()), data.size() * sizeof(uint64_t));
        if (file) {
            diskElementCount = static_cast<int64_t>(data.size());
            dataDirty = false; headerModified = false;
            dirtyMin = INT64_MAX; dirtyMax = -1;
        }
    }
    void flushPartial() {
        if (!dataDirty || dirtyMin > dirtyMax) return;
        if (!fileHandle.is_open()) {
            fileHandle.open(filename, std::ios::binary | std::ios::in | std::ios::out);
            if (!fileHandle) return;
        }
        int64_t byteOff = sizeof(ShardHeader) + dirtyMin * sizeof(uint64_t);
        int64_t byteCount = (dirtyMax - dirtyMin + 1) * sizeof(uint64_t);
        fileHandle.seekp(byteOff, std::ios::beg);
        fileHandle.write(reinterpret_cast<const char*>(&data[dirtyMin]), byteCount);
        if (fileHandle) {
            dataDirty = false; dirtyMin = INT64_MAX; dirtyMax = -1;
        }
    }

public:
    void closeMap() {
        if (isOpen && (dataDirty || headerModified)) flush();
        if (fileHandle.is_open()) fileHandle.close();
        data.clear(); data.shrink_to_fit();
        memset(&header, 0, sizeof(header));
        isOpen = false; dataDirty = false; headerModified = false;
        dirtyMin = INT64_MAX; dirtyMax = -1; diskElementCount = 0;
    }
    MappedFileReader() = default;
    ~MappedFileReader() { closeMap(); }
    MappedFileReader(const MappedFileReader&) = delete;
    MappedFileReader& operator=(const MappedFileReader&) = delete;
    MappedFileReader(MappedFileReader&& other) noexcept
        : filename(std::move(other.filename)), data(std::move(other.data)), header(other.header),
          headerModified(other.headerModified), isOpen(other.isOpen), dirtyMin(other.dirtyMin),
          dirtyMax(other.dirtyMax), dataDirty(other.dataDirty), diskElementCount(other.diskElementCount),
          fileHandle(std::move(other.fileHandle)) {
        other.isOpen = false; other.dataDirty = false; other.headerModified = false;
        other.dirtyMin = INT64_MAX; other.dirtyMax = -1; other.diskElementCount = 0;
        memset(&other.header, 0, sizeof(other.header));
    }
    MappedFileReader& operator=(MappedFileReader&& other) noexcept {
        if (this != &other) {
            closeMap();
            filename = std::move(other.filename); data = std::move(other.data); header = other.header;
            headerModified = other.headerModified; isOpen = other.isOpen; dirtyMin = other.dirtyMin;
            dirtyMax = other.dirtyMax; dataDirty = other.dataDirty; diskElementCount = other.diskElementCount;
            fileHandle = std::move(other.fileHandle);
            other.isOpen = false; other.dataDirty = false; other.headerModified = false;
            other.dirtyMin = INT64_MAX; other.dirtyMax = -1; other.diskElementCount = 0;
            memset(&other.header, 0, sizeof(other.header));
        }
        return *this;
    }
    void flush() {
        if (!isOpen) return;
        if (diskElementCount != static_cast<int64_t>(data.size())) { flushFull(); return; }
        if (headerModified) flushHeader();
        if (dataDirty) flushPartial();
    }
    bool open(const char* path) {
        closeMap(); filename = path;
        std::ifstream file(path, std::ios::binary);
        if (!file) return false;
        file.seekg(0, std::ios::end);
        auto fileSize = file.tellg();
        file.seekg(0, std::ios::beg);
        if (fileSize < 0 || static_cast<std::streamoff>(sizeof(ShardHeader)) > fileSize) return false;
        file.read(reinterpret_cast<char*>(&header), sizeof(ShardHeader));
        if (!file || header.noteCount < 0 || header.capacity <= 0 || header.noteCount > header.capacity) return false;
        size_t count = (static_cast<size_t>(fileSize) - sizeof(ShardHeader)) / sizeof(uint64_t);
        data.resize(count);
        if (count > 0) {
            file.read(reinterpret_cast<char*>(data.data()), count * sizeof(uint64_t));
            if (!file) return false;
        }
        isOpen = true; dataDirty = false; headerModified = false;
        dirtyMin = INT64_MAX; dirtyMax = -1; diskElementCount = static_cast<int64_t>(count);
        return true;
    }
    uint64_t get(int64_t index) const { return data[static_cast<size_t>(index)]; }
    void set(int64_t index, uint64_t value) { data[static_cast<size_t>(index)] = value; markDirty(index); }
    void getRange(int64_t index, int64_t count, uint64_t* out) const {
        std::memcpy(out, &data[static_cast<size_t>(index)], static_cast<size_t>(count) * sizeof(uint64_t));
    }
    void setRange(int64_t index, int64_t count, const uint64_t* in) {
        std::memcpy(&data[static_cast<size_t>(index)], in, static_cast<size_t>(count) * sizeof(uint64_t));
        markDirtyRange(index, count);
    }
    void shiftLeft(int64_t from, int64_t count) {
        size_t f = static_cast<size_t>(from);
        std::memmove(&data[f], &data[f + 1], static_cast<size_t>(count) * sizeof(uint64_t));
        markDirtyRange(from, count);
    }
    void shiftRight(int64_t from, int64_t count) {
        size_t f = static_cast<size_t>(from);
        std::memmove(&data[f + 1], &data[f], static_cast<size_t>(count) * sizeof(uint64_t));
        markDirtyRange(from, count + 1);
    }
    int64_t size() const { return static_cast<int64_t>(data.size()); }
    int64_t getNoteCount() const { return header.noteCount; }
    int64_t getCapacity() const { return header.capacity; }
    void setNoteCount(int64_t count) { header.noteCount = count; headerModified = true; flushHeader(); }
    void setCapacity(int64_t cap) { header.capacity = cap; headerModified = true; flushHeader(); }
    void resizeData(int64_t newCapacity) {
        if (newCapacity > static_cast<int64_t>(data.size())) data.resize(static_cast<size_t>(newCapacity), 0);
        else if (newCapacity < static_cast<int64_t>(data.size())) data.resize(static_cast<size_t>(newCapacity));
    }
};

// ============================================================================
// Sharded Chart Reader
// ============================================================================
class ShardedChartReader {
private:
    struct ShardInfo {
        MappedFileReader reader;
        int64_t noteCount = 0, capacity = 0, startIndex = 0, endIndex = 0;
        uint64_t shardId = 0;
    };

    std::string chartDir;
    std::unordered_map<uint64_t, ShardInfo> activeShards;
    std::vector<uint64_t> availableShards;
    std::vector<int64_t> shardStartIndices;
    std::vector<ShardMetaEntry> shardMeta;
    uint64_t currentShardId = 0;
    int64_t totalNotes = 0;

    static constexpr int POOL_SIZE = 20;
    static constexpr int64_t DEFAULT_SHARD_CAPACITY = 32;
    int64_t correctionTime = 0;

    std::mutex pendingMutex;
    std::unordered_set<uint64_t> pendingLoads; // Track shards currently in queue or being loaded
    
    // --- Persistent Background Worker Thread ---
    std::thread workerThread;
    std::queue<uint64_t> loadQueue;
    std::mutex queueMutex;
    std::condition_variable queueCV;
    std::unordered_map<uint64_t, ShardInfo*> completedLoads;
    bool canStopWorker = false;

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
                }

                {
                    std::lock_guard<std::mutex> lk(pendingMutex);
                    completedLoads[shardId] = info;
                    pendingLoads.erase(shardId); // Remove from pending set
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
        std::vector<TempInfo> tempInfos;
        tempInfos.reserve(files.size());
        for (const auto& name : files) {
            if (getExtension(name) != ".bin" || name == "shardMeta.bin") continue;
            std::string stem = getStem(name);
            uint64_t shardId;
            try { shardId = std::stoull(stem); } catch (...) { continue; }
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
            ShardMetaEntry entry;
            entry.shardId = info.shardId; entry.noteCount = info.noteCount; entry.capacity = info.capacity;
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
        for (size_t i = 0; i < shardMeta.size(); i++) {
            metaOut.write(reinterpret_cast<const char*>(&shardMeta[i]), sizeof(ShardMetaEntry));
        }
    }

    void loadShard(uint64_t shardId) {
        if (activeShards.find(shardId) != activeShards.end()) return;
        {
            std::lock_guard<std::mutex> lk(pendingMutex);
            auto it = completedLoads.find(shardId);
            if (it != completedLoads.end()) {
                ShardInfo* info = it->second;
                if (info) activeShards.emplace(shardId, std::move(*info));
                delete info;
                completedLoads.erase(it);
                pendingLoads.erase(shardId); // Clean up
                return;
            }
            pendingLoads.erase(shardId); // Fallback to sync load, remove from pending
        }
        std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
        ShardInfo info;
        info.shardId = shardId;
        info.startIndex = getShardStartIndex(shardId);
        size_t idx = findShardArrayIndex(shardId);
        if (idx < shardMeta.size()) info.capacity = shardMeta[idx].capacity;
        if (!info.reader.open(path.c_str())) throw std::runtime_error("Failed to open shard: " + std::to_string(shardId));
        info.noteCount = info.reader.getNoteCount();
        info.endIndex = info.startIndex + info.noteCount;
        activeShards.emplace(shardId, std::move(info));
    }

    void prefetchShards(uint64_t currentShardId) {
        for (int i = 1; i <= 5; i++) {
            uint64_t nextId = currentShardId + i;
            if (findShardArrayIndex(nextId) < availableShards.size()) asyncLoadShard(nextId);
        }
    }

    void drainPending() {
        std::lock_guard<std::mutex> lk(pendingMutex);
        if (completedLoads.empty()) return;
        for (auto it = completedLoads.begin(); it != completedLoads.end(); ) {
            ShardInfo* info = it->second;
            if (info && activeShards.find(it->first) == activeShards.end()) {
                activeShards.emplace(it->first, std::move(*info));
                delete info;
            } else {
                delete info;
            }
            it = completedLoads.erase(it);
        }
    }

    ShardInfo* getShardInfoFast(int64_t globalIndex, AccessCache& cache) {
        if (cache.info && globalIndex >= cache.info->startIndex && globalIndex < cache.info->endIndex) return cache.info;
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && cachedShardInfo) {
            cache.info = cachedShardInfo; cache.shardId = cachedShardId;
            return cachedShardInfo;
        }
        drainPending();
        if (globalIndex < 0 || globalIndex >= totalNotes) throw std::out_of_range("Global index out of range");
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1);
        uint64_t shardId = availableShards[shardPos];
        if (shardId != currentShardId && (shardId / 10 != currentShardId / 10)) {
            currentShardId = shardId;
            managePool(currentShardId);
        }
        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) { 
            asyncLoadShard(shardId);
            prefetchShards(shardId);
            return nullptr; 
        }
        cachedShardId = shardId; cachedShardStart = shardStartIndices[shardPos];
        cachedShardEnd = mapIt->second.endIndex; cachedShardInfo = &mapIt->second;
        cache.shardId = shardId; cache.info = cachedShardInfo;
        return cachedShardInfo;
    }

    void asyncLoadShard(uint64_t shardId) {
        if (activeShards.find(shardId) != activeShards.end()) return;
        {
            std::lock_guard<std::mutex> lk(pendingMutex);
            if (completedLoads.find(shardId) != completedLoads.end()) return;
            if (pendingLoads.find(shardId) != pendingLoads.end()) return; // Already queued/loading
        }
        {
            std::lock_guard<std::mutex> lk(queueMutex);
            loadQueue.push(shardId);
        }
        queueCV.notify_one();
    }

    void unloadShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it != activeShards.end()) {
            activeShards.erase(it);
            if (shardId == cachedShardId) { cachedShardInfo = nullptr; cachedShardStart = -1; cachedShardEnd = -1; }
        }
    }

    void managePool(uint64_t currentShard) {
        drainPending();
        std::vector<uint64_t> toRemove;
        for (auto& pair : activeShards) {
            int64_t first = static_cast<int64_t>(pair.first);
            int64_t dist = (first > static_cast<int64_t>(currentShard)) ? (first - static_cast<int64_t>(currentShard)) : (static_cast<int64_t>(currentShard) - first);
            if (dist > POOL_SIZE) toRemove.push_back(pair.first);
        }
        for (size_t i = 0; i < toRemove.size(); i++) unloadShard(toRemove[i]);
    }

    void rebuildShardStartIndices() {
        shardStartIndices.clear();
        int64_t cumulative = 0;
        for (size_t i = 0; i < availableShards.size(); i++) {
            shardStartIndices.push_back(cumulative);
            auto activeIt = activeShards.find(availableShards[i]);
            cumulative += (activeIt != activeShards.end()) ? activeIt->second.noteCount : shardMeta[i].noteCount;
        }
        totalNotes = cumulative;
        for (auto& pair : activeShards) {
            size_t idx = findShardArrayIndex(pair.first);
            if (idx < shardStartIndices.size()) {
                pair.second.startIndex = shardStartIndices[idx];
                pair.second.endIndex = pair.second.startIndex + pair.second.noteCount;
            }
        }
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

    void remapShard(uint64_t shardId, int64_t newCapacity) {
        auto it = activeShards.find(shardId);
        if (it == activeShards.end()) return;
        ShardInfo& shard = it->second;
        int64_t oldNoteCount = shard.noteCount;
        shard.reader.resizeData(newCapacity);
        shard.reader.setNoteCount(oldNoteCount);
        shard.reader.setCapacity(newCapacity);
        shard.noteCount = oldNoteCount; shard.capacity = newCapacity;
        shard.endIndex = shard.startIndex + shard.noteCount;
        shard.reader.flush();
        size_t idx = findShardArrayIndex(shardId);
        if (idx < shardMeta.size()) shardMeta[idx].capacity = newCapacity;
    }

public:
    std::vector<uint8_t> globalJudgement;
    bool globalJudgementInitialized = false;

    void initGlobalJudgement() {
        if (globalJudgementInitialized) return;
        size_t initialSize = static_cast<size_t>((totalNotes + 7) >> 3);
        globalJudgement.reserve(std::max<size_t>(initialSize * 2, static_cast<size_t>(1024))); 
        globalJudgement.assign(initialSize, 0);

        #if defined(_WIN32)
            if (!globalJudgement.empty()) VirtualLock(globalJudgement.data(), globalJudgement.size());
        #else
            if (!globalJudgement.empty()) mlock(globalJudgement.data(), globalJudgement.size());
        #endif
        globalJudgementInitialized = true;
    }

    ShardedChartReader(const char* path) : chartDir(path) {
        scanShards(); 
        initGlobalJudgement();
        startWorker();
    }

    ~ShardedChartReader() {
        writeMetadataFile();
        stopWorker();
        activeShards.clear();
    }

    int64_t cachedShardStart = -1, cachedShardEnd = -1;
    uint64_t cachedShardId = 0;
    ShardInfo* cachedShardInfo = nullptr;

    // --- RESTORED PUBLIC API METHODS ---

    uint64_t findShardForGlobalIndex(int64_t globalIndex) const {
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd) return cachedShardId;
        if (globalIndex < 0 || globalIndex >= totalNotes) throw std::out_of_range("Global index out of range");
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        return availableShards[static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1)];
    }

    ShardInfo* getShardInfo(int64_t globalIndex) {
        if (globalIndex >= cachedShardStart && globalIndex < cachedShardEnd && cachedShardInfo)
            return cachedShardInfo;
        drainPending();
        if (globalIndex < 0 || globalIndex >= totalNotes) throw std::out_of_range("Global index out of range");
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1);
        uint64_t shardId = availableShards[shardPos];
        if (shardId != currentShardId) { currentShardId = shardId; managePool(currentShardId); }
        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) { loadShard(shardId); mapIt = activeShards.find(shardId); }
        cachedShardId = shardId; cachedShardStart = shardStartIndices[shardPos];
        cachedShardEnd = (shardPos + 1 < shardStartIndices.size()) ? shardStartIndices[shardPos + 1] : totalNotes;
        cachedShardInfo = &mapIt->second;
        return cachedShardInfo;
    }

    uint64_t getNote(int64_t globalIndex) {
        if (globalIndex < 0 || globalIndex >= totalNotes) throw std::out_of_range("getNote: globalIndex out of range");
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        if (!info) return 0; 
        int64_t localIndex = globalIndex - info->startIndex;
        if (localIndex < 0 || localIndex >= info->noteCount) throw std::out_of_range("getNote: localIndex out of range");
        correctionTime = info->shardId * 1000000000;
        return info->reader.get(localIndex);
    }

    void setNote(int64_t globalIndex, uint64_t value) {
        ShardInfo* info = getShardInfoFast(globalIndex, readCache);
        if (!info) return; 
        info->reader.set(globalIndex - info->startIndex, value);
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
            if (needed > globalJudgement.capacity()) {
                globalJudgement.reserve(std::max<size_t>(needed, globalJudgement.capacity() * 2));
            }
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
        uint64_t packedNote =
            ((uint64_t)(localPos & 0x7FFFFFFF) << 0)  |
            ((uint64_t)(duration & 0x1FFFF)   << 31) |
            ((uint64_t)(index   & 0xFF)       << 48) |
            ((uint64_t)(type    & 0x7F)       << 56);

        cachedShardInfo = nullptr; cachedShardStart = -1; cachedShardEnd = -1;
        readCache.info = nullptr; judgeCache.info = nullptr;

        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) {
            std::string path = chartDir + "/" + std::to_string(shardId) + ".bin";
            
            if (getFileSize(path) < 0) {
                createShardFile(shardId, DEFAULT_SHARD_CAPACITY);
            }
            
            loadShard(shardId); 
            mapIt = activeShards.find(shardId);
            if (mapIt == activeShards.end()) throw std::runtime_error("Failed to load shard: " + std::to_string(shardId));
        }

        ShardInfo& shard = mapIt->second;
        if (shard.noteCount + 1 > shard.reader.size()) {
            int64_t newCap = std::max<int64_t>(shard.reader.size() + 64, (int64_t)(shard.reader.size() * 1.5));
            remapShard(shardId, newCap);
            mapIt = activeShards.find(shardId);
        }

        ShardInfo& s = mapIt->second;
        uint32_t newPos = static_cast<uint32_t>(localPos & 0x7FFFFFFF);
        int64_t lo = 0, hi = s.noteCount;
        while (lo < hi) {
            int64_t mid = lo + (hi - lo) / 2;
            if (getLocalPos(s.reader.get(mid)) <= newPos) lo = mid + 1; else hi = mid;
        }
        int64_t insertPos = lo;
        int64_t shiftCount = s.noteCount - insertPos;
        if (shiftCount > 0) s.reader.shiftRight(insertPos, shiftCount);
        s.reader.set(insertPos, packedNote);
        s.noteCount++; s.endIndex++; s.reader.setNoteCount(s.noteCount);
        totalNotes++;

        size_t shardPos = findShardArrayIndex(shardId);
        for (size_t i = shardPos + 1; i < shardStartIndices.size(); i++) shardStartIndices[i]++;
        for (auto& pair : activeShards) {
            if (pair.first > (uint64_t)shardId) { pair.second.startIndex++; pair.second.endIndex++; }
        }
        if (shardPos < shardMeta.size()) shardMeta[shardPos].noteCount = s.noteCount;
    }

    void sortShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it == activeShards.end()) return;
        ShardInfo& shard = it->second;
        if (shard.noteCount <= 1) return;
        std::vector<uint64_t> notes(static_cast<size_t>(shard.noteCount));
        shard.reader.getRange(0, shard.noteCount, notes.data());
        radixSortShardInPlace(notes);
        shard.reader.setRange(0, shard.noteCount, notes.data());
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

    void removeNote(int64_t globalIndex) {
        if (globalIndex < 0 || globalIndex >= totalNotes) throw std::out_of_range("Global index out of range");
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        size_t shardPos = static_cast<size_t>(std::distance(shardStartIndices.begin(), it) - 1);
        uint64_t shardId = availableShards[shardPos];
        auto mapIt = activeShards.find(shardId);
        if (mapIt == activeShards.end()) { loadShard(shardId); mapIt = activeShards.find(shardId); }
        ShardInfo& shard = mapIt->second;
        int64_t localIndex = globalIndex - shard.startIndex;
        int64_t remaining = shard.noteCount - localIndex - 1;
        if (remaining > 0) shard.reader.shiftLeft(localIndex, remaining);
        shard.noteCount--; shard.endIndex--; shard.reader.setNoteCount(shard.noteCount);
        totalNotes--;
        for (size_t i = shardPos + 1; i < availableShards.size(); i++) shardStartIndices[i]--;
        for (auto& pair : activeShards) {
            if (pair.first > shardId) { pair.second.startIndex--; pair.second.endIndex--; }
        }
        if (shardPos < shardMeta.size()) shardMeta[shardPos].noteCount = shard.noteCount;
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

    int64_t getLength() const { return totalNotes; }
    size_t getShardCount() const { return availableShards.size(); }

    void printPoolStats() const {
        std::cout << "[POOL] Active shards: " << activeShards.size() << " / " << availableShards.size() << std::endl;
        int count = 0;
        for (auto& pair : activeShards) {
            if (count++ >= 10) { std::cout << "  ... and " << (activeShards.size() - 10) << " more" << std::endl; break; }
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
void core_destroyChart() { ShardedChartReader* old = gReader; gReader = nullptr; delete old; }
uint64_t core_getNote(int64_t index) { if (!gReader) throw std::runtime_error("Chart not loaded"); return gReader->getNote(index); }
void core_setNote(int64_t index, uint64_t value) { if (!gReader) throw std::runtime_error("Chart not loaded"); gReader->setNote(index, value); }
void core_insertNote(int64_t globalPosition, int duration, int index, int type) { if (!gReader) throw std::runtime_error("Chart not loaded"); gReader->insertNote(globalPosition, duration, index, type); }
void core_removeNote(int64_t globalIndex) { if (!gReader) throw std::runtime_error("Chart not loaded"); gReader->removeNote(globalIndex); }
void core_printNoteInfo(int64_t index) { if (!gReader) throw std::runtime_error("Chart not loaded"); gReader->printNoteInfo(index); }
int64_t core_getLength() { if (!gReader) throw std::runtime_error("Chart not loaded"); return gReader->getLength(); }
size_t core_getShardCount() { if (!gReader) return 0; return gReader->getShardCount(); }
void core_printPoolStats() { if (gReader) gReader->printPoolStats(); }