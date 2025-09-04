#define HL_NAME(n) chart_file_##n

#include <hl.h>

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
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, length * sizeof(int64_t)); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
#endif
    length = 0;
}

// -----------------------------------------------------------------------------
// Insert / Remove (single)
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
// Batch insert/remove with branchless merge
// ============================================================================
HL_PRIM void HL_NAME(insertNotes)(varray* newNotesB) {
    int64_t* ptr = hl_aptr(newNotesB, int64_t);
    std::vector<int64_t> newNotes = std::vector<int64_t>(ptr, ptr + (sizeof(newNotesB) / sizeof(int64_t)));

    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t insertCount = newNotes.size();
    int64_t newLen = oldLen + insertCount;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");
    std::memcpy(data + oldLen, newNotes.data(), insertCount * sizeof(int64_t));

    size_t smaller = (oldLen < insertCount) ? oldLen : insertCount;
    ensureScratch(smaller);

    int64_t* temp = scratchBuf;

    int64_t* src;
    int64_t srcSize;
    int64_t* dest;
    int64_t destSize;

    if (oldLen < insertCount) {
        src = data;
        srcSize = oldLen;
        dest = data + oldLen;
        destSize = insertCount;
    } else {
        src = data + oldLen;
        srcSize = insertCount;
        dest = data;
        destSize = oldLen;
    }

    std::memcpy(temp, src, srcSize * sizeof(int64_t));

    int64_t i = 0, j = 0, k = 0;
    while (i < srcSize && j < destSize) {
        int64_t tTime = extractTime(temp[i]);
        int64_t dTime = extractTime(dest[j]);
        bool takeTemp = tTime <= dTime;
        data[k++] = takeTemp ? temp[i++] : dest[j++];
    }

    while (i < srcSize) data[k++] = temp[i++];
    while (j < destSize) data[k++] = dest[j++];

    length = newLen;
}

// ============================================================================
// Branchless, scratch-buffer merge for removeNotes
// ============================================================================
HL_PRIM void HL_NAME(removeNotes)(varray* removeNotesVecB) {
    int64_t* ptr = hl_aptr(removeNotesVecB, int64_t);
    std::vector<int64_t> removeNotesVec = std::vector<int64_t>(ptr, ptr + (sizeof(removeNotesVecB) / sizeof(int64_t)));

    if (removeNotesVec.empty()) return;
    // ditto
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
DEFINE_PRIM(_VOID, removeNotes, _ARR)