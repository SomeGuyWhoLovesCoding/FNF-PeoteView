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
#include <set>

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
// Constants
// ============================================================================
static constexpr int64_t JUDGEDATA_MIN_BYTES = 1179648; // 1.125 MB

// ============================================================================
// Portable filesystem helpers
// ============================================================================
static int64_t getFileSize(const std::string& path) {
#ifdef _WIN32
    WIN32_FILE_ATTRIBUTE_DATA info;
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &info))
        return -1;
    return ((int64_t)info.nFileSizeHigh << 32) | (int64_t)info.nFileSizeLow;
#else
    struct stat st;
    if (stat(path.c_str(), &st) != 0) return -1;
    return (int64_t)st.st_size;
#endif
}

static bool fileExists(const std::string& path) {
    return getFileSize(path) >= 0;
}

static bool deleteFile(const std::string& path) {
#ifdef _WIN32
    return DeleteFileA(path.c_str()) != 0;
#else
    return unlink(path.c_str()) == 0;
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
// Time formatting
// ============================================================================
static std::string formatTime(double ms, bool showMS = false) {
    if (std::isnan(ms)) return "null";
    int centis  = static_cast<int>(ms * 0.1) % 100;
    int seconds = static_cast<int>(ms * 0.001);
    int hours   = seconds / 3600; seconds %= 3600;
    int minutes = seconds / 60;   seconds %= 60;
    std::string t;
    if (hours > 0) t += std::to_string(hours) + ":";
    if (minutes < 10 && hours > 0) t += "0";
    t += std::to_string(minutes) + ":";
    if (seconds < 10) t += "0";
    t += std::to_string(seconds);
    if (showMS) {
        t += ".";
        if (centis < 10) t += "0";
        t += std::to_string(centis);
    }
    return t;
}

// ============================================================================
// MetaNote bitpacking (64 bits, no flag bits):
//   [0..31]  position — 32 bits, 1/4,000,000 ms granularity (1/16 ns)
//   [32..47] duration — 16 bits, 1 ms granularity
//   [48..55] index    — 8 bits,  up to 256 keys
//   [56..63] type     — 8 bits,  up to 256 note types
// ============================================================================
static inline uint32_t getPosition(uint64_t n) { return (uint32_t)(n & 0xFFFFFFFFull); }
static inline uint16_t getDuration(uint64_t n) { return (uint16_t)((n >> 32) & 0xFFFFull); }
static inline uint8_t  getIndex   (uint64_t n) { return (uint8_t) ((n >> 48) & 0xFFull);  }
static inline uint8_t  getType    (uint64_t n) { return (uint8_t) ((n >> 56) & 0xFFull);  }

static inline double ticksToMs(uint32_t ticks) { return ticks / 4000000.0; }

// ============================================================================
// MappedFile — read-only memory-mapped chart shard.
// ============================================================================
class MappedFile {
public:
    MappedFile() {}
    ~MappedFile() { close(); }

    MappedFile(const MappedFile&)            = delete;
    MappedFile& operator=(const MappedFile&) = delete;

    MappedFile(MappedFile&& o) noexcept { *this = std::move(o); }
    MappedFile& operator=(MappedFile&& o) noexcept {
        if (this != &o) {
            close();
            ptr_  = o.ptr_;  o.ptr_  = nullptr;
            size_ = o.size_; o.size_ = 0;
#ifdef _WIN32
            hFile_    = o.hFile_;    o.hFile_    = INVALID_HANDLE_VALUE;
            hMapping_ = o.hMapping_; o.hMapping_ = nullptr;
#else
            fd_ = o.fd_; o.fd_ = -1;
#endif
        }
        return *this;
    }

    bool open(const std::string& path) {
        close();
        int64_t sz = getFileSize(path);
        if (sz <= 0) return false;
        size_ = (size_t)sz;

#ifdef _WIN32
        hFile_ = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                             nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile_ == INVALID_HANDLE_VALUE) return false;
        hMapping_ = CreateFileMappingA(hFile_, nullptr, PAGE_READONLY, 0, 0, nullptr);
        if (!hMapping_) {
            CloseHandle(hFile_); hFile_ = INVALID_HANDLE_VALUE; return false;
        }
        ptr_ = MapViewOfFile(hMapping_, FILE_MAP_READ, 0, 0, 0);
        if (!ptr_) {
            CloseHandle(hMapping_); hMapping_ = nullptr;
            CloseHandle(hFile_);    hFile_    = INVALID_HANDLE_VALUE;
            return false;
        }
#else
        fd_ = ::open(path.c_str(), O_RDONLY);
        if (fd_ < 0) return false;
        ptr_ = mmap(nullptr, size_, PROT_READ, MAP_SHARED, fd_, 0);
        if (ptr_ == MAP_FAILED) {
            ::close(fd_); fd_ = -1; ptr_ = nullptr; return false;
        }
        madvise(ptr_, size_, MADV_SEQUENTIAL);
#endif
        return true;
    }

    void close() {
        if (!ptr_) return;
#ifdef _WIN32
        UnmapViewOfFile(ptr_);
        CloseHandle(hMapping_); hMapping_ = nullptr;
        CloseHandle(hFile_);    hFile_    = INVALID_HANDLE_VALUE;
#else
        munmap(ptr_, size_);
        ::close(fd_); fd_ = -1;
#endif
        ptr_  = nullptr;
        size_ = 0;
    }

    const uint64_t* data()  const { return reinterpret_cast<const uint64_t*>(ptr_); }
    int64_t         count() const { return (int64_t)(size_ / sizeof(uint64_t)); }
    bool            valid() const { return ptr_ != nullptr; }

private:
    void*  ptr_  = nullptr;
    size_t size_ = 0;
#ifdef _WIN32
    HANDLE hFile_    = INVALID_HANDLE_VALUE;
    HANDLE hMapping_ = nullptr;
#else
    int fd_ = -1;
#endif
};

