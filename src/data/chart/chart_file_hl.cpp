#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <algorithm>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// ============================================================================
// NUMA-aware allocator (same as vanilla)
// ============================================================================
#ifdef _WIN32
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
void numaFree(int64_t* ptr, size_t) {
    if (ptr) VirtualFree(ptr, 0, MEM_RELEASE);
}
#else
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
    if (posix_memalign(&mem, 64, bytes) != 0 || !mem) throw std::bad_alloc();
    return static_cast<int64_t*>(mem);
}
void numaFree(int64_t* ptr, size_t) {
    if (ptr) free(ptr);
}
#endif

// ============================================================================
// Persistent scratch buffer
// ============================================================================
int64_t* scratchBuf = nullptr;
size_t scratchCap = 0;
void ensureScratch(size_t needed) {
    if (needed <= scratchCap) return;
    if (scratchBuf) { numaFree(scratchBuf, scratchCap); scratchBuf = nullptr; scratchCap = 0; }
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

// ============================================================================
// Thingy taken from `data.chart.MetaNote`'s main property formula.
// ============================================================================
inline int64_t extractTime(int64_t note)     { return (note >> 23) & 0x1FFFFFFFFFFLL; }

// ============================================================================
// Batch insert/remove
// ============================================================================
HL_PRIM void HL_NAME(insertNotes)(vbyte* arr) {
    int64_t* ptr = arr;
    std::vector<int64_t> newNotes(ptr, ptr + arr->size);
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t insCount = newNotes.size();
    int64_t newLen = oldLen + insCount;

    if (!remap(newLen)) throw std::runtime_error("resize failed");

    ensureScratch(oldLen + insCount);
    int64_t* oldCopy = scratchBuf;
    memcpy(oldCopy, data, oldLen * sizeof(int64_t));
    int64_t* newCopy = scratchBuf + oldLen;
    memcpy(newCopy, newNotes.data(), insCount * sizeof(int64_t));

    int64_t i = 0, j = 0, k = 0;
    while (i < oldLen && j < insCount) {
        int64_t tTime = extractTime(oldCopy[i]);
        int64_t dTime = extractTime(newCopy[j]);
        data[k++] = (tTime <= dTime) ? oldCopy[i++] : newCopy[j++];
    }
    while (i < oldLen) data[k++] = oldCopy[i++];
    while (j < insCount) data[k++] = newCopy[j++];

    length = newLen;
}

HL_PRIM void HL_NAME(removeNotes)(vbyte* arr) {
    int64_t* ptr = arr;
    std::vector<int64_t> toRemove(ptr, ptr + arr->size);
    if (toRemove.empty() || length == 0) return;

    int64_t write = 0, j = 0;
    for (int64_t i = 0; i < length; ++i) {
        if (j < (int64_t)toRemove.size() && data[i] == toRemove[j]) {
            ++j; // skip
        } else {
            if (write != i) data[write] = data[i];
            ++write;
        }
    }
    if (write != length) {
        if (!remap(write)) throw std::runtime_error("shrink failed in removeNotes");
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
DEFINE_PRIM(_VOID, insertNotes, _BYTES)
DEFINE_PRIM(_VOID, removeNotes, _BYTES)
