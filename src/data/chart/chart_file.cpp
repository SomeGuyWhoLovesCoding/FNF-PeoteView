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
int64_t mapped_length = 0;  // Track actual mapped size

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

// ---------------- Memory-mapping helpers ----------------
static bool remap(size_t newLength) {
    // Clean up existing mapping with CORRECT size
#ifdef _WIN32
    if (data) { 
        UnmapViewOfFile(data); 
        data = nullptr; 
    }
    if (hMap) { 
        CloseHandle(hMap); 
        hMap = NULL; 
    }

    LARGE_INTEGER newSize; 
    newSize.QuadPart = newLength * sizeof(int64_t);
    
    // Resize file
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile)) {
        return false;
    }

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) { 
        CloseHandle(hMap); 
        hMap = NULL; 
        return false; 
    }

#else
    // CRITICAL FIX: Use mapped_length, not length for cleanup
    if (data && mapped_length > 0) { 
        munmap(data, mapped_length * sizeof(int64_t)); 
        data = nullptr; 
    }
    
    // Resize file
    if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) {
        return false;
    }

    data = (int64_t*)mmap(nullptr, newLength * sizeof(int64_t),
                          PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { 
        data = nullptr; 
        return false; 
    }
#endif
    
    length = newLength;
    mapped_length = newLength;  // Track what we actually mapped
    return true;
}

// ---------------- Load / Destroy ----------------
void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    
    LARGE_INTEGER fileSize; 
    GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    mapped_length = length;
    remap(length);
#else
    fd = open(inFile, O_RDWR | O_CREAT, 0644);
    if (fd == -1) return;
    
    struct stat st; 
    fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    mapped_length = length;
    remap(length);
#endif
}

int64_t getNote(int64_t atIndex) { 
    if (atIndex < 0 || atIndex >= length) return 0;  // Bounds check
    return data[atIndex]; 
}

void setNote(int64_t atIndex, int64_t value) { 
    if (atIndex < 0 || atIndex >= length) return;   // Bounds check
    data[atIndex] = value; 
}

int64_t getLength() { return length; }

void destroyChart() {
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
    if (data && mapped_length > 0) {
        munmap(data, mapped_length * sizeof(int64_t));  // Use mapped_length!
        data = nullptr;
    }
    if (fd != -1) {
        close(fd); 
        fd = -1;
    }
#endif
    length = 0;
    mapped_length = 0;
}

// ---------------- Insert/Remove with proper cleanup ----------------
void insertNote(int64_t index, int64_t value) {
    if (index < 0 || index > length) {
        throw std::out_of_range("index out of range");
    }
    
    // Store old data temporarily if we need to preserve it
    int64_t old_length = length;
    
    if (!remap(length + 1)) {
        throw std::runtime_error("failed to resize file");
    }
    
    // Move existing data to make room
    if (index < old_length) {
        memmove(&data[index + 1], &data[index], (old_length - index) * sizeof(int64_t));
    }
    
    data[index] = value;
}

void removeNote(int64_t index) {
    if (index < 0 || index >= length) {
        throw std::out_of_range("index out of range");
    }
    
    // Move data to fill the gap
    if (index < length - 1) {
        memmove(&data[index], &data[index + 1], (length - index - 1) * sizeof(int64_t));
    }
    
    if (!remap(length - 1)) {
        throw std::runtime_error("failed to shrink file");
    }
}

// ---------------- Alternative: Batch operations ----------------
void insertNotes(int64_t startIndex, const std::vector<int64_t>& values) {
    if (startIndex < 0 || startIndex > length) {
        throw std::out_of_range("index out of range");
    }
    
    int64_t old_length = length;
    int64_t insert_count = values.size();
    
    if (!remap(length + insert_count)) {
        throw std::runtime_error("failed to resize file");
    }
    
    // Move existing data
    if (startIndex < old_length) {
        memmove(&data[startIndex + insert_count], &data[startIndex], 
                (old_length - startIndex) * sizeof(int64_t));
    }
    
    // Copy new values
    memcpy(&data[startIndex], values.data(), insert_count * sizeof(int64_t));
}