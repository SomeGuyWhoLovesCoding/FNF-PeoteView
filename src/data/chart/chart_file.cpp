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

// ============================================================================
// MappedFile
// ============================================================================
class MappedFile {
    static constexpr int64_t BUFFER_SIZE = 1024 * 1024; // 1 MB
    static constexpr int64_t ELEMENTS_PER_BUFFER =
        BUFFER_SIZE / sizeof(int64_t);

public:
    MappedFile() = default;
    ~MappedFile() { close(); }

    bool open(const char* path) {
#ifdef _WIN32
        hFile = CreateFileA(
            path,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ,
            NULL,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            NULL
        );
        if (hFile == INVALID_HANDLE_VALUE)
            return false;

        LARGE_INTEGER size;
        if (!GetFileSizeEx(hFile, &size))
            return false;

        if (size.QuadPart % sizeof(int64_t) != 0)
            return false;

        file_length = size.QuadPart / sizeof(int64_t);
        return remap(0);
#else
        fd = ::open(path, O_RDWR);
        if (fd == -1)
            return false;

        struct stat st;
        if (fstat(fd, &st) == -1)
            return false;

        if (st.st_size % sizeof(int64_t) != 0)
            return false;

        file_length = st.st_size / sizeof(int64_t);
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
            hMap = nullptr;
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
        mapped_size = 0;
        current_offset = 0;
    }

    int64_t get(int64_t index) {
        ensureMapped(index);
        return data[index - current_offset];
    }

    void set(int64_t index, int64_t value) {
        ensureMapped(index);
        data[index - current_offset] = value;
    }

    int64_t size() const { return file_length; }

private:
    void ensureMapped(int64_t index) {
        if (index < 0 || index >= file_length)
            throw std::out_of_range("Index out of range");

        if (index < current_offset ||
            index >= current_offset + mapped_size) {

            int64_t newOffset =
                (index / ELEMENTS_PER_BUFFER) * ELEMENTS_PER_BUFFER;

            if (!remap(newOffset))
                throw std::runtime_error("Remap failed");
        }
    }

    bool remap(int64_t offset) {
        mapped_size = std::min<int64_t>(
            ELEMENTS_PER_BUFFER,
            file_length - offset
        );

#ifdef _WIN32
        if (data) UnmapViewOfFile(data);
        if (hMap) CloseHandle(hMap);

        hMap = CreateFileMapping(
            hFile,
            NULL,
            PAGE_READWRITE,
            0,
            0,
            NULL
        );
        if (!hMap)
            return false;

        LARGE_INTEGER off;
        off.QuadPart = offset * sizeof(int64_t);

        data = (int64_t*)MapViewOfFile(
            hMap,
            FILE_MAP_READ | FILE_MAP_WRITE,
            off.HighPart,
            off.LowPart,
            mapped_size * sizeof(int64_t)
        );
        if (!data)
            return false;
#else
        if (data)
            munmap(data, mapped_size * sizeof(int64_t));

        off_t off = offset * sizeof(int64_t);
        size_t size = mapped_size * sizeof(int64_t);

        data = (int64_t*)mmap(
            nullptr,
            size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            off
        );

        if (data == MAP_FAILED) {
            data = nullptr;
            return false;
        }
#endif

        current_offset = offset;
        return true;
    }

private:
    int64_t* data = nullptr;
    int64_t file_length = 0;
    int64_t mapped_size = 0;
    int64_t current_offset = 0;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap  = nullptr;
#else
    int fd = -1;
#endif
};

// ============================================================================
// Global API
// ============================================================================
static MappedFile gFile;
static int64_t gLength = 0;

void loadChart(const char* path) {
    if (!gFile.open(path))
        throw std::runtime_error("Failed to open chart file");
    gLength = gFile.size();
}

void destroyChart() {
    gFile.close();
    gLength = 0;
}

int64_t getNote(int64_t index) {
    return gFile.get(index);
}

void setNote(int64_t index, int64_t value) {
    gFile.set(index, value);
}

int64_t getLength() {
    return gLength;
}
