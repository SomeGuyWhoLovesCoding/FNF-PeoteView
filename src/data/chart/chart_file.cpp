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

int64_t* data = nullptr;      // pointer to mapped memory
int64_t length = 0;           // number of int64_t elements

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap = NULL;
#endif

void loadChart(const char* inFile) {
	#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
		// There are two more std::cerr's here just in case because this is the first time we call a function onto this file.
        std::cerr << "Failed to open file named ";
		std::cerr << inFile;
		std::cerr << "\n";
        return;
    }
	printf("Created memmap file for %s\n", inFile);

    LARGE_INTEGER fileSize;
    if (!GetFileSizeEx(hFile, &fileSize)) {
        std::cerr << "Failed to get file size\n";
        CloseHandle(hFile);
        hFile = INVALID_HANDLE_VALUE;
        return;
    }
	printf("Got file size for %s\n", inFile);

    length = fileSize.QuadPart / sizeof(int64_t);

    hMap = CreateFileMapping(hFile, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!hMap) {
        std::cerr << "Failed to create file mapping\n";
        CloseHandle(hFile);
        hFile = INVALID_HANDLE_VALUE;
        return;
    }
	printf("Created file mapping for %s\n", inFile);

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0);
    if (!data) {
        std::cerr << "Failed to map view of file\n";
        CloseHandle(hMap);
        CloseHandle(hFile);
        hMap = NULL;
        hFile = INVALID_HANDLE_VALUE;
    }
	printf("Mapped view of file for %s\n", inFile);

	#else
    int fd = open(inFile, O_RDONLY);
    if (fd == -1) {
        perror("open");
        return;
    }
	printf("Opened file successfully\n");

    struct stat st;
    if (fstat(fd, &st) == -1) {
        perror("fstat");
        close(fd);
        return;
    }
	printf("ftatted file successfully\n");

    length = st.st_size / sizeof(int64_t);

    data = (int64_t*)mmap(nullptr, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (data == MAP_FAILED) {
        perror("mmap");
        data = nullptr;
        close(fd);
        return;
    }
	printf("mmap'd view of file successfully\n");

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
	printf("Unmapped view of file successfully\n"); // newlines after the loadChart ones I had to put for loading the chart.
    data = nullptr;
    if (hMap) { CloseHandle(hMap); hMap = NULL; }
    if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
	#else
    munmap(data, length * sizeof(int64_t));
	printf("munmap'd view of file successfully\n");
    data = nullptr;
	#endif

    length = 0;
}