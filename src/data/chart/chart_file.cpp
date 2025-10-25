// COMPILE TO 64 BIT!!!

#include <iostream>
#include <cstdint>
#include <vector>
#include <stdexcept>
#include <cstring>
#include <string>
#include <algorithm>
#include <fstream>
#include <xmmintrin.h>
#include <chrono>
#include <cstdio>

#ifdef _WIN32
#include <windows.h>
#include <direct.h> 
#else
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// ============================================================================
// MappedFile class
// ============================================================================
class MappedFile {
public:
	MappedFile() = default;
	~MappedFile() { close(); } //ChartSystem already does exactly this. This was originally commented out.

	bool open(const char* path) {
#ifdef _WIN32
		hFile = CreateFileA(
			path,
			GENERIC_READ | GENERIC_WRITE,
			0,
			NULL,
			OPEN_ALWAYS,
			FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN,
			NULL
		);
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
					  PROT_READ | PROT_WRITE,
					  MAP_SHARED | MAP_POPULATE,
					  fd, 0);
		if (data == MAP_FAILED) { data = nullptr; return false; }
#endif
		length = newLength;
		return true;
	}

	#ifdef _WIN32
	/*alignas(32)*/ int64_t* __restrict data = nullptr;
	#else
	/*alignas(32)*/ int64_t* __restrict__ data = nullptr;
	#endif
	int64_t length = 0;

#ifdef _WIN32
	HANDLE hFile = INVALID_HANDLE_VALUE;
	HANDLE hMap  = NULL;
#else
	int fd = -1;
#endif
};

// ============================================================================
// ChartRenderSystem
// ============================================================================
class ChartRenderSystem {
private:
	MappedFile mainFile;
	MappedFile insertFile;
	MappedFile tempFile;

	int64_t tempCapacity = 2048;
	int64_t insertCapacity = 2048;
	int64_t insertCount = 0;
	int64_t tempCount = 0;

	int64_t lastRenderPos = -1;
	int64_t lastSpawnDist = -1;
	int64_t lastDespawnDist = -1;
	int64_t lastMainLen = 0;
    int64_t lastTempCount = 0;

	static constexpr int64_t INITIAL_INSERT_SIZE = 1'048'576; // 8 MB in int64_t element
	static constexpr int64_t INITIAL_TEMP_SIZE = 1'048'576; // 8 MB in int64_t element
	static constexpr int64_t INSERT_INCREMENT = 1'048'576; // 8 MB in int64_t element
	static constexpr int64_t TEMP_INCREMENT = 1'048'576; // 8 MB in int64_t element

public:
	bool stagedDirty = true;
	ChartRenderSystem() = default;
	~ChartRenderSystem() { close(); }

	bool createChartFiles(const char* mainPath) {
	#ifdef _WIN32
		_mkdir("temp");
	#else
		mkdir("temp", 0755);
	#endif

		// Paths
		const char* insertPath = "temp/insert";
		const char* tempPath = "temp/temp";

		// Helper to create a file with 'count' int64_t entries
		auto createFileIfMissing = [](const char* path, size_t count = 0) -> bool {
			std::ifstream ifs(path, std::ios::binary);
			if (ifs.good()) return true; // already exists
			ifs.close();

			std::ofstream ofs(path, std::ios::binary | std::ios::trunc);
			if (!ofs.is_open()) return false;

			int64_t zero = 0;
			for (size_t i = 0; i < count; ++i)
				ofs.write(reinterpret_cast<const char*>(&zero), sizeof(zero));

			ofs.close();
			return true;
		};

		// Create main chart (can be empty)
		if (!createFileIfMissing(mainPath, 0)) return false;

		// Insert buffer (initial capacity)
		if (!createFileIfMissing(insertPath, INITIAL_INSERT_SIZE)) return false;

		// Temp buffer
		if (!createFileIfMissing(tempPath, INITIAL_TEMP_SIZE)) return false;

		// Now open all files
		if (!mainFile.open(mainPath)) return false;
		if (!insertFile.open(insertPath)) return false;
		if (!tempFile.open(tempPath)) return false;

		return true;
	}

	bool initialize(const char* mainPath) {
		if (!createChartFiles(mainPath))
			return false;

		// Ensure temp buffer capacity
		return tempFile.resize(tempCapacity);
	}

