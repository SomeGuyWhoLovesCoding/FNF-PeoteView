#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <cstdint>
#include <stdexcept>
#include <algorithm>
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
// Globals
// -----------------------------------------------------------------------------
int64_t* data = nullptr;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

// -----------------------------------------------------------------------------
// Deferred operation struct
// -----------------------------------------------------------------------------
struct alignas(16) DeferredOp {
    uint64_t index : 63;   // 63-bit index
    uint64_t isInsert : 1; // 1-bit flag
    int64_t value;         // full 64-bit value
};

DeferredOp deferredOps[1048576];
int64_t opCount   = 0;
bool    isDirty   = false;
int64_t netChange = 0;

// -----------------------------------------------------------------------------
// Memory-mapping helpers
// -----------------------------------------------------------------------------
bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }

    LARGE_INTEGER newSize; newSize.QuadPart = newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
        return false;

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

// -----------------------------------------------------------------------------
// Flush deferred operations
// -----------------------------------------------------------------------------
void flushDeferred() {
    if (!isDirty || opCount == 0) return;

    int64_t finalLength = length + netChange;
    if (finalLength < 0) finalLength = 0;

    if (!remap(finalLength))
        throw std::runtime_error("failed to resize for deferred operations");

    std::sort(deferredOps, deferredOps + opCount,
              [](const DeferredOp &a, const DeferredOp &b) { return a.index > b.index; });

    for (int64_t i = 0; i < opCount; ++i) {
        int64_t idx    = deferredOps[i].index;
        int64_t val    = deferredOps[i].value;
        bool    insert = deferredOps[i].isInsert;

        if (insert) {
            if (idx < length) {
                int64_t moveCount = length - idx;
                memmove(&data[idx + 1], &data[idx], moveCount * sizeof(int64_t));
            }
            data[idx] = val;
        } else {
            if (idx < length - 1) {
                int64_t moveCount = length - idx - 1;
                memmove(&data[idx], &data[idx + 1], moveCount * sizeof(int64_t));
            }
            data[length - 1] = 0;
        }
    }

    length  = finalLength;
    opCount = 0;
    isDirty = false;
    netChange = 0;
}

// -----------------------------------------------------------------------------
// Haxe API
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
#ifdef _WIN32
    hFile = CreateFileW((LPCWSTR)inFile->bytes, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    remap(length);
#else
    fd = open(inFile->bytes, O_RDWR | O_CREAT, 0644);
    struct stat st; fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    remap(length);
#endif

    opCount = 0;
    isDirty = false;
    netChange = 0;
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) {
    if (atIndex < 0 || atIndex >= length) return 0;
    return data[atIndex];
}

HL_PRIM void HL_NAME(setNote)(int64_t atIndex, int64_t value) {
    if (atIndex < 0 || atIndex >= length) return;
    data[atIndex] = value;
}

HL_PRIM int64_t HL_NAME(getLength)() {
    return length + (isDirty ? netChange : 0);
}

HL_PRIM void HL_NAME(destroyChart)() {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, length * sizeof(int64_t)); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
#endif
    length = 0;
    opCount = 0;
    isDirty = false;
    netChange = 0;
}

// -----------------------------------------------------------------------------
// Deferred insert/remove
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(insertNote)(int64_t index, int64_t value, bool autoflush) {
    if (index < 0 || index > HL_NAME(getLength)()) return;

    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount] = {uint64_t(index), 1, value};
        opCount++;
        netChange++;
        isDirty = true;
    } else {
        if (autoflush) {
            deferredOps[opCount] = {uint64_t(index), 1, value};
            netChange++;
            isDirty = true;
        }
        flushDeferred();
        if (!autoflush) {
            deferredOps[0] = {uint64_t(index), 1, value};
            opCount = 1;
            netChange = 1;
            isDirty = true;
        }
    }
}

HL_PRIM void HL_NAME(removeNote)(int64_t index, bool autoflush) {
    if (index < 0 || index >= HL_NAME(getLength)()) return;

    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount] = {uint64_t(index), 0, 0};
        opCount++;
        netChange--;
        isDirty = true;
    } else {
        if (autoflush) {
            deferredOps[opCount] = {uint64_t(index), 0, 0};
            netChange--;
            isDirty = true;
        }
        flushDeferred();
        if (!autoflush) {
            deferredOps[0] = {uint64_t(index), 0, 0};
            opCount = 1;
            netChange = -1;
            isDirty = true;
        }
    }
}

// -----------------------------------------------------------------------------
// Register
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING);
DEFINE_PRIM(_I64,  getNote,  _I64);
DEFINE_PRIM(_VOID, setNote,  _I64 _I64);
DEFINE_PRIM(_I64,  getLength, _NO_ARG);
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG);
DEFINE_PRIM(_VOID, insertNote, _I64 _I64 _BOOL);
DEFINE_PRIM(_VOID, removeNote, _I64 _BOOL);
