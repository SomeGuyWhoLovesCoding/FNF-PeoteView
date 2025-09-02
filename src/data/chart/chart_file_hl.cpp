#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <algorithm>

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
int64_t length = 0;           // Current number of notes
int64_t reservedLength = 0;   // Capacity (used only on Windows)

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
LPVOID reservedBase = nullptr;
#else
int fd = -1;
size_t mappedSize = 0;
#endif

// -----------------------------------------------------------------------------
// Memory-mapping helpers
// -----------------------------------------------------------------------------
#ifdef _WIN32
static bool reserveSpace(size_t reserveSize) {
    reservedBase = VirtualAlloc(nullptr, reserveSize * sizeof(int64_t), MEM_RESERVE, PAGE_READWRITE);
    if (!reservedBase) return false;
    reservedLength = reserveSize;
    return true;
}

static bool remap(size_t newLength) {
    if (newLength > reservedLength) {
        size_t newReserve = std::max(newLength, reservedLength * 2);
        LPVOID newBase = VirtualAlloc(nullptr, newReserve * sizeof(int64_t), MEM_RESERVE, PAGE_READWRITE);
        if (!newBase) return false;
        if (data) {
            memcpy(newBase, data, length * sizeof(int64_t));
            UnmapViewOfFile(data);
        }
        if (hMap) CloseHandle(hMap);
        reservedBase = newBase;
        reservedLength = newReserve;
    }

    LARGE_INTEGER newSize;
    newSize.QuadPart = newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
        return false;

    if (!data) {
        hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
        if (!hMap) return false;

        data = (int64_t*)MapViewOfFileEx(hMap, FILE_MAP_ALL_ACCESS, 0, 0, newLength * sizeof(int64_t), reservedBase);
        if (!data) { CloseHandle(hMap); hMap = NULL; return false; }
    }

    length = newLength;
    return true;
}
#else
static bool remap(size_t newLength) {
    if (data) {
        if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) return false;
        void* newData = mremap(data, mappedSize * sizeof(int64_t), newLength * sizeof(int64_t), MREMAP_MAYMOVE);
        if (newData == MAP_FAILED) return false;
        data = (int64_t*)newData;
    } else {
        if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) return false;
        data = (int64_t*)mmap(nullptr, newLength * sizeof(int64_t),
                              PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (data == MAP_FAILED) { data = nullptr; return false; }
    }
    length = newLength;
    mappedSize = newLength;
    return true;
}
#endif

// -----------------------------------------------------------------------------
// Load / Destroy
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(loadChart)(vstring* inFile, int64_t prealloc) {
#ifdef _WIN32
    hFile = CreateFileW((LPCWSTR)inFile->bytes, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;

    reserveSpace(prealloc);

    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    remap(length);
#else
    fd = open(inFile->bytes, O_RDWR | O_CREAT, 0644);
    if (fd == -1) return;

    struct stat st; fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    mappedSize = length;
    remap(length > 0 ? length : prealloc);
#endif
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
    if (reservedBase) { VirtualFree(reservedBase, 0, MEM_RELEASE); reservedBase = nullptr; }
    reservedLength = 0;
#else
    if (data) munmap(data, mappedSize * sizeof(int64_t)); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
    mappedSize = 0;
#endif
    length = 0;
}

// -----------------------------------------------------------------------------
// Insert / Remove (batched single-note wrappers)
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(insertNotes)(int64_t index, HL_NAMED_ARRAY(int64_t, values)) {
    if (index < 0 || index > length) return;
    size_t batchSize = values.size;
    if (batchSize == 0) return;

    remap(length + batchSize);

    if (index < length - batchSize) {
        memmove(&data[index + batchSize], &data[index], (length - batchSize - index) * sizeof(int64_t));
    }
    memcpy(&data[index], values.data, batchSize * sizeof(int64_t));
}

HL_PRIM void HL_NAME(removeNotes)(int64_t index, int64_t count) {
    if (index < 0 || index >= length) return;
    if (count == 0) return;
    if (index + count > length) count = length - index;

    if (index + count < length) {
        memmove(&data[index], &data[index + count], (length - index - count) * sizeof(int64_t));
    }

    remap(length - count);
}

HL_PRIM void HL_NAME(insertNote)(int64_t index, int64_t value) {
    HL_NAME(insertNotes)(index, HL_ARRAY_SINGLE(value));
}

HL_PRIM void HL_NAME(removeNote)(int64_t index) {
    HL_NAME(removeNotes)(index, 1);
}

// -----------------------------------------------------------------------------
// Access
// -----------------------------------------------------------------------------
HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) {
    if (atIndex < 0 || atIndex >= length) return 0;
    return data[atIndex];
}

HL_PRIM void HL_NAME(setNote)(int64_t atIndex, int64_t value) {
    if (atIndex < 0 || atIndex >= length) return;
    data[atIndex] = value;
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) {
    return length;
}

// -----------------------------------------------------------------------------
// Register
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING _I64);
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG);
DEFINE_PRIM(_VOID, insertNotes, _I64 _ARR_I64);
DEFINE_PRIM(_VOID, removeNotes, _I64 _I64);
DEFINE_PRIM(_VOID, insertNote, _I64 _I64);
DEFINE_PRIM(_VOID, removeNote, _I64);
DEFINE_PRIM(_I64, getNote, _I64);
DEFINE_PRIM(_VOID, setNote, _I64 _I64);
DEFINE_PRIM(_I64, getLength, _NO_ARG);