	// ============================================================================
	void compactChart() {
		int64_t stagedLen = insertCount;
		if (stagedLen <= 0) return; // nothing to compact

		int64_t* stagedData = insertFile.raw();

		// ------------------------
		// Sort staged notes by time (O(k)) if dirty
		// ------------------------
		if (stagedLen > 1 && stagedDirty) {
			vectorizedSort(stagedData, stagedLen);
			stagedDirty = false;
		}

		auto t1 = std::chrono::high_resolution_clock::now();

		int64_t oldLen = mainFile.size();
		int64_t k = stagedLen;
		int64_t newLen = oldLen + k;

		if (!mainFile.resize(newLen))
			throw std::runtime_error("Failed to resize main file for compaction");

		// Refresh mainData pointer after resize
		int64_t* mainData = mainFile.raw();

		#ifdef _WIN32
		int64_t* __restrict writePtr = mainData + newLen - 1;
		int64_t* __restrict dataPtr  = mainData + oldLen - 1;  // safe now
		int64_t* __restrict newPtr   = stagedData + k - 1;
		#else
		int64_t* __restrict__ writePtr = mainData + newLen - 1;
		int64_t* __restrict__ dataPtr  = mainData + oldLen - 1;  // safe now
		int64_t* __restrict__ newPtr   = stagedData + k - 1;
		#endif

		while (dataPtr >= mainData && newPtr >= stagedData) {
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

		while (newPtr >= stagedData) *writePtr-- = *newPtr--;

		// Clear staged notes
		insertCount = 0;

		// Check if the notes are actually sorted. (DEBUG PURPOSES)
		/*bool sorted = true;
		int64_t* mainData2 = mainFile.raw();
		for (int64_t i = 1; i < mainFile.size(); ++i) {
			std::cout << std::to_string(extractTime(mainData2[i])) << std::endl;
		}*/

		auto t2 = std::chrono::high_resolution_clock::now();
		double us = std::chrono::duration_cast<std::chrono::microseconds>(t2 - t1).count();
		std::cout << us << "microseconds" << std::endl;
	}

	void close() {
		compactChart();
		mainFile.close();
		insertFile.close();
		tempFile.close();

		// Delete temp files
		std::remove("temp/insert");
		std::remove("temp/insertCount");
		std::remove("temp/temp");
		std::remove("temp/size");

		// Delete temp directory
		#ifdef _WIN32
			RemoveDirectoryA("temp"); // Only works if folder is empty
		#else
			rmdir("temp"); // Only works if folder is empty
		#endif

		lastRenderPos = lastSpawnDist = lastDespawnDist = lastMainLen = -1;
		insertCount = tempCount = 0;
	}

	inline int64_t extractTime(int64_t note) { return (note >> 24) & ((1 << 40) - 1); }
	inline int64_t extractDuration(int64_t note) { return (note >> 12) & 0xFFF; }

	int64_t getNote(int64_t index) { return mainFile.raw()[index]; }
	int64_t getLength() const { return mainFile.size(); }

	int64_t getTempNote(int64_t index) { return tempFile.raw()[index]; }

	//////////////////////////
	// MULTIPLE VARIANTS OF INSERTS
	// ALL DEAL WITH VERY DIFFERENT TYPES OF PERFORMANCE
	// THE MULTIPLE-ELEMENT VERSIONS RUN IN PARALLEL BY THE WAY, MAKING INSERTIONS FASTER!
	//////////////////////////

	inline void insertNote(int64_t note) {
		int64_t count = insertCount;

		if (count >= insertCapacity) {
			// Increment capacity by 8 MB
			insertCapacity += INSERT_INCREMENT;

			//std::cout << "resize" << std::endl;
			if (!insertFile.resize(insertCapacity))
				throw std::runtime_error("Failed to resize insertFile");
		}

		_mm_stream_si64(&insertFile.raw()[count], note);
		insertCount++;
		stagedDirty = true; // mark staged as dirty
	}

	inline void insertNote32(int64_t n0, int64_t n1, int64_t n2, int64_t n3, int64_t n4, int64_t n5, int64_t n6, int64_t n7,
		int64_t n8, int64_t n9, int64_t n10, int64_t n11, int64_t n12, int64_t n13, int64_t n14, int64_t n15,
		int64_t n16, int64_t n17, int64_t n18, int64_t n19, int64_t n20, int64_t n21, int64_t n22, int64_t n23,
		int64_t n24, int64_t n25, int64_t n26, int64_t n27, int64_t n28, int64_t n29, int64_t n30, int64_t n31) {
		int64_t count = insertCount;

		// Ensure capacity
		if (count + 32 > insertCapacity) {
			while (count + 32 > insertCapacity)
				insertCapacity += INSERT_INCREMENT;

			if (!insertFile.resize(insertCapacity))
				throw std::runtime_error("Failed to resize insertFile");
		}

		int64_t* raw = insertFile.raw();
		_mm_stream_si64(&raw[count + 0], n0); _mm_stream_si64(&raw[count + 1], n1);
		_mm_stream_si64(&raw[count + 2], n2); _mm_stream_si64(&raw[count + 3], n3);
		_mm_stream_si64(&raw[count + 4], n4); _mm_stream_si64(&raw[count + 5], n5);
		_mm_stream_si64(&raw[count + 6], n6); _mm_stream_si64(&raw[count + 7], n7);
		_mm_stream_si64(&raw[count + 8], n8); _mm_stream_si64(&raw[count + 9], n9);
		_mm_stream_si64(&raw[count + 10], n10); _mm_stream_si64(&raw[count + 11], n11);
		_mm_stream_si64(&raw[count + 12], n12); _mm_stream_si64(&raw[count + 13], n13);
		_mm_stream_si64(&raw[count + 14], n14); _mm_stream_si64(&raw[count + 15], n15);
		_mm_stream_si64(&raw[count + 16], n16); _mm_stream_si64(&raw[count + 17], n17);
		_mm_stream_si64(&raw[count + 18], n18); _mm_stream_si64(&raw[count + 19], n19);
		_mm_stream_si64(&raw[count + 20], n20); _mm_stream_si64(&raw[count + 21], n21);
		_mm_stream_si64(&raw[count + 22], n22); _mm_stream_si64(&raw[count + 23], n23);
		_mm_stream_si64(&raw[count + 24], n24); _mm_stream_si64(&raw[count + 25], n25);
		_mm_stream_si64(&raw[count + 26], n26); _mm_stream_si64(&raw[count + 27], n27);
		_mm_stream_si64(&raw[count + 28], n28); _mm_stream_si64(&raw[count + 29], n29);
		_mm_stream_si64(&raw[count + 30], n30); _mm_stream_si64(&raw[count + 31], n31);

		insertCount += 32;
		stagedDirty = true;
	}

	std::vector<int64_t> output;

	#ifdef _WIN32
	void vectorizedSort(int64_t* __restrict arr, int64_t len)
	#else
	void vectorizedSort(int64_t* __restrict__ arr, int64_t len)
	#endif
	{
		if (len <= 1) return;

		const int64_t TIME_SHIFT = 23;
		const int64_t TIME_BITS  = 41;
		const int PASS_BITS = 8;
		const int RADIX = 1 << PASS_BITS;

		std::vector<int64_t> buffer(len);
		#ifdef _WIN32
		int64_t* __restrict src = arr;
		int64_t* __restrict dst = buffer.data();
		#else
		int64_t* __restrict__ src = arr;
		int64_t* __restrict__ dst = buffer.data();
		#endif

		int64_t numPasses = (TIME_BITS + PASS_BITS - 1) / PASS_BITS;
		std::vector<int64_t> count(RADIX);

		for (int64_t pass = 0; pass < numPasses; ++pass) {
			int shift = TIME_SHIFT + pass * PASS_BITS;
			int64_t mask = (1LL << PASS_BITS) - 1;

			std::fill(count.begin(), count.end(), 0);

			// ------------------------
			// Histogram (32-element manual unroll)
			// ------------------------
			int64_t i = 0;
			for (; i + 31 < len; i += 32) {
				count[(src[i+0]  >> shift) & mask]++;
				count[(src[i+1]  >> shift) & mask]++;
				count[(src[i+2]  >> shift) & mask]++;
				count[(src[i+3]  >> shift) & mask]++;
				count[(src[i+4]  >> shift) & mask]++;
				count[(src[i+5]  >> shift) & mask]++;
				count[(src[i+6]  >> shift) & mask]++;
				count[(src[i+7]  >> shift) & mask]++;
				count[(src[i+8]  >> shift) & mask]++;
				count[(src[i+9]  >> shift) & mask]++;
				count[(src[i+10] >> shift) & mask]++;
				count[(src[i+11] >> shift) & mask]++;
				count[(src[i+12] >> shift) & mask]++;
				count[(src[i+13] >> shift) & mask]++;
				count[(src[i+14] >> shift) & mask]++;
				count[(src[i+15] >> shift) & mask]++;
				count[(src[i+16] >> shift) & mask]++;
				count[(src[i+17] >> shift) & mask]++;
				count[(src[i+18] >> shift) & mask]++;
				count[(src[i+19] >> shift) & mask]++;
				count[(src[i+20] >> shift) & mask]++;
				count[(src[i+21] >> shift) & mask]++;
				count[(src[i+22] >> shift) & mask]++;
				count[(src[i+23] >> shift) & mask]++;
				count[(src[i+24] >> shift) & mask]++;
				count[(src[i+25] >> shift) & mask]++;
				count[(src[i+26] >> shift) & mask]++;
				count[(src[i+27] >> shift) & mask]++;
				count[(src[i+28] >> shift) & mask]++;
				count[(src[i+29] >> shift) & mask]++;
				count[(src[i+30] >> shift) & mask]++;
				count[(src[i+31] >> shift) & mask]++;
			}

			for (; i < len; ++i)
				count[(src[i] >> shift) & mask]++;

			// ------------------------
			// Prefix sum
			// ------------------------
			int64_t sum = 0;
			for (int j = 0; j < RADIX; ++j) {
				int64_t tmp = count[j];
				count[j] = sum;
				sum += tmp;
			}

			// ------------------------
			// Scatter (32-element manual unroll)
			// ------------------------
			i = 0;
			for (; i + 31 < len; i += 32) {
				_mm_stream_si64(&dst[count[(src[i+0]  >> shift) & mask]++], src[i+0]);
				_mm_stream_si64(&dst[count[(src[i+1]  >> shift) & mask]++], src[i+1]);
				_mm_stream_si64(&dst[count[(src[i+2]  >> shift) & mask]++], src[i+2]);
				_mm_stream_si64(&dst[count[(src[i+3]  >> shift) & mask]++], src[i+3]);
				_mm_stream_si64(&dst[count[(src[i+4]  >> shift) & mask]++], src[i+4]);
				_mm_stream_si64(&dst[count[(src[i+5]  >> shift) & mask]++], src[i+5]);
				_mm_stream_si64(&dst[count[(src[i+6]  >> shift) & mask]++], src[i+6]);
				_mm_stream_si64(&dst[count[(src[i+7]  >> shift) & mask]++], src[i+7]);
				_mm_stream_si64(&dst[count[(src[i+8]  >> shift) & mask]++], src[i+8]);
				_mm_stream_si64(&dst[count[(src[i+9]  >> shift) & mask]++], src[i+9]);
				_mm_stream_si64(&dst[count[(src[i+10] >> shift) & mask]++], src[i+10]);
				_mm_stream_si64(&dst[count[(src[i+11] >> shift) & mask]++], src[i+11]);
				_mm_stream_si64(&dst[count[(src[i+12] >> shift) & mask]++], src[i+12]);
				_mm_stream_si64(&dst[count[(src[i+13] >> shift) & mask]++], src[i+13]);
				_mm_stream_si64(&dst[count[(src[i+14] >> shift) & mask]++], src[i+14]);
				_mm_stream_si64(&dst[count[(src[i+15] >> shift) & mask]++], src[i+15]);
				_mm_stream_si64(&dst[count[(src[i+16] >> shift) & mask]++], src[i+16]);
				_mm_stream_si64(&dst[count[(src[i+17] >> shift) & mask]++], src[i+17]);
				_mm_stream_si64(&dst[count[(src[i+18] >> shift) & mask]++], src[i+18]);
				_mm_stream_si64(&dst[count[(src[i+19] >> shift) & mask]++], src[i+19]);
				_mm_stream_si64(&dst[count[(src[i+20] >> shift) & mask]++], src[i+20]);
				_mm_stream_si64(&dst[count[(src[i+21] >> shift) & mask]++], src[i+21]);
				_mm_stream_si64(&dst[count[(src[i+22] >> shift) & mask]++], src[i+22]);
				_mm_stream_si64(&dst[count[(src[i+23] >> shift) & mask]++], src[i+23]);
				_mm_stream_si64(&dst[count[(src[i+24] >> shift) & mask]++], src[i+24]);
				_mm_stream_si64(&dst[count[(src[i+25] >> shift) & mask]++], src[i+25]);
				_mm_stream_si64(&dst[count[(src[i+26] >> shift) & mask]++], src[i+26]);
				_mm_stream_si64(&dst[count[(src[i+27] >> shift) & mask]++], src[i+27]);
				_mm_stream_si64(&dst[count[(src[i+28] >> shift) & mask]++], src[i+28]);
				_mm_stream_si64(&dst[count[(src[i+29] >> shift) & mask]++], src[i+29]);
				_mm_stream_si64(&dst[count[(src[i+30] >> shift) & mask]++], src[i+30]);
				_mm_stream_si64(&dst[count[(src[i+31] >> shift) & mask]++], src[i+31]);
			}

			for (; i < len; ++i)
				_mm_stream_si64(&dst[count[(src[i] >> shift) & mask]++], src[i]);

			std::swap(src, dst);
		}

		if (src != arr)
			std::memcpy(arr, src, len);
	}

	// ============================================================================
	// Optimized renderBuffer
	// ============================================================================
	/**
	 * Time Complexity:
	 *   O(k) for sorting staged notes using radix sort (3-pass to 5-pass for 41-bit time)
	 *   O(log n) for binary search in main notes
	 *   O(log k) for binary search in staged notes
	 *   O(n + k) for merging active notes
	 * Overall worst-case: O(n + k)
	 ** Note: `n` does NOT mean `mainFile`'s size.
	 	Rather, it varies on a very small scale depending on `spawnDist` and `despawnDist`.
	 */
	inline void mergeSorted(int64_t* dst,
						int64_t* a, int64_t na,
						int64_t* b, int64_t nb) {
		int64_t i = 0, j = 0, k = 0;
		while (i < na && j < nb) {
			if (extractTime(a[i]) <= extractTime(b[j]))
				dst[k++] = a[i++];
			else
				dst[k++] = b[j++];
		}
		while (i < na) dst[k++] = a[i++];
		while (j < nb) dst[k++] = b[j++];
	}

	void renderBuffer(int64_t pos, int64_t spawnDist, int64_t despawnDist, int64_t* bounds) { 
		if (!bounds) return;

		/*std::cout << "Cache check: pos=" << (pos == lastRenderPos) 
          << " spawn=" << (spawnDist == lastSpawnDist)
          << " despawn=" << (despawnDist == lastDespawnDist)
          << " mainLen=" << (mainFile.size() == lastMainLen)
          << " dirty=" << stagedDirty << std::endl;*/

		// Early exit if results are already valid - CHECK THIS FIRST
        if (pos == lastRenderPos && 
            spawnDist == lastSpawnDist && 
            despawnDist == lastDespawnDist &&
            mainFile.size() == lastMainLen &&
            !stagedDirty) {
            bounds[0] = 0;
            bounds[1] = lastTempCount;  // Use cached value
            return;
        }

		int64_t spawnTime   = pos + spawnDist;
		int64_t despawnTime = pos - despawnDist;

		int64_t mainLen   = mainFile.size();
		int64_t stagedLen = insertCount;
		
		if (mainLen + stagedLen == 0) {
			tempCount = 0;
			bounds[0] = bounds[1] = 0;
			return;
		}

		int64_t* tempData   = tempFile.raw();
		int64_t* mainData   = mainFile.raw();
		int64_t* stagedData = insertFile.raw();

		// ------------------------
		// Sort staged notes once if dirty
		// ------------------------
		if (stagedLen > 1 && stagedDirty) {
			vectorizedSort(stagedData, stagedLen);
			stagedDirty = false;
		}

		// ------------------------
		// Find active main notes using binary search
		// ------------------------
		int64_t mainStart = 0, mainEnd = mainLen;
		{
			int64_t lo = 0, hi = mainLen;
			while (lo < hi) {
				int64_t mid = (lo + hi) >> 1;
				int64_t t = extractTime(mainData[mid]);
				int64_t d = extractDuration(mainData[mid]);
				int64_t despawnLimit = t + ((d << 2) + d) * 80000;

				if (despawnLimit < despawnTime)
					lo = mid + 1;
				else
					hi = mid;
			}
			mainStart = lo;

			lo = mainStart; hi = mainLen;
			while (lo < hi) {
				int64_t mid = (lo + hi) >> 1;
				if (extractTime(mainData[mid]) <= spawnTime)
					lo = mid + 1;
				else
					hi = mid;
			}
			mainEnd = lo;
		}

		// ------------------------
		// Find active staged notes using binary search
		// ------------------------
		int64_t stagedStart = 0, stagedEnd = stagedLen;
		if (stagedLen > 0) {
			int64_t lo = 0, hi = stagedLen;
			while (lo < hi) {
				int64_t mid = (lo + hi) >> 1;
				int64_t t = extractTime(stagedData[mid]);
				int64_t d = extractDuration(stagedData[mid]);
				int64_t despawnLimit = t + ((d << 2) + d) * 80000;

				if (despawnLimit < despawnTime)
					lo = mid + 1;
				else
					hi = mid;
			}
			stagedStart = lo;

			lo = stagedStart; hi = stagedLen;
			while (lo < hi) {
				int64_t mid = (lo + hi) >> 1;
				if (extractTime(stagedData[mid]) <= spawnTime)
					lo = mid + 1;
				else
					hi = mid;
			}
			stagedEnd = lo;
		}

		// ------------------------
		// Merge active main + staged notes into temp buffer
		// ------------------------
		int64_t mainCount   = mainEnd   - mainStart;
		int64_t stagedCount = stagedEnd - stagedStart;
		int64_t tempCountLocal   = mainCount + stagedCount;

		if (tempCountLocal > 0) {
			// Ensure temp capacity
			if (tempCapacity < tempCountLocal) {
				while (tempCapacity < tempCountLocal)
					tempCapacity += TEMP_INCREMENT;

				if (!tempFile.resize(tempCapacity))
					throw std::runtime_error("Failed to resize temp buffer");
				tempData = tempFile.raw(); // pointer may have changed
			}

			// Merge instead of copy+sort
			mergeSorted(tempData,
						mainData + mainStart, mainCount,
						stagedData + stagedStart, stagedCount);
		}

		tempCount = tempCountLocal;

		lastRenderPos   = pos;
		lastSpawnDist   = spawnDist;
		lastDespawnDist = despawnDist;
    	lastMainLen     = mainLen;  // Add this member variable
        lastTempCount = tempCountLocal;  // Cache it

		bounds[0] = 0;
		bounds[1] = tempCountLocal;
	}
};

// ============================================================================
// Global API
// ============================================================================
static ChartRenderSystem gSystem;

bool loadChart(const char* path) { return gSystem.initialize(path); }
void destroyChart() { gSystem.close(); }

int64_t getNote(int64_t index) { return gSystem.getNote(index); }
int64_t getLength() { return gSystem.getLength(); }
int64_t getTempNote(int64_t index) { return gSystem.getTempNote(index); }

// Variants of insertNote
void insertNote(int64_t note) { gSystem.insertNote(note); }
void insertNote32(int64_t note1, int64_t note2, int64_t note3, int64_t note4,
	int64_t note5, int64_t note6, int64_t note7, int64_t note8,
	int64_t note9, int64_t note10, int64_t note11, int64_t note12,
	int64_t note13, int64_t note14, int64_t note15, int64_t note16,
	int64_t note17, int64_t note18, int64_t note19, int64_t note20,
	int64_t note21, int64_t note22, int64_t note23, int64_t note24,
	int64_t note25, int64_t note26, int64_t note27, int64_t note28,
	int64_t note29, int64_t note30, int64_t note31, int64_t note32) {
	gSystem.insertNote32(note1, note2, note3, note4, note5, note6, note7, note8,
		note9, note10, note11, note12, note13, note14, note15, note16,
		note17, note18, note19, note20, note21, note22, note23, note24,
		note25, note26, note27, note28, note29, note30, note31, note32
	);
}
// end

// render buffer
void renderBuffer(int64_t pos, int64_t spawnDist, int64_t despawnDist, int64_t* bounds) {
	gSystem.renderBuffer(pos, spawnDist, despawnDist, bounds);
}

// ============================================================================
// Example
// ============================================================================

// Helper to encode a note (time << 23) | duration
int64_t encodeNote(int64_t time, int duration, int index, int type) {
    return 
        ((time & ((1LL << 40) - 1)) << 24) |  // 1LL = 64-bit literal
        ((duration & 0xFFF) << 12) |
        ((index & 0xF)    << 8) |
        ((type & 0x1F)    << 3) |
        (0 << 2) | (0 << 1) | 0;
}