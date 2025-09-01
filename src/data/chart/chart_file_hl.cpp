#define HL_NAME(n) chart_file_##n

#include <hl.h>

#include <iostream>
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

// -----------------------------------------------------------------------------
// Helpers
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
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t index) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    return data[index];
}

HL_PRIM void HL_NAME(setNote)(int64_t index, int64_t value) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    data[index] = value;
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { return length; }

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
}

// -----------------------------------------------------------------------------
// Insert / Remove
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(insertNote)(int64_t index, int64_t value) {
    if (index < 0 || index > length) throw std::out_of_range("index out of range");
    if (!remap(length + 1)) throw std::runtime_error("failed to resize file");
    if (index < length) {
        memmove(&data[index + 1], &data[index], (length - index) * sizeof(int64_t));
    }
    data[index] = value;
}

HL_PRIM void HL_NAME(removeNote)(int64_t index) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    if (index < length - 1) {
        memmove(&data[index], &data[index + 1], (length - index - 1) * sizeof(int64_t));
    }
    if (!remap(length - 1)) throw std::runtime_error("failed to shrink file");
}

// -----------------------------------------------------------------------------
// Haxe bindings
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64, getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64, getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64)
DEFINE_PRIM(_VOID, removeNote, _I64 _I64)