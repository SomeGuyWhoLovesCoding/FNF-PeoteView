#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <algorithm>

#ifdef _WIN32
#include <windows.h>
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

int64_t* data = nullptr;
int64_t length = 0;          // number of valid notes
int64_t mapped_length = 0;   // actual mapped size
int64_t gap_start = 0;       // gap start index
int64_t gap_end = 0;         // gap end index

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

// ---------------- Memory-mapping helpers ----------------
bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }

    LARGE_INTEGER newSize; newSize.QuadPart = newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile))
        return false;

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;
    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) { CloseHandle(hMap); hMap = NULL; return false; }
#else
    if (data && mapped_length > 0) { munmap(data, mapped_length * sizeof(int64_t)); data = nullptr; }
    if (ftruncate(fd, newLength * sizeof(int64_t)) == -1) return false;
    data = (int64_t*)mmap(nullptr, newLength * sizeof(int64_t),
                          PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { data = nullptr; return false; }
#endif
    mapped_length = newLength;
    return true;
}

// ---------------- Load / Destroy ----------------
void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = fileSize.QuadPart / sizeof(int64_t);
    mapped_length = length;
    remap(length);
#else
    fd = open(inFile, O_RDWR | O_CREAT, 0644);
    if (fd == -1) return;
    struct stat st; fstat(fd, &st);
    length = st.st_size / sizeof(int64_t);
    mapped_length = length;
    remap(length);
#endif
    gap_start = length;
    gap_end = length;
}

void destroyChart() {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data);
    if (hMap) CloseHandle(hMap);
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile);
#else
    if (data && mapped_length > 0) munmap(data, mapped_length * sizeof(int64_t));
    if (fd != -1) close(fd);
#endif
    data = nullptr; length = 0; mapped_length = 0;
    gap_start = gap_end = 0;
}

// ---------------- Single-note operations using gap buffer ----------------
void insertNote(int64_t note) {
    int64_t idx = findInsertIndex(note);
    if (idx < gap_start || idx > gap_start) moveGap(idx);
    if (gap_end - gap_start < 1) expandGap(16);
    data[gap_start++] = note;
    length++;
}

void removeNote(int64_t note) {
    int64_t idx = findInsertIndex(note);
    int64_t real_idx = idx >= gap_start ? idx + (gap_end - gap_start) : idx;
    if (real_idx >= length || data[real_idx] != note) return; // not found

    // Move gap to removal point
    moveGap(idx);
    gap_start++;   // remove the note by advancing gap start
    length--;

    // Optionally grow the gap a bit after removal
    int64_t growSize = 16;
    gap_end = gap_start + growSize;
    if (!remap(gap_end)) throw std::runtime_error("failed to expand gap after removal");
}

// ---------------- Extract / gap-aware binary search ----------------
inline int64_t extractTime(int64_t note) {
    return (note >> 23) & 0x1FFFFFFFFFFLL; // example 2199023255551 mask
}

int64_t findInsertIndex(int64_t note) {
    int64_t lo = 0, hi = length;
    while (lo < hi) {
        int64_t mid = lo + (hi - lo)/2;
        int64_t midNote = mid >= gap_start ? data[mid + (gap_end - gap_start)] : data[mid];
        if (extractTime(midNote) < extractTime(note)) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}

// ---------------- Gap buffer helpers ----------------
void moveGap(int64_t index) {
    if (index < 0 || index > length) throw std::out_of_range("index out of range");
    if (index < gap_start) {
        int64_t move_size = gap_start - index;
        std::memmove(data + gap_end - move_size, data + index, move_size * sizeof(int64_t));
        gap_start = index;
        gap_end -= move_size;
    } else if (index > gap_start) {
        int64_t move_size = index - gap_start;
        std::memmove(data + gap_start, data + gap_end, move_size * sizeof(int64_t));
        gap_start += move_size;
        gap_end += move_size;
    }
}

void expandGap(int64_t min_extra) {
    int64_t newMapped = mapped_length + min_extra + (mapped_length/2);
    if (!remap(newMapped)) throw std::runtime_error("failed to expand gap buffer");
    gap_end += newMapped - mapped_length;
}

// ---------------- Insert / Remove ----------------
void insertNotes(std::vector<int64_t> values) {
    if (values.empty()) return;
    std::sort(values.begin(), values.end(),
              [](int64_t a, int64_t b){ return extractTime(a) < extractTime(b); });

    for (auto note : values) {
        int64_t idx = findInsertIndex(note);
        if (idx < gap_start || idx > gap_start) moveGap(idx);
        if (gap_end - gap_start < 1) expandGap(16);
        data[gap_start++] = note;
        length++;
    }
}

void removeNotes(std::vector<int64_t> values) {
    if (values.empty() || length == 0) return;
    std::sort(values.begin(), values.end(),
              [](int64_t a, int64_t b){ return extractTime(a) < extractTime(b); });

    int64_t in = 0, out = 0, j = 0;
    int64_t first_removed_index = -1;

    while (in < length && j < (int64_t)values.size()) {
        int64_t note = in >= gap_start ? data[in + (gap_end - gap_start)] : data[in];
        int64_t t = extractTime(note);
        int64_t t_rem = extractTime(values[j]);

        if (t < t_rem) {
            if (out != in) {
                if (in >= gap_start) data[out + (gap_end - gap_start)] = note;
                else data[out] = note;
            }
            in++; out++;
        } else if (t > t_rem) j++;
        else {
            if (first_removed_index < 0) first_removed_index = out;
            if (note == values[j]) in++;
            else { if (out != in) {
                if (in >= gap_start) data[out + (gap_end - gap_start)] = note;
                else data[out] = note;
            } in++; out++; }
            j++;
        }
    }

    while (in < length) {
        int64_t note = in >= gap_start ? data[in + (gap_end - gap_start)] : data[in];
        if (out != in) {
            if (in >= gap_start) data[out + (gap_end - gap_start)] = note;
            else data[out] = note;
        }
        in++; out++;
    }

    length = out;
    gap_start = first_removed_index >= 0 ? first_removed_index : length;

    int64_t growSize = std::max((int64_t)16, (int64_t)(values.size() * 1.5));
    gap_end = gap_start + growSize;
    if (!remap(gap_end)) throw std::runtime_error("failed to expand gap after removal");
}
