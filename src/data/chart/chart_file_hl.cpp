#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <string>
#include <algorithm>

#ifdef _WIN32
#include <windows.h>
#else
#include <fstream>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// ============================================================================
// MappedFile class (updated version)
// ============================================================================
class MappedFile {
public:
    MappedFile() = default;
    ~MappedFile() { close(); }

    bool open(const char* path, size_t initialLength = 0) {
        close(); // in case it's already open

#ifdef _WIN32
        hFile = CreateFileA(path,
                            GENERIC_READ | GENERIC_WRITE,
                            FILE_SHARE_READ,
                            NULL,
                            OPEN_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL,
                            NULL);
        if (hFile == INVALID_HANDLE_VALUE) return false;

        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(hFile, &fileSize)) { close(); return false; }

        length = fileSize.QuadPart / sizeof(int64_t);
        if (length == 0 && initialLength > 0) {
            if (!resize(initialLength)) { close(); return false; }
        } else {
            if (!remap(length)) { close(); return false; }
        }

#else
        fd = ::open(path, O_RDWR | O_CREAT, 0644);
        if (fd == -1) return false;

        struct stat st;
        if (fstat(fd, &st) == -1) { close(); return false; }

        length = st.st_size / sizeof(int64_t);
        if (length == 0 && initialLength > 0) {
            if (!resize(initialLength)) { close(); return false; }
        } else {
            if (!remap(length)) { close(); return false; }
        }
#endif
        return true;
    }

    void close() {
#ifdef _WIN32
        if (data) { UnmapViewOfFile(data); data = nullptr; }
        if (hMap) { CloseHandle(hMap); hMap = NULL; }
        if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
        if (data) { munmap(data, length * sizeof(int64_t)); data = nullptr; }
        if (fd != -1) { ::close(fd); fd = -1; }
#endif
        length = 0;
    }

    bool resize(size_t newLength) { return remap(newLength); }
    int64_t* raw() { return data; }
    const int64_t* raw() const { return data; }
    int64_t size() const { return length; }

private:
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

        void* mapped = mmap(nullptr, newLength * sizeof(int64_t), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mapped == MAP_FAILED) { data = nullptr; return false; }

        data = static_cast<int64_t*>(mapped);
#endif
        length = newLength;
        return true;
    }

    int64_t* __restrict data = nullptr;
    int64_t length = 0;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap  = NULL;
#else
    int fd = -1;
#endif
};

// ============================================================================
// Global state
// ============================================================================
static MappedFile gFile;
int64_t* __restrict data = nullptr;
int64_t length = 0;

// ------------------------ L1 Cache Detection ------------------------
static size_t gL1CacheSize = 32 * 1024; // fallback default
static size_t gPrefetchDist = 16;

static size_t getL1CacheSize() {
#if defined(_WIN32)
    DWORD bufferSize = 0;
    GetLogicalProcessorInformation(nullptr, &bufferSize);
    std::vector<uint8_t> buffer(bufferSize);
    PSYSTEM_LOGICAL_PROCESSOR_INFORMATION info = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION>(buffer.data());
    if (!GetLogicalProcessorInformation(info, &bufferSize)) return 32 * 1024;

    size_t l1Size = 32 * 1024;
    DWORD count = bufferSize / sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION);
    for (DWORD i = 0; i < count; ++i) {
        if (info[i].Relationship == RelationCache &&
            info[i].Cache.Level == 1 &&
            info[i].Cache.Type == CacheData) {
            l1Size = info[i].Cache.Size;
            break;
        }
    }
    return l1Size;
#else
    std::ifstream file("/sys/devices/system/cpu/cpu0/cache/index0/size");
    std::string line;
    if (file.is_open() && std::getline(file, line)) {
        size_t size = 0;
        char unit = line.back();
        size_t value = std::stoul(line);
        if (unit == 'K' || unit == 'k') size = value * 1024;
        else if (unit == 'M' || unit == 'm') size = value * 1024 * 1024;
        else size = value;
        return size;
    }
    return 32 * 1024;
#endif
}

bool remap(size_t newLength) {
    bool ok = gFile.resize(newLength);
    data = gFile.raw();
    length = gFile.size();
    return ok;
}

