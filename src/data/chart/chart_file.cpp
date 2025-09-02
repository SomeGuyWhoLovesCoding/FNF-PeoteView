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

// ---------------- SIMD dispatch (compile-time) ----------------
// Priority: user-defined > compiler-detected
#if defined(USE_AVX2)
    #include <immintrin.h>
    #define SIMD_BACKEND_AVX2
#elif defined(USE_SSE2)
    #include <emmintrin.h>
    #define SIMD_BACKEND_SSE2
#elif defined(USE_NEON)
    #include <arm_neon.h>
    #define SIMD_BACKEND_NEON
#else
    #if defined(__AVX2__)
        #include <immintrin.h>
        #define SIMD_BACKEND_AVX2
    #elif defined(__SSE2__)
        #include <emmintrin.h>
        #define SIMD_BACKEND_SSE2
    #elif defined(__ARM_NEON) || defined(__ARM_NEON__)
        #include <arm_neon.h>
        #define SIMD_BACKEND_NEON
    #else
        #define SIMD_BACKEND_SCALAR
    #endif
#endif

// ---------------- SIMD helpers ----------------
// Copy backward: dst and src may overlap; we copy from high -> low (used for insert shifting)
inline void simd_copy_backward(int64_t* dst, const int64_t* src, int64_t count) {
#if defined(SIMD_BACKEND_AVX2)
    // handle 256-bit blocks (4 x int64_t)
    while (count >= 4) {
        __m256i v = _mm256_loadu_si256((__m256i const*)(src + count - 4));
        _mm256_storeu_si256((__m256i*)(dst + count - 4), v);
        count -= 4;
    }
    // handle 128-bit block if present (2 x int64_t)
    if (count >= 2) {
        __m128i v = _mm_loadu_si128((__m128i const*)(src + count - 2));
        _mm_storeu_si128((__m128i*)(dst + count - 2), v);
        count -= 2;
    }
    // handle final single lane with lane-limited loads/stores (no scalar)
    if (count == 1) {
        __m128i v = _mm_loadl_epi64((__m128i const*)(src)); // loads 64 bits
        _mm_storel_epi64((__m128i*)(dst), v);
    }

#elif defined(SIMD_BACKEND_SSE2)
    while (count >= 2) {
        __m128i v = _mm_loadu_si128((__m128i const*)(src + count - 2));
        _mm_storeu_si128((__m128i*)(dst + count - 2), v);
        count -= 2;
    }
    if (count == 1) {
        __m128i v = _mm_loadl_epi64((__m128i const*)(src));
        _mm_storel_epi64((__m128i*)(dst), v);
    }

#elif defined(SIMD_BACKEND_NEON)
    while (count >= 2) {
        int64x2_t v = vld1q_s64(src + count - 2);
        vst1q_s64(dst + count - 2, v);
        count -= 2;
    }
    if (count == 1) {
        // load 1 lane safely and store 1 lane
        int64x1_t v1 = vld1_s64(src); // loads single int64_t
        vst1_s64(dst, v1);
    }

#else // scalar fallback
    while (count > 0) {
        dst[count - 1] = src[count - 1];
        --count;
    }
#endif
}

// Copy forward: dst = src (used for remove shifting), copy low -> high
inline void simd_copy_forward(int64_t* dst, const int64_t* src, int64_t count) {
#if defined(SIMD_BACKEND_AVX2)
    while (count >= 4) {
        __m256i v = _mm256_loadu_si256((__m256i const*)src);
        _mm256_storeu_si256((__m256i*)dst, v);
        src += 4; dst += 4; count -= 4;
    }
    if (count >= 2) {
        __m128i v = _mm_loadu_si128((__m128i const*)src);
        _mm_storeu_si128((__m128i*)dst, v);
        src += 2; dst += 2; count -= 2;
    }
    if (count == 1) {
        __m128i v = _mm_loadl_epi64((__m128i const*)src);
        _mm_storel_epi64((__m128i*)dst, v);
    }

#elif defined(SIMD_BACKEND_SSE2)
    while (count >= 2) {
        __m128i v = _mm_loadu_si128((__m128i const*)src);
        _mm_storeu_si128((__m128i*)dst, v);
        src += 2; dst += 2; count -= 2;
    }
    if (count == 1) {
        __m128i v = _mm_loadl_epi64((__m128i const*)src);
        _mm_storel_epi64((__m128i*)dst, v);
    }

#elif defined(SIMD_BACKEND_NEON)
    while (count >= 2) {
        int64x2_t v = vld1q_s64(src);
        vst1q_s64(dst, v);
        src += 2; dst += 2; count -= 2;
    }
    if (count == 1) {
        int64x1_t v1 = vld1_s64(src);
        vst1_s64(dst, v1);
    }

#else // scalar fallback
    while (count > 0) {
        *dst++ = *src++;
        --count;
    }
#endif
}

