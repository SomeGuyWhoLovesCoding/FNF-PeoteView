#include <iostream>
#include <cstdint>
#include <stdexcept>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// Debug toggle
#ifdef DEBUG_CHART
    #define DBG_PRINTF(...)  printf(__VA_ARGS__)
    #define DBG_CERR(x)      (std::cerr << x)
#else
    #define DBG_PRINTF(...)  ((void)0)
    #define DBG_CERR(x)      ((void)0)
#endif

int64_t* data = nullptr;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap = NULL;
#endif

void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ, FILE_SHARE_READ, NULL,
                        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        DBG_CERR("Failed to open file named " << inFile << "\n");
        return;
    }
    DBG_PRINTF("Opened file %s\n", inFile);

    LARGE_INTEGER fileSize;
    if (!GetFileSizeEx(hFile, &fileSize)) {
        DBG_CERR("Failed to get file size\n");
        CloseHandle(hFile);
        hFile = INVALID_HANDLE_VALUE;
        return;
    }

    length = fileSize.QuadPart / sizeof(int64_t);

    hMap = CreateFileMapping(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!hMap) {
        DBG_CERR("Failed to create file mapping\n");
        CloseHandle(hFile);
        hFile = INVALID_HANDLE_VALUE;
        return;
    }

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
    if (!data) {
        DBG_CERR("Failed to map view of file\n");
        CloseHandle(hMap);
        CloseHandle(hFile);
        hMap = NULL;
        hFile = INVALID_HANDLE_VALUE;
    }

#else
    int fd = open(inFile, O_RDONLY);
    if (fd == -1) {
        perror("open");
        return;
    }

    struct stat st;
    if (fstat(fd, &st) == -1) {
        perror("fstat");
        close(fd);
        return;
    }

    length = st.st_size / sizeof(int64_t);

    data = (int64_t*)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        data = nullptr;
        close(fd);
        return;
    }

    close(fd);
#endif
}

int64_t getNote(int64_t atIndex) {
    if (!data || atIndex < 0 || atIndex >= length)
        throw std::out_of_range("Index out of range");
    return data[atIndex];
}

int64_t getLength() {
    return length;
}

void destroyChart() {
    if (!data) return;

#ifdef _WIN32
    UnmapViewOfFile(data);
    data = nullptr;
    if (hMap) { CloseHandle(hMap); hMap = NULL; }
    if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
    munmap(data, length * sizeof(int64_t));
    data = nullptr;
#endif

    length = 0;
}