// ============================================================================
// JudgeMap — memory-mapped read/write judgedata shard.
//
// Layout: 3 bits per note, packed LSB-first into a byte stream.
//   bit 0 = hit (flag)
//   bit 1 = missed
//   bit 2 = held
//
// File lifecycle:
//   - No file on disk  →  shard is fully clean; all reads return 0b000.
//   - File exists      →  mapped read/write on first access.
//   - clearJudgement() →  unmap + delete file; shard returns to clean state.
//
// Allocation size: max(JUDGEDATA_MIN_BYTES, next power-of-two >= exact bytes).
// New pages are zero-filled by the OS so no explicit memset needed on creation.
// ============================================================================
class JudgeMap {
public:
    JudgeMap()  {}
    ~JudgeMap() { unmap(); }

    JudgeMap(JudgeMap&& o) noexcept { *this = std::move(o); }
    JudgeMap& operator=(JudgeMap&& o) noexcept {
        if (this != &o) {
            // release current resources
            unmap();
            // transfer ownership
            path_        = std::move(o.path_);
            noteCount_   = o.noteCount_;
            exact_       = o.exact_;
            mappedBytes_ = o.mappedBytes_;
            ptr_         = o.ptr_;
    #ifdef _WIN32
            hFile_       = o.hFile_;
            hMapping_    = o.hMapping_;
    #else
            fd_          = o.fd_;
    #endif
            // leave source in a safe, destructible state
            o.ptr_         = nullptr;
            o.mappedBytes_ = 0;
            o.noteCount_   = 0;
            o.exact_       = 0;
            o.path_.clear();
    #ifdef _WIN32
            o.hFile_       = INVALID_HANDLE_VALUE;
            o.hMapping_    = nullptr;
    #else
            o.fd_          = -1;
    #endif
        }
        return *this;
    }

    // Attach to a shard path and note count. Does not create the file.
    void attach(const std::string& path, int64_t noteCount) {
        unmap();
        path_      = path;
        noteCount_ = noteCount;
        exact_     = (noteCount * 3 + 7) / 8;
        if (fileExists(path_)) ensureMapped();
    }

    void detach() { unmap(); path_.clear(); noteCount_ = 0; exact_ = 0; }

    // Returns 0b000 if unmapped (file absent = clean) or index out of range.
    uint8_t get(int64_t localIndex) const {
        if (!ptr_) return 0;
        int64_t bitPos  = localIndex * 3;
        int64_t byteIdx = bitPos / 8;
        int     shift   = (int)(bitPos % 8);
        if (byteIdx >= mappedBytes_) return 0;
        uint32_t word = ptr_[byteIdx];
        if (byteIdx + 1 < mappedBytes_) word |= ((uint32_t)ptr_[byteIdx + 1] << 8);
        return (uint8_t)((word >> shift) & 0x7);
    }

