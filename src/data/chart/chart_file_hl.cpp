#define HL_NAME(n) chart_file_##n

#include <hl.h>
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

// ---------------- Ultra-fast deferred operations ----------------
static int64_t deferredOps[1048576][3];
static int64_t opCount = 0;
static bool isDirty = false;
static int64_t netChange = 0;

// -----------------------------------------------------------------------------
// Memory-mapping helpers
// -----------------------------------------------------------------------------
static bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }

    LARGE_INTEGER newSize;
    newSize.QuadPart = newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
        return false;

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;

    data = static_cast<int64_t*>(MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0));
    if (!data) { CloseHandle(hMap); hMap = NULL; return false; }

#else
    if (data) { munmap(data, length * sizeof(int64_t)); data = nullptr; }
    if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) return false;

    data = static_cast<int64_t*>(
        mmap(nullptr, newLength * sizeof(int64_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
    );
    if (data == MAP_FAILED) { data = nullptr; return false; }
#endif
    length = newLength;
    return true;
}

// -----------------------------------------------------------------------------
// Optimized deferred flush
// -----------------------------------------------------------------------------
static void flushDeferred() {
    if (!isDirty || opCount == 0) return;

    netChange = 0;
    for (int64_t i = 0; i < opCount; ++i)
        netChange += deferredOps[i][2] ? 1 : -1;

    int64_t finalLength = length + netChange;
    if (finalLength < 0) finalLength = 0;

    if (!remap(finalLength))
        throw std::runtime_error("failed to resize for deferred operations");

    // Sort descending by index
    for (int64_t i = 0; i < opCount - 1; ++i) {
        for (int64_t j = i + 1; j < opCount; ++j) {
            if (deferredOps[i][0] < deferredOps[j][0]) {
                for (int k = 0; k < 3; ++k) {
                    int64_t tmp = deferredOps[i][k];
                    deferredOps[i][k] = deferredOps[j][k];
                    deferredOps[j][k] = tmp;
                }
            }
        }
    }

    for (int64_t i = 0; i < opCount; ++i) {
        int64_t idx = deferredOps[i][0];
        int64_t val = deferredOps[i][1];
        bool isInsert = deferredOps[i][2];

        if (isInsert) {
            if (idx < length) {
                int64_t moveCount = length - idx;
                memmove(&data[idx + 1], &data[idx], moveCount * sizeof(int64_t));
            }
            data[idx] = val;
        } else { // remove
            if (idx < length - 1) {
                int64_t moveCount = length - idx - 1;
                memmove(&data[idx], &data[idx + 1], moveCount * sizeof(int64_t));
            }
            data[length - 1] = 0;
        }
    }

    length = finalLength;
    opCount = 0;
    isDirty = false;
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
    length = fileSize.QuadPart / sizeof(int64_t);

#else
    fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd == -1) throw std::runtime_error("failed to open file");

    struct stat st;
    if (fstat(fd, &st) == -1) throw std::runtime_error("failed to stat file");
    length = st.st_size / sizeof(int64_t);
#endif

    if (!remap(length)) throw std::runtime_error("failed to map file");

    memset(deferredOps, 0, sizeof(deferredOps));
    opCount = 0;
    isDirty = false;
    netChange = 0;
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t idx) {
    if (idx < 0 || idx >= length) throw std::out_of_range("index out of range");
    return data[idx];
}

HL_PRIM void HL_NAME(setNote)(int64_t idx, int64_t val) {
    if (idx < 0 || idx >= length) throw std::out_of_range("index out of range");
    data[idx] = val;
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) {
    return length + (isDirty ? netChange : 0);
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data);
    if (hMap) CloseHandle(hMap);
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
    data = nullptr; hMap = NULL; hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, length * sizeof(int64_t));
    if (fd != -1) close(fd);
    data = nullptr; fd = -1;
#endif
    length = 0;
    memset(deferredOps, 0, sizeof(deferredOps));
    opCount = 0;
    isDirty = false;
    netChange = 0;
}

// ---------------- FASTEST insert/remove ----------------
HL_PRIM void HL_NAME(insertNote)(int64_t idx, int64_t val, bool autoflush) {
    if (idx < 0 || idx > HL_NAME(getLength)(_NO_ARG)) throw std::out_of_range("index out of range");

    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount][0] = idx;
        deferredOps[opCount][1] = val;
        deferredOps[opCount][2] = 1;
        opCount++; isDirty = true;
    } else {
        flushDeferred();
        deferredOps[0][0] = idx;
        deferredOps[0][1] = val;
        deferredOps[0][2] = 1;
        opCount = 1; isDirty = true;
    }
}

HL_PRIM void HL_NAME(removeNote)(int64_t idx, bool autoflush) {
    if (idx < 0 || idx >= HL_NAME(getLength)(_NO_ARG)) throw std::out_of_range("index out of range");

    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount][0] = idx;
        deferredOps[opCount][1] = 0;
        deferredOps[opCount][2] = 0;
        opCount++; isDirty = true;
    } else {
        flushDeferred();
        deferredOps[0][0] = idx;
        deferredOps[0][1] = 0;
        deferredOps[0][2] = 0;
        opCount = 1; isDirty = true;
    }
}

// -----------------------------------------------------------------------------
// Haxe Bindings
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64, getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64, getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64 _BOOL)
DEFINE_PRIM(_VOID, removeNote, _I64 _BOOL)