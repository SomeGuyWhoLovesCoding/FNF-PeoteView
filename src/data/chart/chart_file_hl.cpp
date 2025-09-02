#define HL_NAME(n) chart_file_##n

#include <hl.h>
#include <iostream>
#include <cstdint>
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
    #define SIMD_BACKEND_SCALAR
#endif

// ---------------- SIMD helpers ----------------
inline void simd_copy_backward(int64_t* dst, const int64_t* src, int64_t count) {
#if defined(SIMD_BACKEND_AVX2)
    while (count >= 4) { __m256i v = _mm256_loadu_si256((__m256i const*)(src + count - 4)); _mm256_storeu_si256((__m256i*)(dst + count - 4), v); count -= 4; }
    if (count >= 2) { __m128i v = _mm_loadu_si128((__m128i const*)(src + count - 2)); _mm_storeu_si128((__m128i*)(dst + count - 2), v); count -= 2; }
    if (count == 1) { __m128i v = _mm_loadl_epi64((__m128i const*)src); _mm_storel_epi64((__m128i*)dst, v); }
#elif defined(SIMD_BACKEND_SSE2)
    while (count >= 2) { __m128i v = _mm_loadu_si128((__m128i const*)(src + count - 2)); _mm_storeu_si128((__m128i*)(dst + count - 2), v); count -= 2; }
    if (count == 1) { __m128i v = _mm_loadl_epi64((__m128i const*)src); _mm_storel_epi64((__m128i*)dst, v); }
#elif defined(SIMD_BACKEND_NEON)
    while (count >= 2) { int64x2_t v = vld1q_s64(src + count - 2); vst1q_s64(dst + count - 2, v); count -= 2; }
    if (count == 1) { int64x1_t v1 = vld1_s64(src); vst1_s64(dst, v1); }
#else
    while (count > 0) { dst[count-1] = src[count-1]; --count; }
#endif
}

inline void simd_copy_forward(int64_t* dst, const int64_t* src, int64_t count) {
#if defined(SIMD_BACKEND_AVX2)
    while (count >= 4) { __m256i v = _mm256_loadu_si256((__m256i const*)src); _mm256_storeu_si256((__m256i*)dst, v); src+=4; dst+=4; count-=4; }
    if (count >= 2) { __m128i v = _mm_loadu_si128((__m128i const*)src); _mm_storeu_si128((__m128i*)dst, v); src+=2; dst+=2; count-=2; }
    if (count == 1) { __m128i v = _mm_loadl_epi64((__m128i const*)src); _mm_storel_epi64((__m128i*)dst, v); }
#elif defined(SIMD_BACKEND_SSE2)
    while (count >= 2) { __m128i v = _mm_loadu_si128((__m128i const*)src); _mm_storeu_si128((__m128i*)dst, v); src+=2; dst+=2; count-=2; }
    if (count == 1) { __m128i v = _mm_loadl_epi64((__m128i const*)src); _mm_storel_epi64((__m128i*)dst, v); }
#elif defined(SIMD_BACKEND_NEON)
    while (count >= 2) { int64x2_t v = vld1q_s64(src); vst1q_s64(dst, v); src+=2; dst+=2; count-=2; }
    if (count == 1) { int64x1_t v1 = vld1_s64(src); vst1_s64(dst, v1); }
#else
    while (count > 0) { *dst++ = *src++; --count; }
#endif
}

// -----------------------------------------------------------------------------
// Globals
// -----------------------------------------------------------------------------
int64_t* data = nullptr;
int64_t length = 0;

#ifdef _WIN32
HANDLE hFile = INVALID_HANDLE_VALUE;
HANDLE hMap  = NULL;
#else
int fd = -1;
#endif

static int64_t deferredOps[1048576][3];
static int64_t opCount = 0;
static bool isDirty = false;

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
static bool remap(size_t newLength) {
#ifdef _WIN32
    if (data) { UnmapViewOfFile(data); data=nullptr; }
    if (hMap) { CloseHandle(hMap); hMap=NULL; }
    LARGE_INTEGER sz; sz.QuadPart = newLength*sizeof(int64_t);
    if (!SetFilePointerEx(hFile, sz, NULL, FILE_BEGIN) || !SetEndOfFile(hFile)) return false;
    hMap = CreateFileMapping(hFile, NULL, PAGE_READWRITE, 0,0,NULL);
    if (!hMap) return false;
    data = static_cast<int64_t*>(MapViewOfFile(hMap, FILE_MAP_ALL_ACCESS,0,0,0));
    if (!data) { CloseHandle(hMap); hMap=NULL; return false; }
#else
    if (data) { munmap(data,length*sizeof(int64_t)); data=nullptr; }
    if (ftruncate(fd,newLength*sizeof(int64_t))==-1) return false;
    data = static_cast<int64_t*>(mmap(nullptr,newLength*sizeof(int64_t),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0));
    if (data==MAP_FAILED) { data=nullptr; return false; }
#endif
    length = newLength;
    return true;
}

