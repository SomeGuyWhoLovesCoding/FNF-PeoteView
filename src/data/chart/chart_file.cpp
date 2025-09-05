#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>

#include <thread>
#include <future>
#include <atomic>

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
// Thingy taken from `data.chart.MetaNote`'s main properties' formula.
// ============================================================================
inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

// -----------------------------------------------------------------------------
// Windows cache detection
// -----------------------------------------------------------------------------
#ifdef _WIN32
int64_t detectCacheWindows(int level) {
    DWORD bufferSize = 0;
    GetLogicalProcessorInformation(nullptr, &bufferSize); // get buffer size
    std::vector<SYSTEM_LOGICAL_PROCESSOR_INFORMATION> buffer(bufferSize / sizeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION));
    if (!GetLogicalProcessorInformation(buffer.data(), &bufferSize))
        return (level == 1 ? 32*1024 : level == 2 ? 256*1024 : 8*1024*1024);

    for (auto& info : buffer) {
        if (info.Relationship == RelationCache) {
            CACHE_DESCRIPTOR& c = info.Cache;
            if ((level == 1 && c.Level == 1) ||
                (level == 2 && c.Level == 2) ||
                (level == 3 && c.Level == 3))
                return c.Size;
        }
    }
    return (level == 1 ? 32*1024 : level == 2 ? 256*1024 : 8*1024*1024);
}
#else
// -----------------------------------------------------------------------------
// Linux cache detection
// -----------------------------------------------------------------------------
#include <fstream>
#include <string>
int64_t detectCacheLinux(int level) {
    std::string path = "/sys/devices/system/cpu/cpu0/cache/index" + std::to_string(level) + "/size";
    std::ifstream f(path);
    if (!f.is_open()) return (level == 1 ? 32*1024 : level == 2 ? 256*1024 : 8*1024*1024);
    std::string val;
    f >> val;
    f.close();
    int64_t size = 0;
    if (val.back() == 'K' || val.back() == 'k') {
        val.pop_back();
        size = std::stoll(val) * 1024;
    } else if (val.back() == 'M' || val.back() == 'm') {
        val.pop_back();
        size = std::stoll(val) * 1024 * 1024;
    } else {
        size = std::stoll(val);
    }
    return size;
}
#endif

// -----------------------------------------------------------------------------
// Detect cache size by level (1,2,3)
// -----------------------------------------------------------------------------
int64_t detectCache(int level) {
#ifdef _WIN32
    return detectCacheWindows(level);
#else
    return detectCacheLinux(level);
#endif
}

// -----------------------------------------------------------------------------
// Adaptive block size selection
// -----------------------------------------------------------------------------
int64_t chooseBlockSize(int64_t arrayLen) {
    int64_t l1 = detectCache(1) / sizeof(int64_t);
    int64_t l2 = detectCache(2) / sizeof(int64_t);
    int64_t l3 = detectCache(3) / sizeof(int64_t);

    if (arrayLen <= l1) return l1 / 2;
    if (arrayLen <= l2) return l2 / 2;
    return l3 / 4;
}

// ============================================================================
// Adaptive insertNotes
// ============================================================================
void insertNotes(std::vector<int64_t> newNotes) {
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t insertCount = newNotes.size();
    int64_t newLen = oldLen + insertCount;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    int64_t blockSize = chooseBlockSize(oldLen + insertCount);
    std::vector<int64_t> tempBlock(blockSize); // L1/L2/L3-friendly scratch

    int64_t i = 0, j = 0, k = 0;

    while (i < oldLen || j < insertCount) {
        int64_t curOldBlock = ((oldLen - i) < blockSize) ? (oldLen - i) : blockSize;
        int64_t curNewBlock = ((insertCount - j) < blockSize) ? (insertCount - j) : blockSize;

        // Copy current old block into scratch
        if (curOldBlock > 0) std::memcpy(tempBlock.data(), data + i, curOldBlock * sizeof(int64_t));

        int64_t ii = 0, jj = j;

        while (ii < curOldBlock && jj < j + curNewBlock) {
            int64_t tTime = extractTime(tempBlock[ii]);
            int64_t dTime = extractTime(newNotes[jj]);
            data[k++] = (tTime <= dTime) ? tempBlock[ii++] : newNotes[jj++];
        }

        while (ii < curOldBlock) data[k++] = tempBlock[ii++];
        while (jj < j + curNewBlock) data[k++] = newNotes[jj++];

        i += curOldBlock;
        j += curNewBlock;
    }

    length = newLen;
}

// ============================================================================
// Adaptive removeNotes
// ============================================================================
void removeNotes(std::vector<int64_t> notesToRemove) {
    if (notesToRemove.empty() || length == 0) return;

    int64_t write = 0;
    int64_t j = 0;

    int64_t blockSize = chooseBlockSize(length);
    const int64_t n = length;
    const int64_t m = notesToRemove.size();

    for (int64_t blockStart = 0; blockStart < n; blockStart += blockSize) {
        int64_t blockEnd = ((blockStart + blockSize) < n) ? (blockStart + blockSize) : n;

        for (int64_t i = blockStart; i < blockEnd; ++i) {
            if (j < m && data[i] == notesToRemove[j]) {
                ++j; // skip
            } else {
                if (write != i) data[write] = data[i];
                ++write;
            }
        }
    }

    if (write != length) {
        if (!remap(write)) throw std::runtime_error("failed to shrink file after removeNotes");
        length = write;
    }
}