    void set(int64_t localIndex, uint8_t value) {
        ensureMapped();
        int64_t bitPos  = localIndex * 3;
        int64_t byteIdx = bitPos / 8;
        int     shift   = (int)(bitPos % 8);
        ptr_[byteIdx] = (uint8_t)((ptr_[byteIdx] & ~(0x7u << shift)) |
                                  ((value & 0x7u) << shift));
        int overflow = shift + 3 - 8;
        if (overflow > 0 && byteIdx + 1 < mappedBytes_) {
            int keep = 8 - overflow;
            ptr_[byteIdx + 1] = (uint8_t)((ptr_[byteIdx + 1] & ~((1u << overflow) - 1u)) |
                                           ((value & 0x7u) >> keep));
        }
    }

    bool isFlag  (int64_t i) const { return (get(i) >> 0) & 1; }
    bool isMissed(int64_t i) const { return (get(i) >> 1) & 1; }
    bool isHeld  (int64_t i) const { return (get(i) >> 2) & 1; }

    void setFlag  (int64_t i, bool v) { uint8_t s=get(i); set(i, v?(s|1):(s&~1)); }
    void setMissed(int64_t i, bool v) { uint8_t s=get(i); set(i, v?(s|2):(s&~2)); }
    void setHeld  (int64_t i, bool v) { uint8_t s=get(i); set(i, v?(s|4):(s&~4)); }

    // Unmap and delete the file. All subsequent reads return 0b000.
    void clearJudgement() {
        unmap();
        if (!path_.empty() && fileExists(path_))
            deleteFile(path_);
    }

    bool isMapped() const { return ptr_ != nullptr; }

private:
    std::string path_;
    int64_t     noteCount_   = 0;
    int64_t     exact_       = 0;
    int64_t     mappedBytes_ = 0;
    uint8_t*    ptr_         = nullptr;
#ifdef _WIN32
    HANDLE hFile_    = INVALID_HANDLE_VALUE;
    HANDLE hMapping_ = nullptr;
#else
    int fd_ = -1;
#endif

    // Allocation size: max(JUDGEDATA_MIN_BYTES, next power-of-two >= exact_).
    int64_t allocSize() const {
        int64_t sz = JUDGEDATA_MIN_BYTES;
        if (exact_ > sz) {
            sz = 1;
            while (sz < exact_) sz <<= 1;
        }
        return sz;
    }

