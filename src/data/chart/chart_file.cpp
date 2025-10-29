#include <iostream>
#include <fstream>
#include <cstdint>
#include <vector>
#include <list>
#include <unordered_map>
#include <stdexcept>
#include <filesystem>
#include <algorithm>

// ============================================================================
// LazyBufferedFile: LRU-cached buffered I/O for slow read/write platforms
// ============================================================================
class LazyBufferedFile {
public:
    explicit LazyBufferedFile(size_t blockBytes = 1 << 20, size_t maxCachedBlocks = 8)
        : blockSize(blockBytes), maxBlocks(maxCachedBlocks) {}

    ~LazyBufferedFile() { close(); }

    bool open(const char* path) {
        close();

        filePath = path;
        file.open(filePath, std::ios::in | std::ios::out | std::ios::binary);
        if (!file.is_open()) {
            // create if missing
            file.open(filePath, std::ios::out | std::ios::binary);
            file.close();
            file.open(filePath, std::ios::in | std::ios::out | std::ios::binary);
        }
        if (!file.is_open()) return false;

        std::error_code ec;
        std::uintmax_t bytes = std::filesystem::file_size(filePath, ec);
        if (ec) bytes = 0;
        fileLength = bytes / sizeof(int64_t);
        return true;
    }

    void close() {
        if (!file.is_open()) return;
        flush();
        file.close();
        cacheList.clear();
        cacheMap.clear();
        fileLength = 0;
    }

    bool resize(size_t newLength) {
        flush();
        fileLength = newLength;

        // Extend file with zeros if needed
        std::error_code ec;
        size_t currentBytes = std::filesystem::file_size(filePath, ec);
        if (ec) currentBytes = 0;

        size_t newBytes = newLength * sizeof(int64_t);
        if (newBytes > currentBytes) {
            file.seekp(0, std::ios::end);
            std::vector<char> zeros(4096, 0);
            size_t remaining = newBytes - currentBytes;
            while (remaining > 0) {
                size_t chunk = std::min(remaining, zeros.size());
                file.write(zeros.data(), chunk);
                remaining -= chunk;
            }
            file.flush();
        }
        return true;
    }

    int64_t size() const { return fileLength; }

    int64_t readAt(size_t index) {
        Block* blk = ensureBlockLoaded(index);
        return blk->data[index - blk->startIndex];
    }

    void writeAt(size_t index, int64_t value) {
        Block* blk = ensureBlockLoaded(index);
        blk->data[index - blk->startIndex] = value;
        blk->dirty = true;
    }

    void flush() {
        for (auto& blk : cacheList) {
            if (blk.dirty) writeBlock(blk);
            blk.dirty = false;
        }
        file.flush();
    }

private:
    struct Block {
        size_t startIndex = 0;
        std::vector<int64_t> data;
        bool dirty = false;
    };

    using ListIt = std::list<Block>::iterator;

    Block* ensureBlockLoaded(size_t index) {
        size_t blockStart = (index * sizeof(int64_t) / blockSize) * (blockSize / sizeof(int64_t));

        auto it = cacheMap.find(blockStart);
        if (it != cacheMap.end()) {
            cacheList.splice(cacheList.begin(), cacheList, it->second);
            return &cacheList.front();
        }

        // Load new block
        if (cacheList.size() >= maxBlocks) evictBlock();

        cacheList.emplace_front();
        Block& blk = cacheList.front();
        blk.startIndex = blockStart;
        blk.data.resize(blockSize / sizeof(int64_t));
        blk.dirty = false;

        file.seekg(blockStart * sizeof(int64_t), std::ios::beg);
        file.read(reinterpret_cast<char*>(blk.data.data()), blockSize);
        size_t readBytes = file.gcount();
        if (readBytes < blockSize) {
            std::fill(blk.data.begin() + readBytes / sizeof(int64_t), blk.data.end(), 0);
        }

        cacheMap[blockStart] = cacheList.begin();
        return &blk;
    }

