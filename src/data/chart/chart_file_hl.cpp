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
static int64_t* data = nullptr;
static int64_t  length = 0;          // logical element count
static int64_t  mapped_length = 0;   // actual mapped element count (for munmap)

#ifdef _WIN32
static HANDLE hFile = INVALID_HANDLE_VALUE;
static HANDLE hMap  = NULL;
#else
static int fd = -1;
#endif

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
static bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap)  { CloseHandle(hMap);    hMap  = NULL;    }

    LARGE_INTEGER newSize;
    newSize.QuadPart = (LONGLONG)(newLength * sizeof(int64_t));

    // Resize file
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile)) {
        length = mapped_length = 0;
        return false;
    }

    // If file is now zero-length, keep it unmapped but succeed
    if (newLength == 0) {
        data = nullptr;
        length = mapped_length = 0;
        return true;
    }

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) {
        length = mapped_length = 0;
        return false;
    }

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) {
        CloseHandle(hMap); hMap = NULL;
        length = mapped_length = 0;
        return false;
    }
#else
    // Unmap previous view using the size that was actually mapped
    if (data && mapped_length > 0) {
        munmap((void*)data, (size_t)mapped_length * sizeof(int64_t));
        data = nullptr;
    }

    // Resize file
    if (ftruncate(fd, (off_t)(newLength * sizeof(int64_t))) == -1) {
        length = mapped_length = 0;
        return false;
    }

    // If zero-length, succeed without mapping
    if (newLength == 0) {
        data = nullptr;
        length = mapped_length = 0;
        return true;
    }

    void* p = mmap(nullptr, (size_t)newLength * sizeof(int64_t),
                   PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        data = nullptr;
        length = mapped_length = 0;
        return false;
    }
    data = (int64_t*)p;
#endif

    length = (int64_t)newLength;
    mapped_length = (int64_t)newLength;
    return true;
}

// -----------------------------------------------------------------------------
// API
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);

#ifdef _WIN32
    hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;

    LARGE_INTEGER fileSize; 
    if (!GetFileSizeEx(hFile, &fileSize)) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; return; }
    int64_t fileLen = (int64_t)(fileSize.QuadPart / (LONGLONG)sizeof(int64_t));

    // Map (handles zero length)
    if (!remap((size_t)fileLen)) throw std::runtime_error("failed to map file");
#else
    fd = open(path, O_RDWR | O_CREAT, 0644);
    if (fd == -1) throw std::runtime_error("failed to open file");

    struct stat st;
    if (fstat(fd, &st) == -1) throw std::runtime_error("failed to stat file");
    int64_t fileLen = (int64_t)(st.st_size / (off_t)sizeof(int64_t));

    if (!remap((size_t)fileLen)) throw std::runtime_error("failed to map file");
#endif
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
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap)  { CloseHandle(hMap);    hMap  = NULL;    }
    if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
    if (data && mapped_length > 0) {
        munmap((void*)data, (size_t)mapped_length * sizeof(int64_t)); // use mapped_length!
        data = nullptr;
    }
    if (fd != -1) { close(fd); fd = -1; }
#endif
    length = 0;
    mapped_length = 0;
}

// -----------------------------------------------------------------------------
// Insert / Remove
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(insertNote)(int64_t index, int64_t value) {
    if (index < 0 || index > length) throw std::out_of_range("index out of range");

    int64_t old_length = length;
    if (!remap((size_t)(length + 1))) throw std::runtime_error("failed to resize file");

    if (index < old_length) {
        memmove(&data[index + 1], &data[index],
                (size_t)(old_length - index) * sizeof(int64_t));
    }
    data[index] = value;
}

HL_PRIM void HL_NAME(removeNote)(int64_t index) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");

    if (index < length - 1) {
        memmove(&data[index], &data[index + 1],
                (size_t)(length - index - 1) * sizeof(int64_t));
    }
    if (!remap((size_t)(length - 1))) throw std::runtime_error("failed to shrink file");
}

// -----------------------------------------------------------------------------
// Batch insert: Array<Int64> from Haxe / HashLink
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(insertNotes)(int64_t startIndex, varray* values) {
    if (startIndex < 0 || startIndex > length) throw std::out_of_range("index out of range");
    if (!values) return;

    int64_t insert_count = (int64_t)values->size;
    if (insert_count <= 0) return;

    int64_t* src = hl_aptr(values, int64_t); // pointer to Array<Int64> storage

    int64_t old_length = length;
    if (!remap((size_t)(length + insert_count))) throw std::runtime_error("failed to resize file");

    if (startIndex < old_length) {
        memmove(&data[startIndex + insert_count], &data[startIndex],
                (size_t)(old_length - startIndex) * sizeof(int64_t));
    }
    memcpy(&data[startIndex], src, (size_t)insert_count * sizeof(int64_t));
}

// -----------------------------------------------------------------------------
// Haxe bindings
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64)
DEFINE_PRIM(_VOID, removeNote, _I64)
DEFINE_PRIM(_VOID, insertNotes, _I64 _ARR)