    void ensureMapped() {
        if (ptr_) return;

        int64_t fileBytes = allocSize();

#ifdef _WIN32
        hFile_ = CreateFileA(path_.c_str(),
                             GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                             OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile_ == INVALID_HANDLE_VALUE)
            throw std::runtime_error("JudgeMap: cannot open " + path_);

        LARGE_INTEGER cur; GetFileSizeEx(hFile_, &cur);
        if (cur.QuadPart < fileBytes) {
            LARGE_INTEGER li; li.QuadPart = fileBytes;
            SetFilePointerEx(hFile_, li, nullptr, FILE_BEGIN);
            SetEndOfFile(hFile_);
            // NTFS zero-fills extended regions automatically.
        }

        hMapping_ = CreateFileMappingA(hFile_, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        if (!hMapping_) {
            CloseHandle(hFile_); hFile_ = INVALID_HANDLE_VALUE;
            throw std::runtime_error("JudgeMap: CreateFileMapping failed for " + path_);
        }
        ptr_ = reinterpret_cast<uint8_t*>(
            MapViewOfFile(hMapping_, FILE_MAP_ALL_ACCESS, 0, 0, 0));
        if (!ptr_) {
            CloseHandle(hMapping_); hMapping_ = nullptr;
            CloseHandle(hFile_);    hFile_    = INVALID_HANDLE_VALUE;
            throw std::runtime_error("JudgeMap: MapViewOfFile failed for " + path_);
        }
#else
        fd_ = ::open(path_.c_str(), O_RDWR | O_CREAT, 0644);
        if (fd_ < 0)
            throw std::runtime_error("JudgeMap: cannot open " + path_);

        struct stat st; fstat(fd_, &st);
        if ((int64_t)st.st_size < fileBytes) {
            if (ftruncate(fd_, (off_t)fileBytes) != 0) {
                ::close(fd_); fd_ = -1;
                throw std::runtime_error("JudgeMap: ftruncate failed for " + path_);
            }
            // POSIX guarantees zero-fill for pages extended by ftruncate.
        }

        ptr_ = reinterpret_cast<uint8_t*>(
            mmap(nullptr, (size_t)fileBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0));
        if (ptr_ == MAP_FAILED) {
            ::close(fd_); fd_ = -1; ptr_ = nullptr;
            throw std::runtime_error("JudgeMap: mmap failed for " + path_);
        }
        madvise(ptr_, (size_t)fileBytes, MADV_RANDOM);
#endif
        mappedBytes_ = fileBytes;
    }

    void unmap() {
        if (!ptr_) return;
#ifdef _WIN32
        UnmapViewOfFile(ptr_); ptr_ = nullptr;
        CloseHandle(hMapping_); hMapping_ = nullptr;
        CloseHandle(hFile_);    hFile_    = INVALID_HANDLE_VALUE;
#else
        munmap(ptr_, (size_t)mappedBytes_); ptr_ = nullptr;
        ::close(fd_); fd_ = -1;
#endif
        mappedBytes_ = 0;
    }
};

// ============================================================================
// ShardedChartReader
// ============================================================================
class ShardedChartReader {
private:
    struct ShardInfo {
        MappedFile chart;
        JudgeMap   judge;
        int64_t    noteCount  = 0;
        uint64_t   shardId    = 0;
        int64_t    startIndex = 0;
        int64_t    endIndex   = 0;
    };

    std::string                   chartDir;
    std::map<uint64_t, ShardInfo> activeShards;
    std::vector<uint64_t>         availableShards;
    std::vector<int64_t>          shardStartIndices;
    uint64_t                      currentShardId = 0;
    int64_t                       totalNotes     = 0;
    int64_t                       correctionTime = 0;

    static constexpr int POOL_SIZE         = 100;
    static constexpr int PRELOAD_THRESHOLD = 50;

    std::string judgedataPath(uint64_t shardId) const {
        return chartDir + "/judge" + std::to_string(shardId) + ".bin";
    }

    void scanShards() {
        std::vector<std::string> files;
        listFiles(chartDir, files);

        // Step 1: Collect existing shard IDs
        std::set<uint64_t> existingShards;
        uint64_t maxShardId = 0;
        
        for (const auto& name : files) {
            if (getExtension(name) != ".bin") continue;
            std::string stem = getStem(name);
            if (stem.rfind("judge", 0) == 0) continue; // skip judge files
            try {
                uint64_t id = std::stoull(stem);
                existingShards.insert(id);
                maxShardId = std::max<uint64_t>(maxShardId, id);
            } catch (...) {
                std::cerr << "Warning: unrecognised shard filename: " << name << "\n";
            }
        }

        // Step 2: Build logical shard map (0..maxShardId inclusive)
        int64_t cumulative = 0;
        for (uint64_t logicalId = 0; logicalId <= maxShardId; ++logicalId) {
            // Every logical shard gets an entry in shardStartIndices
            shardStartIndices.push_back(cumulative);
            
            // Only track physically existing shards for loading
            if (existingShards.count(logicalId)) {
                availableShards.push_back(logicalId);
                
                std::string path = chartDir + "/" + std::to_string(logicalId) + ".bin";
                int64_t sz = getFileSize(path);
                if (sz < 0) throw std::runtime_error("Cannot stat shard " + std::to_string(logicalId));
                cumulative += sz / (int64_t)sizeof(uint64_t);
            }
            // Missing shards contribute 0 notes but preserve index alignment
        }
        
        totalNotes = cumulative;
        std::cout << "[INFO] Logical shards: 0.." << maxShardId 
                << " | Physical files: " << availableShards.size()
                << " | Total notes: " << totalNotes << "\n";
    }