// ---------------- Data / state ----------------
int64_t* data = nullptr;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

// ---------------- Ultra-fast strategy: Three-element deferred operations ----------------
// Raw int64_t array structure: [1048576][3]
// Element 0: index, Element 1: value, Element 2: operation type (1=insert, 0=remove)
static int64_t deferredOps[1048576][3];
static int64_t opCount = 0;
static bool isDirty = false;

// ---------------- Memory-mapping helpers ----------------
static bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data = nullptr; }
    if (hMap) { CloseHandle(hMap); hMap = NULL; }

    LARGE_INTEGER newSize; newSize.QuadPart = (LONGLONG)newLength * sizeof(int64_t);
    if (!SetFilePointerEx(hFile, newSize, NULL, FILE_BEGIN) || !SetEndOfFile(hFile)) return false;

    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0, 0, NULL);
    if (!hMap) return false;

    data = (int64_t*)MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS, 0, 0, 0);
    if (!data) { CloseHandle(hMap); hMap = NULL; return false; }

#else
    if (data) { munmap(data, length * sizeof(int64_t)); data = nullptr; }
    if (ftruncate(fd, (off_t)newLength * sizeof(int64_t)) == -1) return false;

    data = (int64_t*)mmap(nullptr, newLength * sizeof(int64_t),
                          PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { data = nullptr; return false; }
#endif
    length = (int64_t)newLength;
    return true;
}

static void flushDeferred() {
    if (!isDirty || opCount == 0) return;

    // Save old length (we need to reason about moving old elements)
    int64_t oldLength = length;

    // Calculate final size using raw array elements
    int64_t netChange = 0;
    for (int64_t i = 0; i < opCount; ++i) {
        netChange += deferredOps[i][2] ? 1 : -1; // Element 2 contains operation type
    }

    int64_t finalLength = oldLength + netChange;
    if (finalLength < 0) finalLength = 0;

    // Single remap to final size
    if (!remap((size_t)finalLength)) {
        throw std::runtime_error("failed to resize for deferred operations");
    }

    // Sort by index (descending) for optimal processing
    for (int64_t i = 0; i < opCount - 1; ++i) {
        for (int64_t j = i + 1; j < opCount; ++j) {
            if (deferredOps[i][0] < deferredOps[j][0]) { // Element 0 contains index
                // Swap all three elements
                for (int k = 0; k < 3; ++k) {
                    int64_t temp = deferredOps[i][k];
                    deferredOps[i][k] = deferredOps[j][k];
                    deferredOps[j][k] = temp;
                }
            }
        }
    }

    // Apply operations from highest index to lowest
    // Note: after remap, length == finalLength. We use oldLength where
    // needed to compute how many existing elements must be moved.
    for (int64_t i = 0; i < opCount; ++i) {
        int64_t index = deferredOps[i][0];  // Element 0: index
        int64_t value = deferredOps[i][1];  // Element 1: value
        bool isInsert = deferredOps[i][2];  // Element 2: operation type

        if (isInsert) {
            // For insert: shift old elements at [index .. oldLength-1] one right
            if (index < oldLength) {
                int64_t* src = &data[index];
                int64_t* dst = &data[index + 1];
                // number of old elements to move
                int64_t moveCount = oldLength - index;
                // Use SIMD forward/backward copies (backward here)
                simd_copy_backward(dst, src, moveCount);
            }
            // write inserted value
            data[index] = value;
            // update oldLength to reflect applied insertion (for subsequent ops)
            ++oldLength;
        } else { // Remove
            if (index < oldLength - 1) {
                int64_t* dst = &data[index];
                int64_t* src = &data[index + 1];
                int64_t moveCount = oldLength - index - 1;
                // forward copy
                simd_copy_forward(dst, src, moveCount);
            }
            // update oldLength to reflect applied removal
            --oldLength;
        }
    }

    // Finalize state: length already set by remap; opCount clear
    opCount = 0;
    isDirty = false;
}

