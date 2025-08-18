#define HL_NAME(n) chart_file_##n

#include <hl.h>

#include <iostream>
#include <vector>
#include <cstdio>
#include <cstdint>

#define _FILE_OFFSET_BITS 64

std::vector<int64_t> data;
FILE* file = nullptr;
int64_t length = 0;

HL_PRIM void HL_NAME(loadChart)(vbyte* inFile) {
	const char* string = hl_aptr(inFile, const char);

	file = fopen(string, "rb");
	if (!file) {
		std::cerr << "Failed to open file: " << string << "\n";
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

HL_PRIM int64_t HL_NAME(getNote)(int64_t atIndex) {
	if (atIndex < 0 || atIndex >= length) {
		throw std::out_of_range("Index out of range");
	}
	return data[atIndex];
}

HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) {
	return length;
}

HL_PRIM void HL_NAME(destroy)(_NO_ARG) {
	data.clear();
	length = 0;
}

DEFINE_PRIM(_VOID, loadChart, _BYTES)
DEFINE_PRIM(_I64, getNote, _I64)
DEFINE_PRIM(_I64, getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroy, _NO_ARG)