// ------------------------ Extract Time ------------------------
inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

// ============================================================================
// HL API functions
// ============================================================================
HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);
    if (!gFile.open(path)) throw std::runtime_error("Failed to open chart file");

    data = gFile.raw();
    length = gFile.size();

    gL1CacheSize = getL1CacheSize();
    gPrefetchDist = gL1CacheSize / sizeof(int64_t) / 4;
}

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) { gFile.close(); data = nullptr; length = 0; }

HL_PRIM int64_t HL_NAME(getNote)(int64_t idx) { return data[idx]; }
HL_PRIM void HL_NAME(setNote)(int64_t idx, int64_t val) { data[idx] = val; }
HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { return length; }

HL_PRIM void HL_NAME(insertNote)(int64_t idx, int64_t val) {
    if (idx < 0 || idx > length) throw std::out_of_range("index out of range");
    if (!remap(length + 1)) throw std::runtime_error("resize failed");
    if (idx < length) memmove(&data[idx + 1], &data[idx], (length - idx) * sizeof(int64_t));
    data[idx] = val;
}

HL_PRIM void HL_NAME(removeNote)(int64_t idx) {
    if (idx < 0 || idx >= length) throw std::out_of_range("index out of range");
    if (idx < length - 1) memmove(&data[idx], &data[idx + 1], (length - idx - 1) * sizeof(int64_t));
    if (!remap(length - 1)) throw std::runtime_error("shrink failed");
}

HL_PRIM void HL_NAME(insertNotes)(vbyte* arr, int64_t len) {
    auto* ptr = reinterpret_cast<int64_t*>(arr);
    std::vector<int64_t> newNotes(ptr, ptr + len);
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t k = newNotes.size();
    int64_t newLen = oldLen + k;
    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    int64_t* __restrict writePtr = data + newLen - 1;
    int64_t* __restrict dataPtr  = data + oldLen - 1;
    int64_t* __restrict newPtr   = newNotes.data() + k - 1;

    while (dataPtr >= data && newPtr >= newNotes.data()) {
        if ((dataPtr - data) > gPrefetchDist) __builtin_prefetch(dataPtr - gPrefetchDist, 0, 1);
        if ((newPtr - newNotes.data()) > gPrefetchDist) __builtin_prefetch(newPtr - gPrefetchDist, 0, 1);

        int64_t timeData = extractTime(*dataPtr);
        int64_t timeNew  = extractTime(*newPtr);

        if (timeData > timeNew) {
            if (writePtr != dataPtr) *writePtr = *dataPtr;
            --dataPtr;
        } else {
            *writePtr = *newPtr;
            --newPtr;
        }
        --writePtr;
    }

    while (newPtr >= newNotes.data()) {
        if ((newPtr - newNotes.data()) > gPrefetchDist) __builtin_prefetch(newPtr - gPrefetchDist, 0, 1);
        *writePtr-- = *newPtr--;
    }
    length = newLen;
}

HL_PRIM void HL_NAME(removeNotes)(vbyte* arr, int64_t len) {
    auto* ptr = reinterpret_cast<int64_t*>(arr);
    std::vector<int64_t> notesToRemove(ptr, ptr + len);
    if (notesToRemove.empty() || length == 0) return;

    int64_t* __restrict readPtr   = data;
    int64_t* __restrict writePtr  = data;
    int64_t* __restrict endPtr    = data + length;
    int64_t* __restrict removePtr = notesToRemove.data();
    int64_t* __restrict removeEnd = notesToRemove.data() + notesToRemove.size();

    while (readPtr < endPtr) {
        if ((readPtr - data) + gPrefetchDist < length) __builtin_prefetch(readPtr + gPrefetchDist, 0, 1);
        if ((removePtr - notesToRemove.data()) + gPrefetchDist < notesToRemove.size()) __builtin_prefetch(removePtr + gPrefetchDist, 0, 1);

        if (removePtr < removeEnd && *readPtr == *removePtr) {
            ++removePtr;
        } else {
            if (writePtr != readPtr) *writePtr = *readPtr;
            ++writePtr;
        }
        ++readPtr;
    }

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
