#include <iostream>
#include <vector>
#include <cstdint>
#include <cstring>
#include <stdexcept>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

// ----------------- Config -----------------
constexpr int64_t NOTES_PER_BLOCK = 256;
constexpr int64_t BLOCK_SIZE_BYTES = NOTES_PER_BLOCK * sizeof(int64_t) + sizeof(uint16_t);

// ----------------- Globals -----------------
int64_t* data = nullptr;
int64_t mapped_bytes = 0;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap = NULL;
#else
int fd = -1;
#endif

// Blocks in memory
std::vector<std::vector<int64_t>> blocks;
// Cumulative offsets for binary search
std::vector<int64_t> blockOffsets;

// ----------------- Remap Helpers -----------------
static bool remap(int64_t newBytes) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }

    LARGE_INTEGER size; size.QuadPart = newBytes;
    if (!SetFilePointerEx(hFile, size, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
        return false;

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) { CloseHandle(hMap); hMap = NULL; return false; }

#else
    if (!data) {
        if (ftruncate(fd, newBytes) == -1) return false;
        data = (int64_t*)mmap(nullptr, newBytes,
                              PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (data == MAP_FAILED) { data = nullptr; return false; }
    } else {
        if (ftruncate(fd, newBytes) == -1) return false;
        void* newData = mremap(data, mapped_bytes, newBytes, MREMAP_MAYMOVE);
        if (newData == MAP_FAILED) return false;
        data = (int64_t*)newData;
    }
#endif
    mapped_bytes = newBytes;
    return true;
}

// ----------------- Block Offsets -----------------
void rebuildBlockOffsets() {
    blockOffsets.clear();
    int64_t sum = 0;
    for (auto& b : blocks) {
        blockOffsets.push_back(sum);F
        sum += b.size();
    }
    length = sum;
}

int64_t findBlock(int64_t index, int64_t& offsetInBlock) {
    if (index >= length) throw std::out_of_range("Index out of range");
    int64_t left = 0, right = blockOffsets.size() - 1;
    while (left < right) {
        int64_t mid = (left + right + 1) / 2;
        if (blockOffsets[mid] <= index) left = mid;
        else right = mid - 1;
    }
    offsetInBlock = index - blockOffsets[left];
    return left;
}

// ----------------- Load / Destroy -----------------
void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    mapped_bytes = fileSize.QuadPart;
#else
    fd = open(inFile, O_RDWR | O_CREAT, 0644);
    struct stat st; fstat(fd, &st);
    mapped_bytes = st.st_size;
#endif
    if (mapped_bytes == 0) mapped_bytes = BLOCK_SIZE_BYTES;
    if (!remap(mapped_bytes)) throw std::runtime_error("Failed mmap file");

    // Rebuild blocks in memory
    blocks.clear();
    int64_t offset = 0;
    while (offset + sizeof(uint16_t) < mapped_bytes) {
        std::vector<int64_t> b;
        int64_t available = (mapped_bytes - offset) / sizeof(int64_t);
        int64_t count = NOTES_PER_BLOCK;
		if (count < available) count = available;
        b.resize(count);
        memcpy(b.data(), (char*)data + offset, count * sizeof(int64_t));
        blocks.push_back(b);
        offset += BLOCK_SIZE_BYTES;
    }

    rebuildBlockOffsets();
}

void destroyChart() {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, mapped_bytes); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
#endif
    blocks.clear();
    blockOffsets.clear();
    mapped_bytes = 0;
    length = 0;
}

// ----------------- Access -----------------
int64_t getNote(int64_t index) {
    int64_t offset;
    int64_t blk = findBlock(index, offset);
    return blocks[blk][offset];
}

void setNote(int64_t index, int64_t value) {
    int64_t offset;
    int64_t blk = findBlock(index, offset);
    blocks[blk][offset] = value;
}

int64_t getLength() {
	return length;
}

// ----------------- Insert / Remove -----------------
void insertNote(int64_t index, int64_t value) {
    if (index > length) throw std::out_of_range("Index out of range");

    if (index == length) {
        // Append
        if (blocks.empty() || blocks.back().size() >= NOTES_PER_BLOCK)
            blocks.emplace_back();
        blocks.back().push_back(value);
        rebuildBlockOffsets();
        return;
    }

    int64_t offsetInBlock;
    int64_t blk = findBlock(index, offsetInBlock);
    auto& b = blocks[blk];
    if (b.size() < NOTES_PER_BLOCK) {
        b.insert(b.begin() + offsetInBlock, value);
    } else {
        // Split block
        std::vector<int64_t> newBlock(b.begin() + NOTES_PER_BLOCK/2, b.end());
        b.erase(b.begin() + NOTES_PER_BLOCK/2, b.end());
        if (offsetInBlock > b.size())
            newBlock.insert(newBlock.begin() + (offsetInBlock - b.size()), value);
        else
            b.insert(b.begin() + offsetInBlock, value);
        blocks.insert(blocks.begin() + blk + 1, std::move(newBlock));
    }
    rebuildBlockOffsets();
}

void removeNote(int64_t index) {
    if (index >= length) throw std::out_of_range("Index out of range");
    int64_t offsetInBlock;
    int64_t blk = findBlock(index, offsetInBlock);
    auto& b = blocks[blk];
    b.erase(b.begin() + offsetInBlock);

    if (b.empty() && blocks.size() > 1)
        blocks.erase(blocks.begin() + blk);

    rebuildBlockOffsets();
}

// ----------------- Append-Only Fast Path -----------------
void appendNote(int64_t value) {
    if (blocks.empty() || blocks.back().size() >= NOTES_PER_BLOCK)
        blocks.emplace_back();
    blocks.back().push_back(value);
    rebuildBlockOffsets();
}

// ----------------- Shrink File -----------------
void shrinkFileIfNeeded() {
    while (!blocks.empty() && blocks.back().empty())
        blocks.pop_back();
    rebuildBlockOffsets();

    int64_t neededBytes = blocks.size() * BLOCK_SIZE_BYTES;
    if (neededBytes < mapped_bytes) remap(neededBytes);
}