    void evictBlock() {
        printf("Evict block");
        auto last = std::prev(cacheList.end());
        if (last->dirty) writeBlock(*last);
        cacheMap.erase(last->startIndex);
        cacheList.pop_back();
    }

    void writeBlock(const Block& blk) {
        file.seekp(blk.startIndex * sizeof(int64_t), std::ios::beg);
        file.write(reinterpret_cast<const char*>(blk.data.data()),
                   blk.data.size() * sizeof(int64_t));
    }

    std::fstream file;
    std::string filePath;
    size_t blockSize;
    size_t maxBlocks;
    size_t fileLength = 0;

    std::list<Block> cacheList;
    std::unordered_map<size_t, ListIt> cacheMap;
};

// ============================================================================
// Global chart I/O API
// ============================================================================
static LazyBufferedFile gFile;
static int64_t gLength = 0;

bool remap(size_t newLength) {
    bool ok = gFile.resize(newLength);
    gLength = gFile.size();
    return ok;
}

void loadChart(const char* inFile) {
    if (!gFile.open(inFile))
        throw std::runtime_error("Failed to open chart file");
    gLength = gFile.size();
}

void destroyChart() {
    gFile.close();
    gLength = 0;
}

int64_t getNote(int64_t i) { return gFile.readAt(i); }
void setNote(int64_t i, int64_t v) { gFile.writeAt(i, v); }
int64_t getLength() { return gLength; }

inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

void insertNote(int64_t index, int64_t value) {
    if (index < 0 || index > gLength)
        throw std::out_of_range("index out of range");

    // Resize file to hold one more
    if (!remap(gLength + 1))
        throw std::runtime_error("failed to resize file");

    // Shift elements right from end to index
    for (int64_t i = gLength - 1; i > index; --i) {
        int64_t prev = gFile.readAt(i - 1);
        gFile.writeAt(i, prev);
    }

    gFile.writeAt(index, value);
    ++gLength;
}

void removeNote(int64_t index) {
    if (index < 0 || index >= gLength)
        throw std::out_of_range("index out of range");

    // Shift left from index+1 to end
    for (int64_t i = index; i < gLength - 1; ++i) {
        int64_t next = gFile.readAt(i + 1);
        gFile.writeAt(i, next);
    }

    if (!remap(gLength - 1))
        throw std::runtime_error("failed to shrink file");
    --gLength;
}

void insertNotes(const std::vector<int64_t>& newNotes) {
    if (newNotes.empty()) return;

    int64_t oldLen = gLength;
    int64_t k = newNotes.size();
    int64_t newLen = oldLen + k;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    int64_t dataIdx = oldLen - 1;
    int64_t newIdx = k - 1;
    int64_t writeIdx = newLen - 1;

    while (dataIdx >= 0 && newIdx >= 0) {
        int64_t d = gFile.readAt(dataIdx);
        int64_t n = newNotes[newIdx];
        if (extractTime(d) > extractTime(n)) {
            gFile.writeAt(writeIdx--, d);
            --dataIdx;
        } else {
            gFile.writeAt(writeIdx--, n);
            --newIdx;
        }
    }

    while (newIdx >= 0) gFile.writeAt(writeIdx--, newNotes[newIdx--]);
    gLength = newLen;
}

void removeNotes(const std::vector<int64_t>& notesToRemove) {
    if (notesToRemove.empty()) return;

    int64_t writeIdx = 0;
    for (int64_t readIdx = 0; readIdx < gLength; ++readIdx) {
        int64_t note = gFile.readAt(readIdx);
        if (std::find(notesToRemove.begin(), notesToRemove.end(), note) == notesToRemove.end()) {
            gFile.writeAt(writeIdx++, note);
        }
    }

    if (!remap(writeIdx))
        throw std::runtime_error("failed to shrink file after removeNotes");
    gLength = writeIdx;
}