    int64_t shardStartFor(uint64_t shardId) const {
        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), shardId);
        if (it == availableShards.end() || *it != shardId)
            throw std::runtime_error("Shard not found: " + std::to_string(shardId));
        return shardStartIndices[std::distance(availableShards.begin(), it)];
    }

    void loadShard(uint64_t logicalShardId) {
        if (activeShards.count(logicalShardId)) return;

        ShardInfo info;
        info.shardId    = logicalShardId; // logical ID, not array index
        info.startIndex = shardStartIndices[logicalShardId]; // direct lookup

        std::string path = chartDir + "/" + std::to_string(logicalShardId) + ".bin";
        if (!info.chart.open(path))
            throw std::runtime_error("Failed to mmap shard " + std::to_string(logicalShardId));

        info.noteCount = info.chart.count();
        info.endIndex  = info.startIndex + info.noteCount;
        info.judge.attach(judgedataPath(logicalShardId), info.noteCount);

        activeShards[logicalShardId] = std::move(info);
    }

    void unloadShard(uint64_t shardId) {
        auto it = activeShards.find(shardId);
        if (it == activeShards.end()) return;
        it->second.judge.detach();
        it->second.chart.close();
        activeShards.erase(it);
    }

    void managePool(uint64_t current) {
        std::vector<uint64_t> toRemove;
        for (auto& p : activeShards)
            if (p.first + POOL_SIZE < current)
                toRemove.push_back(p.first);
        for (uint64_t id : toRemove) unloadShard(id);

        auto it = std::lower_bound(availableShards.begin(), availableShards.end(), current);
        if (it != availableShards.end()) {
            size_t pos = std::distance(availableShards.begin(), it);
            size_t rem = availableShards.size() - pos;
            if (rem <= (size_t)PRELOAD_THRESHOLD) {
                size_t n = (std::min)((size_t)POOL_SIZE, rem);
                for (size_t i = 0; i < n; i++) {
                    uint64_t next = availableShards[pos + i];
                    if (!activeShards.count(next)) loadShard(next);
                }
            }
        }
    }

    ShardInfo& resolve(int64_t globalIndex, int64_t& localOut) {
        uint64_t logicalShardId = findShardFor(globalIndex);
        
        // Time correction: logical shard ID × ticks per 0.25s interval
        correctionTime = (int64_t)logicalShardId * 4000000000LL; // 0.25s = 1e9 ticks
        
        // Check if this logical shard has a physical file
        if (!std::binary_search(availableShards.begin(), availableShards.end(), logicalShardId)) {
            // Missing shard = no notes in this time window
            throw std::runtime_error("Accessing note in missing shard " + std::to_string(logicalShardId));
        }
        
        if (logicalShardId != currentShardId) {
            currentShardId = logicalShardId;
            managePool(currentShardId);
        }
        
        if (!activeShards.count(logicalShardId)) {
            loadShard(logicalShardId); // loadShard uses logical ID as key
        }
        
        ShardInfo& info = activeShards[logicalShardId];
        localOut = globalIndex - info.startIndex;
        return info;
    }