// ---------------- Load / Destroy ----------------
void loadChart(const char* inFile) {
#ifdef _WIN32
    hFile = CreateFileA(inFile, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, NULL,
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER fileSize; GetFileSizeEx(hFile, &fileSize);
    length = (int64_t)(fileSize.QuadPart / sizeof(int64_t));
    remap(length);
#else
    fd = open(inFile, O_RDWR | O_CREAT, 0644);
    struct stat st; fstat(fd, &st);
    length = (int64_t)(st.st_size / sizeof(int64_t));
    remap(length);
#endif

    // Clear the three-element array structure
    memset(deferredOps, 0, sizeof(deferredOps));
    opCount = 0;
    isDirty = false;
}

int64_t getNote(int64_t atIndex) {
    flushDeferred(); // Ensure we're reading current state
    if (atIndex < 0 || atIndex >= length) throw std::out_of_range("index out of range");
    return data[atIndex];
}

void setNote(int64_t atIndex, int64_t value) {
    flushDeferred(); // Ensure consistent state
    if (atIndex < 0 || atIndex >= length) throw std::out_of_range("index out of range");
    data[atIndex] = value;
}

int64_t getLength() {
    if (!isDirty) return length;

    int64_t change = 0;
    for (int64_t i = 0; i < opCount; ++i) {
        change += deferredOps[i][2] ? 1 : -1; // Element 2 contains operation type
    }
    return length + change;
}

void destroyChart() {
#ifdef _WIN32
    if (data) UnmapViewOfFile(data); data = nullptr;
    if (hMap) CloseHandle(hMap); hMap = NULL;
    if (hFile != INVALID_HANDLE_VALUE) CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE;
#else
    if (data) munmap(data, length * sizeof(int64_t)); data = nullptr;
    if (fd != -1) close(fd); fd = -1;
#endif
    length = 0;
    memset(deferredOps, 0, sizeof(deferredOps));
    opCount = 0;
    isDirty = false;
}

// ---------------- FASTEST insert/remove functions ----------------
void insertNote(int64_t index, int64_t value, bool autoflush = false) {
    if (index < 0 || index > getLength()) {
        throw std::out_of_range("index out of range");
    }

    // Use raw int64_t array: [0]=index, [1]=value, [2]=operation type
    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount][0] = index;
        deferredOps[opCount][1] = value;
        deferredOps[opCount][2] = 1; // 1 = insert
        opCount++;
        isDirty = true;
    } else {
        // Array full or autoflush requested - flush and add
        flushDeferred();
        deferredOps[0][0] = index;
        deferredOps[0][1] = value;
        deferredOps[0][2] = 1; // 1 = insert
        opCount = 1;
        isDirty = true;
    }
}

void removeNote(int64_t index, bool autoflush = false) {
    if (index < 0 || index >= getLength()) {
        throw std::out_of_range("index out of range");
    }

    // Use raw int64_t array: [0]=index, [1]=value, [2]=operation type
    if (opCount < 1048576 && !autoflush) {
        deferredOps[opCount][0] = index;
        deferredOps[opCount][1] = 0; // value unused for remove
        deferredOps[opCount][2] = 0; // 0 = remove
        opCount++;
        isDirty = true;
    } else {
        // Array full or autoflush requested - flush and add
        flushDeferred();
        deferredOps[0][0] = index;
        deferredOps[0][1] = 0; // value unused for remove
        deferredOps[0][2] = 0; // 0 = remove
        opCount = 1;
        isDirty = true;
    }
}

// ---------------- Force immediate application ----------------
void sync() {
    flushDeferred();
}

// ---------------- Ultra-fast bulk operations ----------------
void insertNotesInstant(const std::vector<std::pair<int64_t, int64_t>>& indexValuePairs, bool autoflush = false) {
    for (const auto& pair : indexValuePairs) {
        if (opCount < 1048576 && !autoflush) {
            deferredOps[opCount][0] = pair.first;
            deferredOps[opCount][1] = pair.second;
            deferredOps[opCount][2] = 1; // 1 = insert
            opCount++;
        } else {
            flushDeferred();
            deferredOps[0][0] = pair.first;
            deferredOps[0][1] = pair.second;
            deferredOps[0][2] = 1; // 1 = insert
            opCount = 1;
        }
    }
    isDirty = true;
}

void removeNotesInstant(const std::vector<int64_t>& indices, bool autoflush = false) {
    for (int64_t index : indices) {
        if (opCount < 1048576 && !autoflush) {
            deferredOps[opCount][0] = index;
            deferredOps[opCount][1] = 0; // value unused for remove
            deferredOps[opCount][2] = 0; // 0 = remove
            opCount++;
        } else {
            flushDeferred();
            deferredOps[0][0] = index;
            deferredOps[0][1] = 0; // value unused for remove
            deferredOps[0][2] = 0; // 0 = remove
            opCount = 1;
        }
    }
    isDirty = true;
}