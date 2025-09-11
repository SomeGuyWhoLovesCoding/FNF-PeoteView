#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <immintrin.h>

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
// Chart file operations
// ============================================================================
void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    remap(length);
#else
    fd = open(inFile, O_RDWR | O_CREAT, 0644);
    struct stat st; fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    remap(length);
#endif
}

int64_t getNote(int64_t atIndex) { return data[atIndex]; }
void setNote(int64_t atIndex, int64_t value) { data[atIndex] = value; }
int64_t getLength() { return length; }

void destroyChart() {
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

inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

void insertNotes(std::vector<int64_t> newNotes) {
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t k = newNotes.size();
    int64_t newLen = oldLen + k;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

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

void removeNotes(std::vector<int64_t> notesToRemove) {
    if (notesToRemove.empty()) return;

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