public:
    explicit ShardedChartReader(const char* path) : chartDir(path) {
        scanShards();
        if (availableShards.empty())
            throw std::runtime_error("No shards found in " + chartDir);
        size_t n = (std::min)((size_t)POOL_SIZE, availableShards.size());
        for (size_t i = 0; i < n; i++) loadShard(availableShards[i]);
    }

    ~ShardedChartReader() {
        for (auto& p : activeShards) {
            p.second.judge.detach();
            p.second.chart.close();
        }
    }

    uint64_t findShardFor(int64_t globalIndex) const {
        if (globalIndex < 0 || globalIndex >= totalNotes)
            throw std::out_of_range("Global index out of range");
        
        // Binary search on logical shard boundaries
        auto it = std::upper_bound(shardStartIndices.begin(), shardStartIndices.end(), globalIndex);
        if (it == shardStartIndices.begin()) 
            throw std::runtime_error("Invalid shard lookup");
        
        // The logical shard ID is the INDEX in shardStartIndices
        uint64_t logicalShardId = std::distance(shardStartIndices.begin(), it) - 1;
        return logicalShardId;
    }

    // Time correction now uses logical shard ID directly ✅
    uint64_t findShardForTimeCorrection(int64_t globalIndex) const {
        return findShardFor(globalIndex); // Same logic, clearer name
    }

    // ── Chart access ──────────────────────────────────────────────────────────
    uint64_t getNote(int64_t i) {
        int64_t l = 0; return resolve(i, l).chart.data()[l];
    }

    // ── Judgement state ───────────────────────────────────────────────────────
    bool isNoteHit   (int64_t i) { int64_t l = 0; return resolve(i,l).judge.isFlag  (l); }
    bool isNoteMissed(int64_t i) { int64_t l = 0; return resolve(i,l).judge.isMissed(l); }
    bool isNoteHeld  (int64_t i) { int64_t l = 0; return resolve(i,l).judge.isHeld  (l); }

    void setNoteHit   (int64_t i, bool v) { int64_t l = 0; resolve(i,l).judge.setFlag  (l,v); }
    void setNoteMissed(int64_t i, bool v) { int64_t l = 0; resolve(i,l).judge.setMissed(l,v); }
    void setNoteHeld  (int64_t i, bool v) { int64_t l = 0; resolve(i,l).judge.setHeld  (l,v); }

    // ── clearJudgement ────────────────────────────────────────────────────────
    // Deletes every judgeN.bin for all shards — active and evicted.
    // After this call every note reads as 0b000.
    void clearJudgement() {
        for (auto& p : activeShards)
            p.second.judge.clearJudgement();
        // Also sweep evicted shards that may have a dirty file on disk.
        for (uint64_t id : availableShards) {
            std::string jp = judgedataPath(id);
            if (fileExists(jp)) deleteFile(jp);
        }
    }

    // ── Debug ─────────────────────────────────────────────────────────────────
    void printNoteInfo(int64_t i) {
        uint64_t n  = getNote(i);
        double   ms = ticksToMs(getPosition(n));
        std::cout << "  Note " << i << ": "
                  << "time=" << formatTime(ms, true)
                  << " pos=" << getPosition(n) << "ticks"
                  << " dur=" << getDuration(n) << "ms"
                  << " idx=" << (int)getIndex(n)
                  << " type=" << (int)getType(n)
                  << " flags=["
                  << (isNoteHit(i)    ? "F" : "")
                  << (isNoteMissed(i) ? "M" : "")
                  << (isNoteHeld(i)   ? "H" : "") << "]"
                  << " raw=0x" << std::hex << n << std::dec << "\n";
    }

    int64_t getLength()     const { return totalNotes; }
    size_t  getShardCount() const { return availableShards.size(); }

    void printPoolStats() const {
        std::cout << "[POOL] Active: " << activeShards.size()
                  << " / " << availableShards.size() << "\n";
        int c = 0;
        for (const auto& p : activeShards) {
            if (c++ >= 10) {
                std::cout << "  ... and " << (activeShards.size()-10) << " more\n";
                break;
            }
            std::cout << "  Shard " << p.first
                      << ": " << p.second.noteCount << " notes"
                      << (p.second.judge.isMapped() ? " [judge mapped]" : " [judge clean]")
                      << "\n";
        }
    }
};

// ============================================================================
// Global API
// ============================================================================
static ShardedChartReader* gReader = nullptr;

void core_loadChart   (const char* path) { delete gReader; gReader = new ShardedChartReader(path); }
void core_destroyChart()                 { delete gReader; gReader = nullptr; }

uint64_t core_getNote(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->getNote(index);
}

int64_t core_getLength() {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->getLength();
}

size_t core_getShardCount() {
    if (!gReader) return 0;
    return gReader->getShardCount();
}

bool core_isNoteHit(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->isNoteHit(index);
}
void core_setNoteHit(int64_t index, bool value) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->setNoteHit(index, value);
}

bool core_isNoteMissed(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->isNoteMissed(index);
}
void core_setNoteMissed(int64_t index, bool value) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->setNoteMissed(index, value);
}

bool core_isNoteHeld(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    return gReader->isNoteHeld(index);
}
void core_setNoteHeld(int64_t index, bool value) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->setNoteHeld(index, value);
}

void core_clearJudgement() {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->clearJudgement();
}

void core_printNoteInfo(int64_t index) {
    if (!gReader) throw std::runtime_error("Chart not loaded");
    gReader->printNoteInfo(index);
}
void core_printPoolStats() {
    if (gReader) gReader->printPoolStats();
}