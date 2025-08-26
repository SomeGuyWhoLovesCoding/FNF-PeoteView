#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <vector>
#include <cstdint>
#include <stdexcept>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// -----------------------------------------------------------------------------
// Config
// -----------------------------------------------------------------------------
constexpr int64_t NOTES_PER_BLOCK = 256;
constexpr int64_t BLOCK_SIZE_BYTES = NOTES_PER_BLOCK * sizeof(int64_t) + sizeof(uint16_t);

// -----------------------------------------------------------------------------
// Globals
// -----------------------------------------------------------------------------
int64_t* data = nullptr;
int64_t mapped_bytes = 0;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

// Blocks in memory
std::vector<std::vector<int64_t>> blocks;
std::vector<int64_t> blockOffsets;

// Last-accessed block cache
static size_t lastBlockIndex = 0;
static std::vector<int64_t>* lastBlockPtr = nullptr;

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
static bool remap(int64_t newBytes) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }

    LARGE_INTEGER size; 
    size.QuadPart = newBytes;
    if (!SetFilePointerEx(hFile, size, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
        return false;

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) { CloseHandle(hMap); hMap = NULL; return false; }

#else
    if (data) { munmap(data, mapped_bytes); data = nullptr; }
    if (ftruncate(fd, newBytes) == -1) return false;

    data = (int64_t*)mmap(nullptr, newBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { data = nullptr; return false; }
#endif
    mapped_bytes = newBytes;
    return true;
}

static void rebuildBlockOffsets() {
    blockOffsets.clear();
    int64_t sum = 0;
    for (auto& b : blocks) {
        blockOffsets.push_back(sum);
        sum += b.size();
    }
    length = sum;

    // Reset cache on rebuild
    lastBlockIndex = 0;
    lastBlockPtr = blocks.empty() ? nullptr : &blocks[0];
}

static int64_t findBlock(int64_t index, int64_t& offsetInBlock) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    int64_t left = 0, right = blockOffsets.size() - 1;
    while (left < right) {
        int64_t mid = (left + right + 1) / 2;
        if (blockOffsets[mid] <= index) left = mid;
        else right = mid - 1;
    }
    offsetInBlock = index - blockOffsets[left];
    return left;
}

// -----------------------------------------------------------------------------
// API
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(loadChart)(vstring *inFile) {
    const char* path = hl_to_utf8(inFile->bytes);

#ifdef _WIN32
    hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    mapped_bytes = fileSize.QuadPart;
#else
    fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd == -1) throw std::runtime_error("failed to open file");
    struct stat st; fstat(fd, &st);
    mapped_bytes = st.st_size;
#endif
    if (mapped_bytes == 0) mapped_bytes = BLOCK_SIZE_BYTES;
    if (!remap(mapped_bytes)) throw std::runtime_error("failed to map file");

    blocks.clear();
    int64_t offset = 0;
    while (offset + sizeof(uint16_t) < mapped_bytes) {
        std::vector<int64_t> b;
        int64_t available = (mapped_bytes - offset) / sizeof(int64_t);
        int64_t count = NOTES_PER_BLOCK;
        if (count > available) count = available;
        b.resize(count);
        memcpy(b.data(), (char*)data + offset, count * sizeof(int64_t));
        blocks.push_back(b);
        offset += BLOCK_SIZE_BYTES;
    }

    rebuildBlockOffsets();
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data);
    if (hMap) CloseHandle(hMap);
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
    data = nullptr; hMap = NULL; hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, mapped_bytes);
    if (fd != -1) close(fd);
    data = nullptr; fd = -1;
#endif
    blocks.clear();
    blockOffsets.clear();
    mapped_bytes = 0;
    length = 0;
    lastBlockPtr = nullptr;
    lastBlockIndex = 0;
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t index) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");

    size_t offsetInBlock;
    std::vector<int64_t>* blk;

    // Fast path: use last accessed block
    if (lastBlockPtr && index >= blockOffsets[lastBlockIndex] &&
        index < blockOffsets[lastBlockIndex] + lastBlockPtr->size()) {
        blk = lastBlockPtr;
        offsetInBlock = index - blockOffsets[lastBlockIndex];
    } else {
        lastBlockIndex = findBlock(index, (int64_t&)offsetInBlock);
        blk = &blocks[lastBlockIndex];
        lastBlockPtr = blk;
    }

    return (*blk)[offsetInBlock];
}

HL_PRIM void HL_NAME(setNote)(int64_t index, int64_t value) {
    int64_t offset;
    int64_t blk = findBlock(index, offset);
    blocks[blk][offset] = value;
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { return length; }

// -----------------------------------------------------------------------------
// Insert / Remove / Append / Shrink
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(insertNote)(int64_t index, int64_t value) {
    if (index < 0 || index > length) throw std::out_of_range("index out of range");

    if (index == length) {
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
        std::vector<int64_t> newBlock(b.begin() + NOTES_PER_BLOCK / 2, b.end());
        b.erase(b.begin() + NOTES_PER_BLOCK / 2, b.end());
        if (offsetInBlock > b.size())
            newBlock.insert(newBlock.begin() + (offsetInBlock - b.size()), value);
        else
            b.insert(b.begin() + offsetInBlock, value);
        blocks.insert(blocks.begin() + blk + 1, std::move(newBlock));
    }
    rebuildBlockOffsets();
}

HL_PRIM void HL_NAME(removeNote)(int64_t index) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    int64_t offsetInBlock;
    int64_t blk = findBlock(index, offsetInBlock);
    auto& b = blocks[blk];
    b.erase(b.begin() + offsetInBlock);

    if (b.empty() && blocks.size() > 1)
        blocks.erase(blocks.begin() + blk);

    rebuildBlockOffsets();
}

HL_PRIM void HL_NAME(appendNote)(int64_t value) {
    if (blocks.empty() || blocks.back().size() >= NOTES_PER_BLOCK)
        blocks.emplace_back();
    blocks.back().push_back(value);
    rebuildBlockOffsets();
}

HL_PRIM void HL_NAME(shrinkFileIfNeeded)(_NO_ARG) {
    while (!blocks.empty() && blocks.back().empty())
        blocks.pop_back();
    rebuildBlockOffsets();
    int64_t neededBytes = blocks.size() * BLOCK_SIZE_BYTES;
    if (neededBytes < mapped_bytes) remap(neededBytes);
}

// -----------------------------------------------------------------------------
// Haxe bindings
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_I64, getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64, getLength, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64)
DEFINE_PRIM(_VOID, removeNote, _I64 _I64)
DEFINE_PRIM(_VOID, appendNote, _I64)
DEFINE_PRIM(_VOID, shrinkFileIfNeeded, _NO_ARG)