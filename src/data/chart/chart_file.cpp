#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#endif

int64_t* data = nullptr;
int64_t length = 0;           // Number of notes currently used
int64_t reservedLength = 0;   // Total reserved capacity in notes

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
LPVOID reservedBase = nullptr;
#else
int fd = -1;
size_t mappedSize = 0;
#endif

// ---------------- Memory-mapping helpers ----------------
#ifdef _WIN32
static bool reserveSpace(size_t reserveSize) {
    reservedBase = VirtualAlloc(
        nullptr,
        reserveSize * sizeof(int64_t),
        MEM_RESERVE,
        PAGE_READWRITE
    );
    if (!reservedBase) return false;
    reservedLength = reserveSize;
    return true;
}

static bool remap(size_t newLength) {
    if (newLength > reservedLength) {
        // Auto-grow reserved space by doubling
        size_t newReserve = newLength;
        size_t maxReserve = reservedLength * 2;
        if (newReserve > maxReserve) newReserve = maxReserve;
        LPVOID newBase = VirtualAlloc(nullptr, newReserve * sizeof(int64_t), MEM_RESERVE, PAGE_READWRITE);
        if (!newBase) return false;

        // Remap old data to new base
        if (data) {
            memcpy(newBase, data, length * sizeof(int64_t));
            UnmapViewOfFile(data);
        }

        if (hMap) CloseHandle(hMap);
        reservedBase = newBase;
        reservedLength = newReserve;
        hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
        if (!hMap) return false;
    }

    // Extend file on disk
    LARGE_INTEGER newSize;
    newSize.QuadPart = newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile)) return false;

    if (!data) {
        hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
        if (!hMap) return false;

        data = (int64_t*)MapViewOfFileEx(
            hMap,
            FILE_MAP_ALL_ACCESS,
            0, 0,
            newLength * sizeof(int64_t),
            reservedBase
        );
        if (!data) { CloseHandle(hMap); hMap = NULL; return false; }
    }

    length = newLength;
    return true;
}
#else
// Linux / Unix version
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

// ---------------- Load / Destroy ----------------
void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;

    reserveSpace(1048576);

    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    remap(length);
#else
    fd = open(inFile, O_RDWR | O_CREAT, 0644);
    if (fd == -1) return;

    struct stat st; fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    mappedSize = length;
    remap(length > 0 ? length : 1048576);
#endif
}

void destroyChart() {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
    if (reservedBase) VirtualFree(reservedBase, 0, MEM_RELEASE); reservedBase = nullptr;
    reservedLength = 0;
#else
    if (data) munmap(data, mappedSize * sizeof(int64_t)); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
    mappedSize = 0;
#endif
    length = 0;
}

// ---------------- Batched insert/remove ----------------
void insertNotes(int64_t index, const std::vector<int64_t>& values) {
    if (index < 0 || index > length) throw std::out_of_range("index out of range");
    size_t batchSize = values.size();
    if (batchSize == 0) return;

    remap(length + batchSize);

    if (index < length - batchSize) {
        memmove(&data[index + batchSize], &data[index], (length - batchSize - index) * sizeof(int64_t));
    }
    memcpy(&data[index], values.data(), batchSize * sizeof(int64_t));
}

void removeNotes(int64_t index, size_t count) {
    if (index < 0 || index >= length) throw std::out_of_range("index out of range");
    if (count == 0) return;
    if (index + count > length) count = length - index;

    if (index + count < length) {
        memmove(&data[index], &data[index + count], (length - index - count) * sizeof(int64_t));
    }

    remap(length - count);
}

// ---------------- Single-note helpers ----------------
void insertNote(int64_t index, int64_t value) {
    insertNotes(index, std::vector<int64_t>{value});
}

void removeNote(int64_t index) {
    removeNotes(index, 1);
}

// ---------------- Access helpers ----------------
int64_t getNote(int64_t atIndex) { return data[atIndex]; }
void setNote(int64_t atIndex, int64_t value) { data[atIndex] = value; }
int64_t getLength() { return length; }
