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
#endif

int64_t* data = nullptr;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

// ---------------- Ultra-fast strategy: Three-element deferred operations ----------------
// Raw int64_t array structure: [1048576][3]
// Element 0: index, Element 1: value, Element 2: operation type (1=insert, 0=remove)
static int64_t deferredOps[1048576][3];
static int64_t opCount = 0;
static bool isDirty = false;

// ---------------- Memory-mapping helpers ----------------
static bool remap(size_t newLength) {
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

static void flushDeferred() {
    if (!isDirty || opCount == 0) return;
    
    // Calculate final size using raw array elements
    int64_t netChange = 0;
    for (int64_t i = 0; i < opCount; ++i) {
        netChange += deferredOps[i][2] ? 1 : -1; // Element 2 contains operation type
    }
    
    int64_t finalLength = length + netChange;
    if (finalLength < 0) finalLength = 0;
    
    // Single remap to final size
    if (!remap(finalLength)) {
        throw std::runtime_error("failed to resize for deferred operations");
    }
    
    // Sort by index (descending) for optimal processing
    for (int64_t i = 0; i < opCount - 1; ++i) {
        for (int64_t j = i + 1; j < opCount; ++j) {
            if (deferredOps[i][0] < deferredOps[j][0]) { // Element 0 contains index
                // Swap all three elements
                for (int k = 0; k < 3; ++k) {
                    int64_t temp = deferredOps[i][k];
                    deferredOps[i][k] = deferredOps[j][k];
                    deferredOps[j][k] = temp;
                }
            }
        }
    }
    
    // Apply operations from highest index to lowest
    for (int64_t i = 0; i < opCount; ++i) {
        int64_t index = deferredOps[i][0];  // Element 0: index
        int64_t value = deferredOps[i][1];  // Element 1: value
        bool isInsert = deferredOps[i][2];  // Element 2: operation type
        
        if (isInsert) {
            if (index < length - 1) {
                // Use fast 8-byte aligned copy
                int64_t* src = &data[index];
                int64_t* dst = &data[index + 1];
                int64_t moveCount = length - index - 1;
                
                // Ultra-fast: copy 8 elements at a time using manual unrolling
                while (moveCount >= 8) {
                    dst[moveCount-1] = src[moveCount-1];
                    dst[moveCount-2] = src[moveCount-2]; 
                    dst[moveCount-3] = src[moveCount-3];
                    dst[moveCount-4] = src[moveCount-4];
                    dst[moveCount-5] = src[moveCount-5];
                    dst[moveCount-6] = src[moveCount-6];
                    dst[moveCount-7] = src[moveCount-7];
                    dst[moveCount-8] = src[moveCount-8];
                    moveCount -= 8;
                }
                // Handle remainder
                while (moveCount > 0) {
                    dst[moveCount-1] = src[moveCount-1];
                    moveCount--;
                }
            }
            data[index] = value;
        } else { // Remove
            if (index < length - 1) {
                // Fast removal with unrolled copy
                int64_t* dst = &data[index];
                int64_t* src = &data[index + 1];
                int64_t moveCount = length - index - 1;
                
                // Copy 8 elements at a time
                while (moveCount >= 8) {
                    dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = src[3];
                    dst[4] = src[4]; dst[5] = src[5]; dst[6] = src[6]; dst[7] = src[7];
                    dst += 8; src += 8; moveCount -= 8;
                }
                // Handle remainder
                while (moveCount > 0) {
                    *dst++ = *src++;
                    moveCount--;
                }
            }
        }
    }
    
    opCount = 0;
    isDirty = false;
}

// ---------------- Load / Destroy ----------------
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
    
    // Clear the three-element array structure
    memset(deferredOps, 0, sizeof(deferredOps));
    opCount = 0;
    isDirty = false;
}

int64_t getNote(int64_t atIndex) { 
    flushDeferred(); // Ensure we're reading current state
    return data[atIndex]; 
}

void setNote(int64_t atIndex, int64_t value) { 
    flushDeferred(); // Ensure consistent state
    data[atIndex] = value; 
}

int64_t getLength() { 
    if (!isDirty) return length;
    
    int64_t change = 0;
    for (int64_t i = 0; i < opCount; ++i) {
        change += deferredOps[i][2] ? 1 : -1; // Element 2 contains operation type
    }
    return length + change;
}

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
    memset(deferredOps, 0, sizeof(deferredOps));
    opCount = 0;
    isDirty = false;
}

// ---------------- FASTEST insert/remove functions ----------------
void insertNote(int64_t index, int64_t value, bool autoflush = false) {
    if (index < 0 || index > getLength()) {
        throw std::out_of_range("index out of range");
    }
    
    // Use raw int64_t array: [0]=index, [1]=value, [2]=operation type
    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount][0] = index;
        deferredOps[opCount][1] = value;
        deferredOps[opCount][2] = 1; // 1 = insert
        opCount++;
        isDirty = true;
    } else {
        // Array full or autoflush requested - flush and add
        flushDeferred();
        deferredOps[0][0] = index;
        deferredOps[0][1] = value;
        deferredOps[0][2] = 1; // 1 = insert
        opCount = 1;
        isDirty = true;
    }
}

void removeNote(int64_t index, bool autoflush = false) {
    if (index < 0 || index >= getLength()) {
        throw std::out_of_range("index out of range");
    }
    
    // Use raw int64_t array: [0]=index, [1]=value, [2]=operation type
    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount][0] = index;
        deferredOps[opCount][1] = 0; // value unused for remove
        deferredOps[opCount][2] = 0; // 0 = remove
        opCount++;
        isDirty = true;
    } else {
        // Array full or autoflush requested - flush and add
        flushDeferred();
        deferredOps[0][0] = index;
        deferredOps[0][1] = 0; // value unused for remove
        deferredOps[0][2] = 0; // 0 = remove
        opCount = 1;
        isDirty = true;
    }
}

// ---------------- Force immediate application ----------------
void sync() {
    flushDeferred();
}

// ---------------- Ultra-fast bulk operations ----------------
void insertNotesInstant(const std::vector<std::pair<int64_t, int64_t>>& indexValuePairs, bool autoflush = false) {
    for (const auto& pair : indexValuePairs) {
        if (opCount < 1048576 && !autoflush) {
            deferredOps[opCount][0] = pair.first;
            deferredOps[opCount][1] = pair.second;
            deferredOps[opCount][2] = 1; // 1 = insert
            opCount++;
        } else {
            flushDeferred();
            deferredOps[0][0] = pair.first;
            deferredOps[0][1] = pair.second;
            deferredOps[0][2] = 1; // 1 = insert
            opCount = 1;
        }
    }
    isDirty = true;
}

void removeNotesInstant(const std::vector<int64_t>& indices, bool autoflush = false) {
    for (int64_t index : indices) {
        if (opCount < 1048576 && !autoflush) {
            deferredOps[opCount][0] = index;
            deferredOps[opCount][1] = 0; // value unused for remove
            deferredOps[opCount][2] = 0; // 0 = remove
            opCount++;
        } else {
            flushDeferred();
            deferredOps[0][0] = index;
            deferredOps[0][1] = 0; // value unused for remove
            deferredOps[0][2] = 0; // 0 = remove
            opCount = 1;
        }
    }
    isDirty = true;
}