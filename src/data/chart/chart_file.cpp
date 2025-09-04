#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <algorithm>
#include <unordered_set>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// ============================================================================
// NUMA-aware allocator
// ============================================================================
#ifdef _WIN32
// Windows NUMA allocation (fallback to VirtualAlloc)
static bool windows_try_virtualallocn = true;

int64_t* numaAlloc(size_t count) {
    SIZE_T bytes = count * sizeof(int64_t);

    if (windows_try_virtualallocn) {
        typedef LPVOID (WINAPI *VirtualAllocExNuma_t)(HANDLE, LPVOID, SIZE_T, DWORD, DWORD, DWORD);
        typedef BOOL (WINAPI *GetNumaProcessorNodeEx_t)(const PROCESSOR_NUMBER*, PUSHORT);

        HMODULE hKernel = GetModuleHandleW(L"kernel32.dll");
        if (hKernel) {
            auto fnVAEN = (VirtualAllocExNuma_t)GetProcAddress(hKernel, "VirtualAllocExNuma");
            auto fnGetNode = (GetNumaProcessorNodeEx_t)GetProcAddress(hKernel, "GetNumaProcessorNodeEx");
            if (fnVAEN && fnGetNode) {
                PROCESSOR_NUMBER procNum = {0};
                GetCurrentProcessorNumberEx(&procNum);

                USHORT node = 0;
                if (!fnGetNode(&procNum, &node)) node = 0;

                LPVOID mem = fnVAEN(GetCurrentProcess(), nullptr, bytes,
                                    MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE, (DWORD)node);
                if (mem) return static_cast<int64_t*>(mem);
            }
        }
        windows_try_virtualallocn = false;
    }

    LPVOID mem = VirtualAlloc(nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!mem) throw std::bad_alloc();
    return static_cast<int64_t*>(mem);
}

void numaFree(int64_t* ptr, size_t /*count*/) {
    if (ptr) VirtualFree(ptr, 0, MEM_RELEASE);
}

#else // Linux / POSIX
#include <errno.h>
#include <stdlib.h>
#if defined(__linux__)
#include <numa.h>
#endif

int64_t* numaAlloc(size_t count) {
    size_t bytes = count * sizeof(int64_t);

#if defined(__linux__)
    if (numa_available() != -1) {
        int preferred = numa_preferred();
        void* mem = numa_alloc_onnode(bytes, preferred);
        if (mem) return static_cast<int64_t*>(mem);
    }
#endif

    void* mem = nullptr;
    int rc = posix_memalign(&mem, 64, bytes);
    if (rc != 0 || !mem) throw std::bad_alloc();
    return static_cast<int64_t*>(mem);
}

void numaFree(int64_t* ptr, size_t /*count*/) {
    if (!ptr) return;
#if defined(__linux__)
    if (numa_available() != -1) {
        // If you always allocated with numa_alloc_onnode, call numa_free(ptr, bytes) here.
        // We can’t distinguish malloc vs numa_alloc, so use free().
    }
#endif
    free(ptr);
}
#endif

// ============================================================================
// Persistent scratch buffer
// ============================================================================
int64_t* scratchBuf = nullptr;
size_t scratchCap   = 0;

void ensureScratch(size_t needed) {
    if (needed <= scratchCap) return;

    if (scratchBuf) {
        numaFree(scratchBuf, scratchCap);
        scratchBuf = nullptr;
        scratchCap = 0;
    }

    scratchBuf = numaAlloc(needed);
    scratchCap = needed;
}

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

// ============================================================================
// Stuff taken from `data.chart.MetaNote`'s main properties' formula.
// ============================================================================
inline int64_t extractTime(int64_t note) {
    return (note >> 23) & 0x1FFFFFFFFFFLL;
}

inline int64_t extractLane(int64_t note) {
    return note & 0x3;
}

inline int64_t extractType(int64_t note) {
    return (note >> 2) & 0xF;
}

inline int64_t extractIndex(int64_t note) {
    return (note >> 6) & 0xF;
}

inline int64_t extractDuration(int64_t note) {
    return (note >> 10) & 0x1FFF;
}

// ============================================================================
// Batch insert: forward merge, persistent scratch buffer
// ============================================================================
void insertNotes(std::vector<int64_t> newNotes) {
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t insertCount = newNotes.size();
    int64_t newLen = oldLen + insertCount;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    // Allocate scratch buffer (persistent, never shrink)
    ensureScratch(insertCount); // scratchBuf >= insertCount

    // Copy new notes to scratch
    std::memcpy(scratchBuf, newNotes.data(), insertCount * sizeof(int64_t));

    // Simple forward merge
    int64_t* left = scratchBuf;     // new notes
    int64_t leftSize = insertCount;
    int64_t* right = data;          // existing data
    int64_t rightSize = oldLen;

    int64_t i = 0, j = 0, k = 0;
    while (i < leftSize && j < rightSize) {
        int64_t lt = extractTime(left[i]);
        int64_t rt = extractTime(right[j]);

        uint64_t takeLeft = (uint64_t)(lt <= rt);
        uint64_t takeRight = 1 ^ takeLeft;

        data[k] = left[i] * takeLeft + right[j] * takeRight;
        i += takeLeft;
        j += takeRight;
        ++k;
    }

    while (i < leftSize) data[k++] = left[i++];
    while (j < rightSize) data[k++] = right[j++];

    length = newLen;
}

// ============================================================================
// Batch remove: forward merge, unsorted removeNotes, persistent scratch
// ============================================================================
void removeNotes(std::vector<int64_t> notesToRemove) {
    if (notesToRemove.empty() || length == 0) return;

    // Allocate scratch buffer (persistent, never shrink)
    ensureScratch(notesToRemove.size());

    int64_t* dst = data;
    int64_t* src = data;

    for (int64_t i = 0; i < length; ++i) {
        int64_t note = src[i];
        bool keep = true;

        // Compare against all notes in notesToRemove
        for (size_t j = 0; j < notesToRemove.size(); ++j) {
            int64_t target = notesToRemove[j];
            if (extractTime(note)     == extractTime(target) &&
                extractLane(note)     == extractLane(target) &&
                extractType(note)     == extractType(target) &&
                extractIndex(note)    == extractIndex(target) &&
                extractDuration(note) == extractDuration(target)) {
                keep = false;
                break;
            }
        }

        if (keep) *dst++ = note;
    }

    int64_t newLen = dst - data;
    if (!remap(newLen)) throw std::runtime_error("failed to shrink file");

    length = newLen;
}
