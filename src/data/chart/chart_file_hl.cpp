#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <string>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// ============================================================================
// Memory-mapped file handling
// ============================================================================
int64_t* data = nullptr;
int64_t length = 0;
#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }
    LARGE_INTEGER newSize; newSize.QuadPart = newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile)) return false;
    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;
    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) { CloseHandle(hMap); hMap = NULL; return false; }
#else
    if (data) { munmap(data, length * sizeof(int64_t)); data = nullptr; }
    if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) return false;
    data = (int64_t*)mmap(nullptr, newLength * sizeof(int64_t),
                          PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { data = nullptr; return false; }
#endif
    length = newLength;
    return true;
}

// ============================================================================
// Chart file operations (HL wrappers)
// ============================================================================
HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);
#ifdef _WIN32
    hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    remap(length);
#else
    fd = open(path, O_RDWR | O_CREAT, 0644);
    struct stat st; fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    remap(length);
#endif
}
HL_PRIM int64_t HL_NAME(getNote)(int64_t idx) { return data[idx]; }
HL_PRIM void HL_NAME(setNote)(int64_t idx, int64_t val) { data[idx] = val; }
HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { return length; }
HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, length * sizeof(int64_t)); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
#endif
    length = 0;
}
HL_PRIM void HL_NAME(insertNote)(int64_t idx, int64_t val) {
    if (idx < 0 || idx > length) throw std::out_of_range("index out of range");
    if (!remap(length + 1)) throw std::runtime_error("resize failed");
    if (idx < length) {
        memmove(&data[idx + 1], &data[idx], (length - idx) * sizeof(int64_t));
    }
    data[idx] = val;
}
HL_PRIM void HL_NAME(removeNote)(int64_t idx) {
    if (idx < 0 || idx >= length) throw std::out_of_range("index out of range");
    if (idx < length - 1) {
        memmove(&data[idx], &data[idx + 1], (length - idx - 1) * sizeof(int64_t));
    }
    if (!remap(length - 1)) throw std::runtime_error("shrink failed");
}

// ============================================================================
// Thingy taken from `data.chart.MetaNote`'s main property formula.
// ============================================================================
inline int64_t extractTime(int64_t note)     { return (note >> 23) & 0x1FFFFFFFFFFLL; }

// -----------------------------------------------------------------------------
// Windows cache detection
// -----------------------------------------------------------------------------
#ifdef _WIN32
int64_t detectCacheWindows(int level) {
    DWORD bufferSize = 0;
    GetLogicalProcessorInformation(nullptr, &bufferSize); // get buffer size
    std::vector<SYSTEM_LOGICAL_PROCESSOR_INFORMATION> buffer(bufferSize / sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION));
    if (!GetLogicalProcessorInformation(buffer.data(), &bufferSize))
        return (level == 1 ? 32*1024 : level == 2 ? 256*1024 : 8*1024*1024);

    for (auto& info : buffer) {
        if (info.Relationship == RelationCache) {
            CACHE_DESCRIPTOR& c = info.Cache;
            if (c.Level == level)
                return c.Size;
        }
    }
    return (level == 1 ? 32*1024 : level == 2 ? 256*1024 : 8*1024*1024);
}
#else
// -----------------------------------------------------------------------------
// Linux cache detection
// -----------------------------------------------------------------------------
#include <fstream>
#include <string>
int64_t detectCacheLinux(int level) {
    std::string path = "/sys/devices/system/cpu/cpu0/cache/index" + std::to_string(level) + "/size";
    std::ifstream f(path);
    if (!f.is_open()) return (level == 1 ? 32*1024 : level == 2 ? 256*1024 : 8*1024*1024);
    std::string val;
    f >> val;
    f.close();
    int64_t size = 0;
    if (val.back() == 'K' || val.back() == 'k') {
        val.pop_back();
        size = std::stoll(val) * 1024;
    } else if (val.back() == 'M' || val.back() == 'm') {
        val.pop_back();
        size = std::stoll(val) * 1024 * 1024;
    } else {
        size = std::stoll(val);
    }
    return size;
}
#endif

