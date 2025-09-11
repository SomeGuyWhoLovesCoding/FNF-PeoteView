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

inline int64_t extractTime(int64_t note)     { return (note >> 23) & 0x1FFFFFFFFFFLL; }

HL_PRIM void HL_NAME(insertNotes)(vbyte* arr, int64_t len) {
    unsigned long long* ptr = (unsigned long long*)arr;
    //int64_t len = sizeof(ptr) / sizeof(int64_t);
    //printf("%s\n", std::to_string(len).c_str());
    std::vector<int64_t> newNotes(ptr, ptr + len);
    if (newNotes.empty()) return;

    if (newNotes.empty()) return;

    int64_t* writePtr = data + newLen - 1;
    int64_t* dataPtr  = data + oldLen - 1;
    int64_t* newPtr   = newNotes.data() + k - 1;

    // Backwards merge by extractTime
    while (dataPtr >= data && newPtr >= newNotes.data()) {
        int64_t timeData = extractTime(*dataPtr);
        int64_t timeNew  = extractTime(*newPtr);

        if (timeData > timeNew) {
            if (writePtr != dataPtr) *writePtr = *dataPtr; // skip if already in place
            --dataPtr;
        } else {
            *writePtr = *newPtr;
            --newPtr;
        }
        --writePtr;
    }

    // Copy any remaining newNotes
    while (newPtr >= newNotes.data()) *writePtr-- = *newPtr--;

    length = newLen;
}

HL_PRIM void HL_NAME(removeNotes)(vbyte* arr, int64_t len) {
    unsigned long long* ptr = (unsigned long long*)arr;
    //int64_t len = sizeof(ptr) / sizeof(int64_t);
    //printf("%s\n", std::to_string(len).c_str());
    std::vector<int64_t> notesToRemove(ptr, ptr + len);
    if (toRemove.empty() || length == 0) return;

    int64_t* readPtr  = data;
    int64_t* writePtr = data;
    int64_t* endPtr   = data + length;
    int64_t* removePtr = notesToRemove.data();
    int64_t* removeEnd = notesToRemove.data() + notesToRemove.size();

    while (readPtr < endPtr) {
        if (removePtr < removeEnd && *readPtr == *removePtr) {
            ++removePtr; // skip this note
        } else {
            if (writePtr != readPtr) *writePtr = *readPtr;
            ++writePtr;
        }
        ++readPtr;
    }

    // Shrink file if needed
    int64_t newLength = writePtr - data;
    if (newLength != length) {
        if (!remap(newLength)) throw std::runtime_error("failed to shrink file after removeNotes");
        length = newLength;
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
