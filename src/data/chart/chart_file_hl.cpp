#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <fstream>
#include <vector>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <algorithm>
#include <filesystem>

// ============================================================================
// BufferedFile: fstream-based equivalent of MappedFile
// ============================================================================
class BufferedFile {
public:
    BufferedFile() = default;
    ~BufferedFile() { close(); }

    bool open(const char* path) {
        close();
        filePath = path;

        file.open(filePath, std::ios::in | std::ios::out | std::ios::binary);
        if (!file.is_open()) {
            // Create new if not existing
            std::ofstream create(filePath, std::ios::binary);
            create.close();
            file.open(filePath, std::ios::in | std::ios::out | std::ios::binary);
        }
        if (!file.is_open()) return false;

        // Load everything into memory buffer
        std::error_code ec;
        std::uintmax_t bytes = std::filesystem::file_size(filePath, ec);
        if (ec) bytes = 0;

        length = bytes / sizeof(int64_t);
        buffer.resize(length);
        if (length > 0) {
            file.read(reinterpret_cast<char*>(buffer.data()), bytes);
        }
        return true;
    }

    void close() {
        flush();
        file.close();
        buffer.clear();
        buffer.shrink_to_fit();
        length = 0;
    }

    bool resize(size_t newLength) {
        flush();
        buffer.resize(newLength, 0);
        length = newLength;
        return true;
    }

    int64_t* raw() { return buffer.data(); }
    int64_t size() const { return length; }

    void flush() {
        if (!file.is_open()) return;
        file.seekp(0, std::ios::beg);
        file.write(reinterpret_cast<const char*>(buffer.data()), buffer.size() * sizeof(int64_t));
        file.flush();
    }

private:
    std::string filePath;
    std::fstream file;
    std::vector<int64_t> buffer;
    size_t length = 0;
};

// ============================================================================
// Global state + Haxe API
// ============================================================================
static BufferedFile gFile;

#ifdef _WIN32
int64_t* data = nullptr;
#else
int64_t*__ data = nullptr;
#endif
int64_t length = 0;

bool remap(size_t newLength) {
    bool ok = gFile.resize(newLength);
    data = gFile.raw();
    length = gFile.size();
    return ok;
}

HL_PRIM void HL_NAME(loadChart)(vstring* inFile) {
    const char* path = hl_to_utf8(inFile->bytes);
    if (!gFile.open(path))
        throw std::runtime_error("Failed to open chart file");
    data = gFile.raw();
    length = gFile.size();
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t idx) { return data[idx]; }
HL_PRIM void HL_NAME(setNote)(int64_t idx, int64_t val) { data[idx] = val; }
HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG) { return length; }

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG) {
    gFile.close();
    data = nullptr;
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

inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

HL_PRIM void HL_NAME(insertNotes)(vbyte* arr, int64_t len) {
#ifdef _WIN32
    unsigned long long* ptr = (unsigned long long*)arr;
#else
    unsigned long long*__ ptr = (unsigned long long*)arr;
#endif

    std::vector<int64_t> newNotes(ptr, ptr + len);
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t k = newNotes.size();
    int64_t newLen = oldLen + k;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

#ifdef _WIN32
    int64_t* writePtr = data + newLen - 1;
    int64_t* dataPtr  = data + oldLen - 1;
    int64_t* newPtr   = newNotes.data() + k - 1;
#else
    int64_t*__ writePtr = data + newLen - 1;
    int64_t*__ dataPtr  = data + oldLen - 1;
    int64_t*__ newPtr   = newNotes.data() + k - 1;
#endif

    while (dataPtr >= data && newPtr >= newNotes.data()) {
        int64_t timeData = extractTime(*dataPtr);
        int64_t timeNew  = extractTime(*newPtr);

        if (timeData > timeNew) {
            if (writePtr != dataPtr) *writePtr = *dataPtr;
            --dataPtr;
        } else {
            *writePtr = *newPtr;
            --newPtr;
        }
        --writePtr;
    }

    while (newPtr >= newNotes.data()) *writePtr-- = *newPtr--;
    length = newLen;
}

HL_PRIM void HL_NAME(removeNotes)(vbyte* arr, int64_t len) {
    unsigned long long* ptr = (unsigned long long*)arr;
    std::vector<int64_t> notesToRemove(ptr, ptr + len);
    if (notesToRemove.empty() || length == 0) return;

    int64_t* readPtr   = data;
    int64_t* writePtr  = data;
    int64_t* endPtr    = data + length;
    int64_t* removePtr = notesToRemove.data();
    int64_t* removeEnd = notesToRemove.data() + notesToRemove.size();

    while (readPtr < endPtr) {
        if (removePtr < removeEnd && *readPtr == *removePtr) {
            ++removePtr;
        } else {
            if (writePtr != readPtr) *writePtr = *readPtr;
            ++writePtr;
        }
        ++readPtr;
    }

    int64_t newLength = writePtr - data;
    if (newLength != length) {
        if (!remap(newLength)) throw std::runtime_error("failed to shrink file after removeNotes");
        length = newLength;
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
DEFINE_PRIM(_VOID, insertNotes, _BYTES _I64)
DEFINE_PRIM(_VOID, removeNotes, _BYTES _I64)