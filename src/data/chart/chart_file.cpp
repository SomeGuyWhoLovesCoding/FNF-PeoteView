#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <string>
#include <unordered_map>
#include <memory>
#include <cstddef>
#include <new>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// ============================================================================
// MappedFile class - encapsulates mmap / CreateFileMapping
// ============================================================================
class MappedFile {
public:
    MappedFile() = default;
    ~MappedFile() { close(); }

    bool open(const char* path) {
#ifdef _WIN32
        hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ,
                            NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hFile == INVALID_HANDLE_VALUE) return false;

        LARGE_INTEGER fileSize;
        GetFileSizeEx(hFile, &fileSize);
        length = fileSize.QuadPart / sizeof(int64_t);
        return remap(length);
#else
        fd = ::open(path, O_RDWR | O_CREAT, 0644);
        if (fd == -1) return false;

        struct stat st;
        fstat(fd, &st);
        length = st.st_size / sizeof(int64_t);
        return remap(length);
#endif
    }

    void close() {
#ifdef _WIN32
        if (data) UnmapViewOfFile(data);
        data = nullptr;
        if (hMap) CloseHandle(hMap);
        hMap = NULL;
        if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
        hFile = INVALID_HANDLE_VALUE;
#else
        if (data) munmap(data, length * sizeof(int64_t));
        data = nullptr;
        if (fd != -1) ::close(fd);
        fd = -1;
#endif
        length = 0;
    }

    bool resize(size_t newLength) { return remap(newLength); }

    int64_t* raw() { return data; }
    const int64_t* raw() const { return data; }
    int64_t size() const { return length; }

private:
    bool remap(size_t newLength) {
#ifdef _WIN32
        if (data) { UnmapViewOfFile(data); data = nullptr; }
        if (hMap) { CloseHandle(hMap); hMap = NULL; }

        LARGE_INTEGER newSize;
        newSize.QuadPart = newLength * sizeof(int64_t);
        if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
            return false;

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

    int64_t* __restrict data = nullptr;
    int64_t length = 0;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap  = NULL;
#else
    int fd = -1;
#endif
};

// ============================================================================
// Global state + API
// ============================================================================
MappedFile gFile;

// ============================================================================
// Deferred Inserts and Removals optimization technique (unfinished)
// ============================================================================

// ------------------------------
// FileMappedAllocator
// ------------------------------
template <typename T>
class FileMappedAllocator {
public:
    using value_type = T;

    FileMappedAllocator(MappedFile& file) noexcept : file(file) {
        offset = 0;
        base = file.raw();
        capacity = file.size();
        if (!base) throw std::runtime_error("MappedFile not initialized");
    }

    template <typename U>
    FileMappedAllocator(const FileMappedAllocator<U>& other) noexcept
        : file(other.file), offset(other.offset), base(other.base), capacity(other.capacity) {}

    T* allocate(std::size_t n) {
        std::size_t bytes = n * sizeof(T);
        if (offset + bytes > capacity * sizeof(int64_t)) {
            // Resize underlying mapped file
            std::size_t newElems = (offset + bytes) / sizeof(int64_t) + 1;
            if (!file.resize(newElems))
                throw std::bad_alloc();

            base = file.raw();
            capacity = file.size();
        }

        T* ptr = reinterpret_cast<T*>(reinterpret_cast<char*>(base) + offset);
        offset += bytes;
        return ptr;
    }

    void deallocate(T* ptr, std::size_t n) noexcept {
        // No-op: memory reclaimed on file close
    }

    template <typename U>
    struct rebind { using other = FileMappedAllocator<U>; };

    bool operator==(const FileMappedAllocator& other) const noexcept { return &file == &other.file; }
    bool operator!=(const FileMappedAllocator& other) const noexcept { return &file != &other.file; }

private:
    MappedFile& file;
    int64_t* base;
    std::size_t capacity; // in int64_t
    std::size_t offset;   // in bytes

    template <typename U> friend class FileMappedAllocator;
};

