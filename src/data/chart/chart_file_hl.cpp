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
// MappedFile class - encapsulates mmap / CreateFileMapping
// ============================================================================
class MappedFile {
    static constexpr int64_t BUFFER_SIZE = 1048576LL; // 1MB buffer
    static constexpr int64_t ELEMENTS_PER_BUFFER = BUFFER_SIZE / sizeof(int64_t);
    
public:
    MappedFile() = default;
    ~MappedFile() { close(); }

    bool open(const char* path) {
#ifdef _WIN32
        hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ,
                            NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile == INVALID_HANDLE_VALUE) return false;

        LARGE_INTEGER fileSize;
        if (!GetFileSizeEx(hFile, &fileSize)) {
            CloseHandle(hFile);
            hFile = INVALID_HANDLE_VALUE;
            return false;
        }

        if (fileSize.QuadPart % sizeof(int64_t) != 0) {
            CloseHandle(hFile);
            hFile = INVALID_HANDLE_VALUE;
            return false;
        }

        file_length = fileSize.QuadPart / sizeof(int64_t);
        current_offset = 0;
        return remap(0);
#else
        fd = ::open(path, O_RDONLY);
        if (fd == -1) return false;

        struct stat st;
        if (fstat(fd, &st) == -1) {
            ::close(fd);
            fd = -1;
            return false;
        }

        if (st.st_size % sizeof(int64_t) != 0) {
            ::close(fd);
            fd = -1;
            return false;
        }

        file_length = st.st_size / sizeof(int64_t);
        current_offset = 0;
        return remap(0);
#endif
    }

    void close() {
#ifdef _WIN32
        if (data) {
            UnmapViewOfFile(data);
            data = nullptr;
        }
        if (hMap) {
            CloseHandle(hMap);
            hMap = NULL;
        }
        if (hFile != INVALID_HANDLE_VALUE) {
            CloseHandle(hFile);
            hFile = INVALID_HANDLE_VALUE;
        }
#else
        if (data) {
            munmap(data, mapped_size * sizeof(int64_t));
            data = nullptr;
        }
        if (fd != -1) {
            ::close(fd);
            fd = -1;
        }
#endif
        file_length = 0;
        current_offset = 0;
        mapped_size = 0;
    }

    int64_t get(int64_t index) {
        if (index < 0 || index >= file_length) {
            throw std::out_of_range("Index out of range");
        }

        // Check if we need to remap for this index
        if (index < current_offset || index >= current_offset + mapped_size) {
            // Calculate new offset centered around the requested index
            int64_t new_offset = (index / ELEMENTS_PER_BUFFER) * ELEMENTS_PER_BUFFER;
            new_offset = std::max<int64_t>(0LL, new_offset);
            new_offset = std::min<int64_t>(new_offset, file_length - 1);
            
            if (!remap(new_offset)) {
                throw std::runtime_error("Failed to remap file region");
            }
        }

        return data[index - current_offset];
    }

    int64_t* raw() { return data; }
    const int64_t* raw() const { return data; }
    int64_t size() const { return file_length; }
    int64_t currentOffset() const { return current_offset; }
    int64_t currentSize() const { return mapped_size; }

private:
    bool remap(int64_t offset) {
        // Calculate how much we can map from this offset
        mapped_size = std::min<int64_t>(ELEMENTS_PER_BUFFER, file_length - offset);
        if (mapped_size <= 0) return false;

#ifdef _WIN32
        if (data) {
            UnmapViewOfFile(data);
            data = nullptr;
        }
        if (hMap) {
            CloseHandle(hMap);
            hMap = NULL;
        }

        hMap = CreateFileMapping(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
        if (!hMap) return false;

        // Calculate the file offset in bytes
        LARGE_INTEGER file_offset;
        file_offset.QuadPart = offset * sizeof(int64_t);
        
        DWORD size_high = (mapped_size * sizeof(int64_t)) >> 32;
        DWORD size_low = (mapped_size * sizeof(int64_t)) & 0xFFFFFFFF;

        data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_READ, 
                                      file_offset.HighPart, file_offset.LowPart,
                                      mapped_size * sizeof(int64_t));
        if (!data) {
            CloseHandle(hMap);
            hMap = NULL;
            return false;
        }
#else
        if (data) {
            munmap(data, mapped_size * sizeof(int64_t));
            data = nullptr;
        }

        off_t file_offset = offset * sizeof(int64_t);
        size_t map_size = mapped_size * sizeof(int64_t);

        data = (int64_t*)mmap(nullptr, map_size,
                              PROT_READ, MAP_SHARED, fd, file_offset);
        if (data == MAP_FAILED) {
            data = nullptr;
            return false;
        }
#endif

        current_offset = offset;
        return true;
    }

    int64_t* data = nullptr;
    int64_t file_length = 0;
    int64_t current_offset = 0;
    int64_t mapped_size = 0;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap  = NULL;
#else
    int fd = -1;
#endif
};

// ============================================================================
// Global state + HL API
// ============================================================================
static MappedFile gFile;
int64_t length = 0;

HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);
    if (!gFile.open(path))
        throw std::runtime_error("Failed to open chart file");
    length = gFile.size();
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) { return gFile.get(atIndex); }
HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { return length; }

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
    gFile.close();
    length = 0;
}

// ============================================================================
// Haxe bindings
// ============================================================================
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64,  getNote, _I64)
DEFINE_PRIM(_I64,  getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)