static void flushDeferred() {
    if (!isDirty || opCount==0) return;
    int64_t oldLength = length;
    int64_t netChange=0;
    for(int64_t i=0;i<opCount;++i) netChange += deferredOps[i][2]?1:-1;
    int64_t finalLength = oldLength + netChange; if(finalLength<0) finalLength=0;
    if(!remap(finalLength)) throw std::runtime_error("failed to resize");
    for(int64_t i=0;i<opCount-1;++i) for(int64_t j=i+1;j<opCount;++j) if(deferredOps[i][0]<deferredOps[j][0]) for(int k=0;k<3;++k) std::swap(deferredOps[i][k],deferredOps[j][k]);
    for(int64_t i=0;i<opCount;++i){
        int64_t idx = deferredOps[i][0];
        int64_t val = deferredOps[i][1];
        bool ins = deferredOps[i][2];
        if(ins){
            if(idx<oldLength) simd_copy_backward(&data[idx+1],&data[idx],oldLength-idx);
            data[idx]=val;
            ++oldLength;
        }else{
            if(idx<oldLength-1) simd_copy_forward(&data[idx],&data[idx+1],oldLength-idx-1);
            --oldLength;
        }
    }
    opCount=0; isDirty=false;
}

// -----------------------------------------------------------------------------
// HL API
// -----------------------------------------------------------------------------
HL_PRIM void HL_NAME(loadChart)(vstring* inFile){
    const char* path = hl_to_utf8(inFile->bytes);
#ifdef _WIN32
    hFile = CreateFileA(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(hFile==INVALID_HANDLE_VALUE) return;
    LARGE_INTEGER sz; GetFileSizeEx(hFile,&sz);
    length = sz.QuadPart/sizeof(int64_t);
#else
    fd = open(path,O_RDWR|O_CREAT,0644); if(fd==-1) throw std::runtime_error("open failed");
    struct stat st; if(fstat(fd,&st)==-1) throw std::runtime_error("stat failed");
    length = st.st_size/sizeof(int64_t);
#endif
    if(!remap(length)) throw std::runtime_error("map failed");
    memset(deferredOps,0,sizeof(deferredOps)); opCount=0; isDirty=false;
}

HL_PRIM int64_t HL_NAME(getNote)(int64_t idx){ flushDeferred(); if(idx<0||idx>=length) throw std::out_of_range("index"); return data[idx]; }
HL_PRIM void HL_NAME(setNote)(int64_t idx,int64_t val){ flushDeferred(); if(idx<0||idx>=length) throw std::out_of_range("index"); data[idx]=val; }
HL_PRIM int64_t HL_NAME(getLength)(_NO_ARG){ if(!isDirty) return length; int64_t c=0; for(int64_t i=0;i<opCount;++i) c+=deferredOps[i][2]?1:-1; return length+c; }

HL_PRIM void HL_NAME(destroyChart)(_NO_ARG){
#ifdef _WIN32
    if(data) UnmapViewOfFile(data); if(hMap) CloseHandle(hMap); if(hFile!=INVALID_HANDLE_VALUE) CloseHandle(hFile);
    data=nullptr; hMap=NULL; hFile=INVALID_HANDLE_VALUE;
#else
    if(data) munmap(data,length*sizeof(int64_t)); if(fd!=-1) close(fd); data=nullptr; fd=-1;
#endif
    length=0; memset(deferredOps,0,sizeof(deferredOps)); opCount=0; isDirty=false;
}

HL_PRIM void HL_NAME(insertNote)(int64_t idx,int64_t val,bool autoflush){
    if(idx<0||idx>HL_NAME(getLength)(_NO_ARG)) throw std::out_of_range("index");
    if(opCount<1048576 && !autoflush){ deferredOps[opCount][0]=idx; deferredOps[opCount][1]=val; deferredOps[opCount][2]=1; opCount++; isDirty=true; }
    else { flushDeferred(); deferredOps[0][0]=idx; deferredOps[0][1]=val; deferredOps[0][2]=1; opCount=1; isDirty=true; }
}

HL_PRIM void HL_NAME(removeNote)(int64_t idx,bool autoflush){
    if(idx<0||idx>=HL_NAME(getLength)(_NO_ARG)) throw std::out_of_range("index");
    if(opCount<1048576 && !autoflush){ deferredOps[opCount][0]=idx; deferredOps[opCount][1]=0; deferredOps[opCount][2]=0; opCount++; isDirty=true; }
    else { flushDeferred(); deferredOps[0][0]=idx; deferredOps[0][1]=0; deferredOps[0][2]=0; opCount=1; isDirty=true; }
}

// -----------------------------------------------------------------------------
// HL binding macros
// -----------------------------------------------------------------------------
DEFINE_PRIM(_VOID, loadChart, _STRING)
DEFINE_PRIM(_I64, getNote, _I64)
DEFINE_PRIM(_VOID, setNote, _I64 _I64)
DEFINE_PRIM(_I64, getLength, _NO_ARG)
DEFINE_PRIM(_VOID, destroyChart, _NO_ARG)
DEFINE_PRIM(_VOID, insertNote, _I64 _I64 _BOOL)
DEFINE_PRIM(_VOID, removeNote, _I64 _BOOL)