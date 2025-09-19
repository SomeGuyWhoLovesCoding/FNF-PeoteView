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

int64_t* __restrict gData = nullptr;
int64_t length = 0;
int64_t indexOffsetPos = 0; // For sequential `getNote(atIndex)`. Resets when updating the NoteSpawner again.

// ============================================================================
// Deferred Inserts and Removals optimization technique (unfinished)
// ============================================================================
std::unordered_map<int64_t, int64_t> inserts;
std::unordered_map<int64_t, bool> removals;

inline int64_t extractTime(int64_t note) { return (note >> 23) & 0x1FFFFFFFFFFLL; }

void insertNote(int64_t index, int64_t note) {
    inserts.insert({index, note});
}

void removeNote(int64_t index) {
    removals.insert({index, true});
}

void resetGetNoteLookup() {
    indexOffsetPos = 0;
}

bool remap(size_t newLength) {
    bool ok = gFile.resize(newLength);
    gData = gFile.raw();
    length = gFile.size();
    return ok;
}

void loadChart(const char* inFile) {
    if (!gFile.open(inFile))
        throw std::runtime_error("Failed to open chart file");

    /*std::string insertsPath = std::string(inFile) + "_deferredInserts.bin";
    inserts.createNew(insertsPath, 10000); // 10000 is the number of buckets*/

    /*std::string removalsPath = std::string(inFile) + "_deferredRemoves.bin";
    inserts.createNew(removalsPath, 10000); // 10000 is the number of buckets*/

    gData = gFile.raw();
    length = gFile.size();
}

void destroyChart() {
    gFile.close();
    gData = nullptr;
    length = 0;

    inserts.clear();
    removals.clear();
}

int64_t getNote(int64_t atIndex) {
    if (inserts.at(atIndex) != 0) {
        indexOffsetPos++;
        return inserts.at(atIndex);
    }

    return gData[atIndex - indexOffsetPos];
}
void setNote(int64_t atIndex, int64_t value) { gData[atIndex] = value; }
int64_t getLength() { return length + inserts.size() - removals.size(); }

void insertNotes(std::vector<int64_t> newNotes) {
    if (newNotes.empty()) return;

    int64_t left = 0;
    int64_t right = length - 1;
    int64_t index = -1;
    for (int64_t newNote : newNotes) {
        int64_t noteTime = extractTime(newNote);
        while (left <= right) {
            int64_t mid = left + (right - left) / 2;
            int64_t midTime = extractTime(gData[mid]);
            if (midTime == noteTime) {
                index = mid;
                break;
            } else if (midTime < noteTime) {
                left = mid + 1;
            } else {
                right = mid - 1;
            }
        }
        if (index == -1) {
            // If not found, index can be set to left (insertion point)
            index = left;
        }
        insertNote(index, newNote);
    }
}

void removeNotes(const std::vector<int64_t>& notesToRemove) {
    if (notesToRemove.empty()) return;

    for (int64_t note : notesToRemove) {
        int64_t targetTime = extractTime(note);

        int64_t left = 0;
        int64_t right = length - 1;
        int64_t foundIdx = -1;

        // Binary search by extractTime
        while (left <= right) {
            int64_t mid = left + (right - left) / 2;
            int64_t midTime = extractTime(gData[mid]);

            if (midTime == targetTime) {
                if (gData[mid] == note) {
                    foundIdx = mid;
                    break;  // exact match
                }
                // Time matches but value differs: scan nearby
                int64_t l = mid - 1, r = mid + 1;
                while (l >= left && extractTime(gData[l]) == targetTime) {
                    if (gData[l] == note) { foundIdx = l; break; }
                    --l;
                }
                while (foundIdx == -1 && r <= right && extractTime(gData[r]) == targetTime) {
                    if (gData[r] == note) { foundIdx = r; break; }
                    ++r;
                }
                break;
            } else if (midTime < targetTime) {
                left = mid + 1;
            } else {
                right = mid - 1;
            }
        }

        // Defer removal if found in mapped file
        if (foundIdx != -1) {
            removeNote(foundIdx);
        }

        // Also check deferred inserts (in case the note hasn’t been flushed yet)
        for (auto it = inserts.begin(); it != inserts.end(); ) {
            if (it->second == note) {
                it = inserts.erase(it);
                break;  // remove only the first match
            } else {
                ++it;
            }
        }
    }
}