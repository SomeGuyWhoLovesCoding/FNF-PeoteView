#include <iostream>
#include <vector>
#include <cstdio>
#include <cstdint>

#define _FILE_OFFSET_BITS 64

std::vector<int64_t> data;
FILE* file = nullptr;
int64_t length = 0;

void loadChart(const char* inFile) {
	file = fopen(inFile, "rb");
	if (!file) {
		std::cerr << "Failed to open file: " << inFile << "\n";
		return;
	}

	// Seek to end, get length in int64_t elements
	#if defined(_WIN32)
	_fseeki64(file, 0, SEEK_END);
	length = _ftelli64(file) / sizeof(int64_t);
	_fseeki64(file, 0, SEEK_SET);
	#else
	fseeko(file, 0, SEEK_END);
	length = ftello(file) / sizeof(int64_t);
	fseeko(file, 0, SEEK_SET);
	#endif

	data.resize(length);

	size_t read = fread(data.data(), sizeof(int64_t), length, file);
	if (read != (size_t)length) {
		std::cerr << "Short read: expected " << length << " got " << read << "\n";
	}

	fclose(file);
	file = nullptr;
}

int64_t getNote(int64_t atIndex) {
	if (atIndex < 0 || atIndex >= length) {
		throw std::out_of_range("Index out of range");
	}
	return data[atIndex];
}

int64_t getLength() {
	return length;
}

void destroyChart() {
	data.clear();
	length = 0;
}