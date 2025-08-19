#define HL_NAME(n) chart_file_##n

#include <hl.h>

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

// ---------------- Dynamic chunk size ----------------
/**
 * PS. Most modern computers these days are made with more than 1gb of ram but we'll just call it there so
**/
size_t getDynamicChunkSize() {
	size_t chunk = 16 * 1024 * 1024; // fallback 16MB
#ifdef _WIN32
	MEMORYSTATUSEX memStatus = {};
	memStatus.dwLength = sizeof(memStatus);
	if (GlobalMemoryStatusEx(&memStatus)) {
		size_t avail = memStatus.ullAvailPhys;
		chunk = avail / 4; // use 25% of available memory
	}
#else
	long pages = sysconf(_SC_AVPHYS_PAGES);
	long pageSize = sysconf(_SC_PAGESIZE);
	if (pages > 0 && pageSize > 0) {
		size_t avail = pages * pageSize;
		chunk = avail / 4; // 25% of available memory
	}
#endif
	if (chunk < 1024 * sizeof(int64_t)) chunk = 1024 * sizeof(int64_t); // minimum 1024 elements
	return chunk;
}

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

// ---------------- Load / Destroy ----------------
HL_PRIM void HL_NAME(loadChart)(vstring *inFile) {
	printf("Oh hey you're here\n");
	const char* string = hl_to_utf8(inFile->bytes);
#ifdef _WIN32
	hFile = CreateFileA(string, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
						OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
	if (hFile == INVALID_HANDLE_VALUE) return;
	LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
	length = fileSize.QuadPart / sizeof(int64_t);
	remap(length);
#else
	fd = open(string, O_RDWR | O_CREAT, 0644);
	struct stat st; fstat(fd, &st);
	length = st.st_size / sizeof(int64_t);
	remap(length);
#endif
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) { return data[atIndex]; }
HL_PRIM void HL_NAME(setNote)(int64_t atIndex, int64_t value) { data[atIndex] = value; }
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

/**
 * All of this is simply for when the chart editor arrives.
 * But, for now, this is completely untested and I highly recommend that you don't use it.
 * Unless you want to experiment. Just be careful.
**/

// ---------------- Optimized single insert ----------------
HL_PRIM void HL_NAME(insertNote)(int64_t atIndex, int64_t value) {
	if (atIndex < 0 || atIndex > length) throw std::out_of_range("Index out of range");

	size_t oldLen = length;
	if (!remap(oldLen + 1)) throw std::runtime_error("Failed to grow file");

	size_t chunkSize = getDynamicChunkSize() / sizeof(int64_t);
	int64_t remaining = oldLen - atIndex;

	// Shift data in chunks
	while (remaining > 0) {
		size_t chunk = (remaining > chunkSize) ? chunkSize : remaining;
		memmove(&data[atIndex + 1 + remaining - chunk],
				&data[atIndex + remaining - chunk],
				chunk * sizeof(int64_t));
		remaining -= chunk;
	}

	data[atIndex] = value;
}

// ---------------- Optimized single remove ----------------
HL_PRIM void HL_NAME(removeNote)(int64_t atIndex) {
	if (atIndex < 0 || atIndex >= length) throw std::out_of_range("Index out of range");

	size_t chunkSize = getDynamicChunkSize() / sizeof(int64_t);
	int64_t remaining = length - atIndex - 1;

	// Shift data in chunks
	while (remaining > 0) {
		size_t chunk = (remaining > chunkSize) ? chunkSize : remaining;
		memmove(&data[atIndex + remaining - chunk],
				&data[atIndex + 1 + remaining - chunk],
				chunk * sizeof(int64_t));
		remaining -= chunk;
	}

	if (!remap(length - 1)) throw std::runtime_error("Failed to shrink file");
}

// ---------------- Chunked batch insert ----------------
HL_PRIM void HL_NAME(insertNotes)(int64_t atIndex, varray* values) {
	int64_t* array = hl_aptr(values, int64_t);

	if (atIndex < 0 || atIndex > length) throw std::out_of_range("Index out of range");
	size_t n = values->size;
	if (n == 0) return;

	size_t oldLen = length;
	if (!remap(oldLen + n)) throw std::runtime_error("Failed to grow file");

	size_t chunkSize = getDynamicChunkSize() / sizeof(int64_t);
	int64_t remaining = oldLen - atIndex;

	while (remaining > 0) {
		size_t chunk = (remaining > chunkSize) ? chunkSize : remaining;
		memmove(&data[atIndex + n + remaining - chunk],
				&data[atIndex + remaining - chunk],
				chunk * sizeof(int64_t));
		remaining -= chunk;
	}

	memcpy(&data[atIndex], array, n * sizeof(int64_t));
}

// ---------------- Chunked batch remove ----------------
HL_PRIM void HL_NAME(removeNotes)(int64_t atIndex, size_t count) {
	if (atIndex < 0 || atIndex + (int64_t)count > length) throw std::out_of_range("Index out of range");
	if (count == 0) return;

	size_t chunkSize = getDynamicChunkSize() / sizeof(int64_t);
	int64_t remaining = length - atIndex - count;

	while (remaining > 0) {
		size_t chunk = (remaining > chunkSize) ? chunkSize : remaining;
		memmove(&data[atIndex + remaining - chunk],
				&data[atIndex + count + remaining - chunk],
				chunk * sizeof(int64_t));
		remaining -= chunk;
	}

	if (!remap(length - count)) throw std::runtime_error("Failed to shrink file");
}

DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64, getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64, getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64)
DEFINE_PRIM(_VOID, removeNote, _I64 _I64)
DEFINE_PRIM(_VOID, insertNotes, _I64 _ARR)
DEFINE_PRIM(_VOID, removeNotes, _I64 _I64)