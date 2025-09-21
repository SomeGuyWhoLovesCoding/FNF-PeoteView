#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <string>

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
// MappedFile class - encapsulates mmap / CreateFileMapping
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
        if (hFile == INVALID_HANDLE_VALUE) {
            hFile = INVALID_HANDLE_VALUE;
            return false;
        }

        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(hFile, &fileSize)) {
            close();
            return false;
        }

        // If file is empty and initialLength > 0, resize it
        length = fileSize.QuadPart / sizeof(int64_t);
        if (length == 0 && initialLength > 0) {
            if (!resize(initialLength)) {
                close();
                return false;
            }
        } else {
            if (!remap(length)) {
                close();
                return false;
            }
        }

#else
        fd = ::open(path, O_RDWR | O_CREAT, 0644);
        if (fd == -1) {
            fd = -1;
            return false;
        }

        struct stat st;
        if (fstat(fd, &st) == -1) {
            close();
            return false;
        }

        length = st.st_size / sizeof(int64_t);
        if (length == 0 && initialLength > 0) {
            if (!resize(initialLength)) {
                close();
                return false;
            }
        } else {
            if (!remap(length)) {
                close();
                return false;
            }
        }
#endif
        return true;
    }

    void close() {
#ifdef _WIN32
        if (data) { UnmapViewOfFile(data); data = nullptr; }
        if (hMap) { CloseHandle(hMap); hMap = NULL; }
        if (hFile != INVALID_HANDLE_VALUE) {
            CloseHandle(hFile);
            hFile = INVALID_HANDLE_VALUE;
        }
#else
        if (data) { munmap(data, length * sizeof(int64_t)); data = nullptr; }
        if (fd != -1) {
            ::close(fd);
            fd = -1;
        }
#endif
        length = 0;
    }

    bool resize(size_t newLength) {
        return remap(newLength);
    }

    int64_t* raw() { return data; }
    const int64_t* raw() const { return data; }
    int64_t size() const { return length; }

private:
    bool remap(size_t newLength) {
#ifdef _WIN32
        if (data) { UnmapViewOfFile(data); data = nullptr; }
        if (hMap) { CloseHandle(hMap); hMap = NULL; }

        LARGE_INTEGER newSize;
        newSize.QuadPart = newLength * sizeof(int64_t);
        if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) ||
            !SetEndOfFile(hFile)) {
            return false;
        }

        hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
        if (!hMap) return false;

        data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
        if (!data) {
            CloseHandle(hMap); hMap = NULL;
            return false;
        }
#else
        if (data) {
            munmap(data, length * sizeof(int64_t));
            data = nullptr;
        }

        if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) return false;

        void* mapped = mmap(nullptr,
                            newLength * sizeof(int64_t),
                            PROT_READ | PROT_WRITE,
                            MAP_SHARED,
                            fd,
                            0);
        if (mapped == MAP_FAILED) {
            data = nullptr;
            return false;
        }

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
// Global state + API (same as your original)
// ============================================================================
static MappedFile gFile;

int64_t* __restrict data = nullptr;
int64_t length = 0;

// ------------------------ L1 Cache Detection + Prefetch ------------------------
static size_t gL1CacheSize = 32 * 1024; // fallback default
static size_t gPrefetchDist = 16;       // precomputed prefetch distance

size_t getL1CacheSize() {
#if defined(_WIN32)
    DWORD bufferSize = 0;
    GetLogicalProcessorInformation(nullptr, &bufferSize);
    std::vector<uint8_t> buffer(bufferSize);
    PSYSTEM_LOGICAL_PROCESSOR_INFORMATION info = reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION>(buffer.data());
    if (!GetLogicalProcessorInformation(info, &bufferSize)) return 32 * 1024;

    size_t l1Size = 32 * 1024; // default
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
    return 32 * 1024; // fallback
#endif
}

bool remap(size_t newLength) {
    bool ok = gFile.resize(newLength);
    data = gFile.raw();
    length = gFile.size();
    return ok;
}

// ------------------------ Extract Time ------------------------
inline int64_t extractTime(int64_t note) {
    return (note >> 23) & 0x1FFFFFFFFFFLL;
}

// ------------------------ Chart API ------------------------
void loadChart(const char* inFile) {
    if (!gFile.open(inFile))
        throw std::runtime_error("Failed to open chart file");

    data = gFile.raw();
    length = gFile.size();

    // Detect L1 cache once and precompute prefetch distance
    gL1CacheSize = getL1CacheSize();
    gPrefetchDist = gL1CacheSize / sizeof(int64_t) / 4;
}

void destroyChart() {
    gFile.close();
    data = nullptr;
    length = 0;
}

int64_t getNote(int64_t atIndex) { return data[atIndex]; }
void setNote(int64_t atIndex, int64_t value) { data[atIndex] = value; }
int64_t getLength() { return length; }

void insertNote(int64_t index, int64_t value) {
    if (index < 0 || index > length) throw std::out_of_range("index out of range");
    if (!remap(length + 1)) throw std::runtime_error("failed to resize file");
    if (index < length) {
        memmove(&data[index + 1], &data[index], (length - index) * sizeof(int64_t));
    }
    data[index] = value;
}

void removeNote(int64_t index) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    if (index < length - 1) {
        memmove(&data[index], &data[index + 1], (length - index - 1) * sizeof(int64_t));
    }
    if (!remap(length - 1)) throw std::runtime_error("failed to shrink file");
}

// ------------------------ Insert Notes with Prefetch ------------------------
void insertNotes(std::vector<int64_t> newNotes) {
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t k = newNotes.size();
    int64_t newLen = oldLen + k;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    int64_t* __restrict writePtr = data + newLen - 1;
    int64_t* __restrict dataPtr  = data + oldLen - 1;
    int64_t* __restrict newPtr   = newNotes.data() + k - 1;

    while (dataPtr >= data && newPtr >= newNotes.data()) {
        if ((dataPtr - data) > gPrefetchDist)
            __builtin_prefetch(dataPtr - gPrefetchDist, 0, 1);
        if ((newPtr - newNotes.data()) > gPrefetchDist)
            __builtin_prefetch(newPtr - gPrefetchDist, 0, 1);

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
        if ((newPtr - newNotes.data()) > gPrefetchDist)
            __builtin_prefetch(newPtr - gPrefetchDist, 0, 1);
        *writePtr-- = *newPtr--;
    }
    length = newLen;
}

// ------------------------ Remove Notes with Prefetch ------------------------
void removeNotes(std::vector<int64_t> notesToRemove) {
    if (notesToRemove.empty()) return;

    int64_t* __restrict readPtr   = data;
    int64_t* __restrict writePtr  = data;
    int64_t* __restrict endPtr    = data + length;
    int64_t* __restrict removePtr = notesToRemove.data();
    int64_t* __restrict removeEnd = notesToRemove.data() + notesToRemove.size();

    while (readPtr < endPtr) {
        if ((readPtr - data) + gPrefetchDist < length)
            __builtin_prefetch(readPtr + gPrefetchDist, 0, 1);
        if ((removePtr - notesToRemove.data()) + gPrefetchDist < notesToRemove.size())
            __builtin_prefetch(removePtr + gPrefetchDist, 0, 1);

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
        if (!remap(newLength))
            throw std::runtime_error("failed to shrink file after removeNotes");
        length = newLength;
    }
}