// -----------------------------------------------------------------------------
// Detect cache size by level (1,2,3)
// -----------------------------------------------------------------------------
int64_t detectCache(int level) {
#ifdef _WIN32
    return detectCacheWindows(level);
#else
    return detectCacheLinux(level);
#endif
}

// -----------------------------------------------------------------------------
// Adaptive block size selection
// -----------------------------------------------------------------------------
int64_t chooseBlockSize(int64_t arrayLen) {
    int64_t l1 = detectCache(1) / sizeof(int64_t);
    int64_t l2 = detectCache(2) / sizeof(int64_t);
    int64_t l3 = detectCache(3) / sizeof(int64_t);

    if (arrayLen <= l1) return l1 / 2;
    if (arrayLen <= l2) return l2 / 2;
    return l3 / 4;
}

// ============================================================================
// Batch insert/remove
// ============================================================================
// Why the fuck are these two functions slower than their hxcpp version GRAAAAAAAAAAH this is why hxcpp is superior in performance
// Edit: I had to calculate the correct length by putting a separate int64_t argument in place. I can't believe hashlink's `vbyte*` was actually a pointer of an `unsigned char`.
HL_PRIM void HL_NAME(insertNotes)(vbyte* arr, int64_t len) {
    unsigned long long* ptr = (unsigned long long*)arr;
    //int64_t len = sizeof(ptr) / sizeof(int64_t);
    //printf("%s\n", std::to_string(len).c_str());
    std::vector<int64_t> newNotes(ptr, ptr + len);
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t insertCount = newNotes.size();
    int64_t newLen = oldLen + insertCount;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    int64_t blockSize = chooseBlockSize(oldLen + insertCount);
    std::vector<int64_t> tempBlock(blockSize); // L1/L2/L3-friendly scratch

    int64_t i = 0, j = 0, k = 0;

    while (i < oldLen || j < insertCount) {
        int64_t curOldBlock = ((oldLen - i) < blockSize) ? (oldLen - i) : blockSize;
        int64_t curNewBlock = ((insertCount - j) < blockSize) ? (insertCount - j) : blockSize;

        // Copy current old block into scratch
        if (curOldBlock > 0) std::memcpy(tempBlock.data(), data + i, curOldBlock * sizeof(int64_t));

        int64_t ii = 0, jj = j;

        while (ii < curOldBlock && jj < j + curNewBlock) {
            int64_t tTime = extractTime(tempBlock[ii]);
            int64_t dTime = extractTime(newNotes[jj]);
            data[k++] = (tTime <= dTime) ? tempBlock[ii++] : newNotes[jj++];
        }

        while (ii < curOldBlock) data[k++] = tempBlock[ii++];
        while (jj < j + curNewBlock) data[k++] = newNotes[jj++];

        i += curOldBlock;
        j += curNewBlock;
    }

    length = newLen;
}

HL_PRIM void HL_NAME(removeNotes)(vbyte* arr, int64_t len) {
    unsigned long long* ptr = (unsigned long long*)arr;
    //int64_t len = sizeof(ptr) / sizeof(int64_t);
    //printf("%s\n", std::to_string(len).c_str());
    std::vector<int64_t> toRemove(ptr, ptr + len);
    if (toRemove.empty() || length == 0) return;

    int64_t write = 0;
    int64_t j = 0;

    int64_t blockSize = chooseBlockSize(length);
    const int64_t n = length;
    const int64_t m = toRemove.size();

    for (int64_t blockStart = 0; blockStart < n; blockStart += blockSize) {
        int64_t blockEnd = ((blockStart + blockSize) < n) ? (blockStart + blockSize) : n;

        for (int64_t i = blockStart; i < blockEnd; ++i) {
            if (j < m && data[i] == toRemove[j]) {
                ++j; // skip
            } else {
                if (write != i) data[write] = data[i];
                ++write;
            }
        }
    }

    if (write != length) {
        if (!remap(write)) throw std::runtime_error("failed to shrink file after removeNotes");
        length = write;
    }
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64)
DEFINE_PRIM(_VOID, removeNote, _I64)
DEFINE_PRIM(_VOID, insertNotes, _BYTES _I64)
DEFINE_PRIM(_VOID, removeNotes, _BYTES _I64)