// ------------------------------
// Type alias for deferred notes
// ------------------------------
using DeferredMap = std::unordered_map<int64_t, int64_t, std::hash<int64_t>, std::equal_to<int64_t>,
                                       FileMappedAllocator<std::pair<const int64_t, int64_t>>>;

// Global mapped files
MappedFile insertsFile;
MappedFile removalsFile;
DeferredMap inserts;
DeferredMap removals;

void insertDeferred(int64_t note) {
    int64_t index = 0; // placeholder
    //(*inserts)[index] = note;
}

void removeDeferred(int64_t index) {
    //(*removals)[index] = true;
}

int64_t* __restrict data = nullptr;
int64_t length = 0;
int64_t indexOffsetPos = 0; // For sequential `getNote(atIndex)`.
// Resets when starting a note update again, for an obvious reason.
// It's because insertions and removals need to be very fast on the chart editor so this is basically a sorta "hack" to solve impossible problems I would've once faced.

void resetGetNoteLookup() {
    indexOffsetPos = 0;
}

bool remap(size_t newLength) {
    bool ok = gFile.resize(newLength);
    data = gFile.raw();
    length = gFile.size();
    return ok;
}

void loadChart(const char* inFile) {
    if (!gFile.open(inFile))
        throw std::runtime_error("Failed to open chart file");

    std::string insertsPath = std::string(inFile) + "_deferredInserts.bin";
    if (!insertsFile.open(insertsPath.c_str())) {
        insertsFile.open(insertsPath.c_str());
        insertsFile.resize(1024 * 16);
    } else {
        insertsFile.resize(1024 * 16);
    }

    std::string removalsPath = std::string(inFile) + "_deferredRemoves.bin";
    if (!removalsFile.open(removalsPath.c_str())) {
        removalsFile.open(removalsPath.c_str());
        removalsFile.resize(1024 * 16);
    } else {
        removalsFile.resize(1024 * 16);
    }
    
    FileMappedAllocator<std::pair<const int64_t, int64_t>> allocI(insertsFile);
    FileMappedAllocator<std::pair<const int64_t, bool>> allocR(removalsFile);
    DeferredMap insertsM(10, std::hash<int64_t>(), std::equal_to<int64_t>(), allocI);
    DeferredMap removalsM(10, std::hash<int64_t>(), std::equal_to<int64_t>(), allocR);

    inserts = insertsM;
    removals = removalsM;

    data = gFile.raw();
    length = gFile.size();
}

void destroyChart() {
    gFile.close();
    insertsFile.close();
    removalsFile.close();
    data = nullptr;
    length = 0;
}

int64_t getNote(int64_t atIndex) {
    auto it = inserts.find(atIndex);
    if (it != inserts.end()) return it->second;
    // fallback to main chart
    return data[atIndex - indexOffsetPos];
}
void setNote(int64_t atIndex, int64_t value) { data[atIndex] = value; }
int64_t getLength() { return length; }

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

inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

void insertNotes(std::vector<int64_t> newNotes) {
    if (newNotes.empty()) return;

    int64_t oldLen = length;
    int64_t k = newNotes.size();
    int64_t newLen = oldLen + k;

    if (!remap(newLen)) throw std::runtime_error("failed to resize file");

    int64_t* __restrict writePtr = data + newLen - 1;
    int64_t* __restrict dataPtr  = data + oldLen - 1;
    int64_t* __restrict newPtr   = newNotes.data() + k - 1;

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

void removeNotes(std::vector<int64_t> notesToRemove) {
    if (notesToRemove.empty()) return;

    int64_t* __restrict readPtr   = data;
    int64_t* __restrict writePtr  = data;
    int64_t* __restrict endPtr    = data + length;
    int64_t* __restrict removePtr = notesToRemove.data();
    int64_t* __restrict removeEnd = notesToRemove.data() + notesToRemove.size();

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
        if (!remap(newLength))
            throw std::runtime_error("failed to shrink file after removeNotes");
        length = newLength;
    }
}