#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <algorithm>
#include <unordered_map>
#include <thread>
#include <atomic>
#include <exception>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#undef NOMINMAX
#else
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#endif

#ifndef CHART_FILE_NO_TRANSPILER
#include "./include/rapidjson/document.h"
#include "./include/rapidjson/istreamwrapper.h"
#include "./include/rapidjson/ostreamwrapper.h"
#include "./include/rapidjson/prettywriter.h"
#include "./include/rapidjson/error/en.h"
#endif

template <class MainFn, class WorkerFn>
static void chart_dual_run(MainFn&& mainFn, WorkerFn&& workerFn) {
	std::exception_ptr workerErr;
	std::thread worker;
	try {
		worker = std::thread([&workerFn, &workerErr]() {
			try { workerFn(); } catch (...) { workerErr = std::current_exception(); }
		});
	} catch (...) {
		workerFn();
		mainFn();
		return;
	}
	try { mainFn(); }
	catch (...) { worker.join(); throw; }
	worker.join();
	if (workerErr) std::rethrow_exception(workerErr);
}

class BitArray {
	std::vector<uint8_t> data;
	size_t count = 0;
	size_t ones = 0;
public:
	void init(size_t n) {
		count = n;
		ones = 0;
		data.assign((n + 7) / 8, 0);
	}
	bool get(size_t i) const {
		if (i >= count) return false;
		return (data[i >> 3] >> (i & 7)) & 1;
	}
	void set(size_t i, bool val) {
		if (i >= count) return;
		const uint8_t mask = (uint8_t)(1u << (i & 7));
		const bool was = (data[i >> 3] & mask) != 0;
		if (was == val) return;
		if (val) { data[i >> 3] |= mask; ++ones; }
		else { data[i >> 3] &= (uint8_t)~mask; --ones; }
	}
	void insert(size_t i, bool val) {
		if (i > count) i = count;
		const size_t newCount = count + 1;
		const size_t newBytes = (newCount + 7) / 8;
		if (data.size() < newBytes) data.push_back(0);
		if (ones == 0) {
			count = newCount;
			if (val) { data[i >> 3] |= (uint8_t)(1u << (i & 7)); ++ones; }
			return;
		}
		const size_t startByte = i >> 3;
		const size_t endByte = (count >> 3) + 1;
		for (size_t b = endByte; b-- > startByte + 1;) {
			data[b] = (uint8_t)((data[b] << 1) | ((data[b - 1] >> 7) & 1u));
		}
		const uint8_t shift = (uint8_t)(i & 7);
		const uint8_t lo = data[startByte] & (uint8_t)((1u << shift) - 1);
		const uint8_t hi = (uint8_t)(data[startByte] >> shift);
		data[startByte] = (uint8_t)(lo
			| ((uint8_t)(val ? 1u : 0u) << shift)
			| (uint8_t)(hi << 1));
		if (val) ++ones;
		count = newCount;
	}
	void erase(size_t i) {
		if (i >= count) return;
		if (ones == 0) {
			--count;
			if (count % 8 == 0 && !data.empty()) data.pop_back();
			return;
		}
		const bool removed = get(i);
		const size_t startByte = i >> 3;
		const size_t endByte = (count + 7) >> 3;
		const uint8_t shift = (uint8_t)(i & 7);
		const uint8_t nextBit0 = (startByte + 1 < endByte)
			? (uint8_t)(data[startByte + 1] << 7) : 0;
		for (size_t b = startByte + 1; b < endByte; ++b) {
			const uint8_t carry = (b + 1 < endByte) ? (uint8_t)(data[b + 1] << 7) : 0;
			data[b] = (uint8_t)((data[b] >> 1) | carry);
		}
		const uint8_t lo = data[startByte] & (uint8_t)((1u << shift) - 1);
		const uint8_t hi = (uint8_t)(data[startByte] >> (shift + 1));
		data[startByte] = (uint8_t)(lo | (uint8_t)(hi << shift) | nextBit0);
		--count;
		if (removed) --ones;
		if (count % 8 != 0) {
			set(count, false);
		}
		else if (!data.empty()) {
			data.pop_back();
		}
	}
	size_t size() const { return count; }
	bool anySet() const { return ones != 0; }
};

#pragma pack(push, 1)
struct ChartNote {
	uint64_t first8;
	uint32_t last4;
};
#pragma pack(pop)
static_assert(sizeof(ChartNote) == 12, "ChartNote must be exactly 12 bytes!");
static_assert(sizeof(ChartNote) % 4 == 0, "ChartNote must stay 4-byte aligned!");

static inline ChartNote packNote(uint64_t position, uint32_t duration, uint32_t index, uint32_t type, uint32_t lane) {
	ChartNote n;
	n.first8 = (position & 0x0000FFFFFFFFFFFFULL) | ((uint64_t)(duration & 0xFFFF) << 48);
	n.last4 = ((duration >> 16) & 0xFF)
		| ((index & 0x3FF) << 8)
		| ((type & 0xFF) << 18)
		| ((lane & 0x3F) << 26);
	return n;
}
static inline uint64_t notePos(const ChartNote& n) { return n.first8 & 0x0000FFFFFFFFFFFFULL; }
static inline uint32_t noteDur(const ChartNote& n) { return (uint32_t)(n.first8 >> 48) | ((n.last4 & 0xFF) << 16); }
static inline uint32_t noteIdx(const ChartNote& n) { return (n.last4 >> 8) & 0x3FF; }
static inline uint32_t noteType(const ChartNote& n) { return (n.last4 >> 18) & 0xFF; }
static inline uint32_t noteLane(const ChartNote& n) { return (n.last4 >> 26) & 0x3F; }

#pragma pack(push, 1)
struct Fvc3Header {
	char     magic[4];
	uint32_t noteCount;
	uint32_t payloadBytes;
	uint8_t  codec;
	uint8_t  pad[3];
};
#pragma pack(pop)
static_assert(sizeof(Fvc3Header) == 16, "Fvc3Header must be exactly 16 bytes!");

static constexpr uint8_t  FVC3_CODEC_GRID_KIND = 0;
static constexpr uint8_t  FVC3_CODEC_RAW = 1;
static constexpr uint8_t  FVC3_CODEC_ROWS = 2;
static constexpr uint8_t  FVC3_CODEC_AC = 3;
static constexpr uint16_t FVC3_MAX_KINDS = 4096;
static constexpr uint32_t FVC3_ROWS_MAX_ROW = 255;

#pragma pack(push, 1)
struct Fvc4Header {
	char     magic[4];
	uint32_t noteCount;
	uint32_t segCount;
};
struct Fvc4SegEntry {
	uint64_t startTick;
	uint32_t noteCount;
	uint32_t imageBytes;
};
#pragma pack(pop)
static_assert(sizeof(Fvc4Header) == 12, "Fvc4Header must be exactly 12 bytes!");
static_assert(sizeof(Fvc4SegEntry) == 16, "Fvc4SegEntry must be exactly 16 bytes!");

static uint64_t fvc3_gcd(uint64_t a, uint64_t b) {
	while (b) { const uint64_t t = a % b; a = b; b = t; }
	return a;
}

struct Fvc3BitW {
	std::vector<uint8_t>& out;
	uint32_t acc = 0; int nbits = 0;
	explicit Fvc3BitW(std::vector<uint8_t>& o) : out(o) {}
	void put(uint32_t v, int bits) {
		acc |= (v & 0xFFFFu) << nbits;
		nbits += bits;
		while (nbits >= 8) { out.push_back((uint8_t)(acc & 0xFF)); acc >>= 8; nbits -= 8; }
	}
	void putVarint(uint64_t v) {
		while (v >= 0x80) { put((uint32_t)((v & 0x7F) | 0x80), 8); v >>= 7; }
		put((uint32_t)v, 8);
	}
	void flush() { if (nbits > 0) { out.push_back((uint8_t)(acc & 0xFF)); acc = 0; nbits = 0; } }
};

struct Fvc3BitR {
	const uint8_t* p; const uint8_t* end; uint32_t acc = 0; int nbits = 0;
	Fvc3BitR(const uint8_t* p_, const uint8_t* end_) : p(p_), end(end_) {}
	bool take(uint32_t& v, int bits) {
		if (bits == 0) { v = 0; return true; }
		while (nbits < bits) {
			if (p >= end) return false;
			acc |= (uint32_t)(*p++) << nbits;
			nbits += 8;
		}
		v = acc & ((1u << bits) - 1u);
		acc >>= bits; nbits -= bits;
		return true;
	}
	bool takeVarint(uint64_t& v) {
		v = 0; int shift = 0;
		for (;;) {
			uint32_t g;
			if (!take(g, 8)) return false;
			v |= (uint64_t)(g & 0x7F) << shift;
			if (!(g & 0x80)) return true;
			shift += 7;
			if (shift > 63) return false;
		}
	}
	bool consumedExactly() const {
		return p == end && nbits < 8;
	}
};

static int fvc3_kindBits(uint64_t kindCount) {
	int bits = 1;
	while ((1ULL << bits) < kindCount) ++bits;
	return bits;
}

static inline void blob_putu(std::vector<uint8_t>& out, uint64_t v) {
	while (v >= 0x80) {
		out.push_back((uint8_t)(v | 0x80));
		v >>= 7;
	}
	out.push_back((uint8_t)v);
}

static inline const uint8_t* blob_getu(const uint8_t* p, const uint8_t* end, uint64_t& v) {
	v = 0;
	int shift = 0;
	while (p < end) {
		const uint64_t b = (uint64_t)(*p++);
		v |= (b & 0x7F) << shift;
		if ((b & 0x80) == 0) return p;
		shift += 7;
		if (shift > 63) break;
	}
	return nullptr;
}

static inline void blob_puti(std::vector<uint8_t>& out, int64_t v) {
	blob_putu(out, (uint64_t)((v << 1) ^ (v >> 63)));
}

static inline const uint8_t* blob_geti(const uint8_t* p, const uint8_t* end, int64_t& v) {
	uint64_t u;
	p = blob_getu(p, end, u);
	if (!p) return nullptr;
	v = (int64_t)((u >> 1) ^ (~(u & 1) + 1));
	return p;
}

static void fvc3_rows_encode(const ChartNote* notes, size_t n, uint64_t grid,
	std::vector<uint8_t>& out,
	const std::vector<uint32_t>* kindsIn = nullptr,
	const std::vector<uint32_t>* idsIn = nullptr) {
	std::vector<uint32_t> kindsLocal;
	std::vector<uint32_t> idsLocal;
	if (!kindsIn || !idsIn) {
		std::unordered_map<uint32_t, uint32_t> kindId;
		idsLocal.resize(n);
		for (size_t i = 0; i < n; ++i) {
			const uint32_t k = (noteIdx(notes[i]) << 16) | (noteType(notes[i]) << 8) | noteLane(notes[i]);
			auto it = kindId.find(k);
			uint32_t id;
			if (it == kindId.end()) {
				kindsLocal.push_back(k);
				id = (uint32_t)(kindsLocal.size() - 1);
				kindId.emplace(k, id);
			}
			else {
				id = it->second;
			}
			idsLocal[i] = id;
		}
	}
	const std::vector<uint32_t>& kinds = kindsIn ? *kindsIn : kindsLocal;
	const std::vector<uint32_t>& ids = idsIn ? *idsIn : idsLocal;

	uint64_t durUnit = 1;
	{
		uint64_t g = 0;
		for (size_t i = 0; i < n; ++i) {
			const uint32_t d = noteDur(notes[i]);
			if (d != 0) { g = g ? fvc3_gcd(g, d) : d; if (g == 1) break; }
		}
		if (g > 1) durUnit = g;
	}
	const bool durGrid = durUnit > 1;
	const int kindBits = fvc3_kindBits(kinds.size());

	struct RowRec { uint64_t gpos; uint32_t len; };
	std::vector<RowRec> rows;
	rows.reserve(n);
	std::unordered_map<uint64_t, uint32_t> gapHist;
	uint64_t prevPos = 0;
	size_t i = 0;
	while (i < n) {
		size_t j = i;
		const uint64_t pos = notePos(notes[i]);
		while (j < n && notePos(notes[j]) == pos
			&& (j - i) < (size_t)FVC3_ROWS_MAX_ROW) ++j;
		const uint64_t gpos = pos / grid;
		++gapHist[gpos - prevPos];
		rows.push_back({ gpos, (uint32_t)(j - i) });
		prevPos = gpos;
		i = j;
	}
	uint64_t gapCode[3] = { 1, 1, 1 };
	{
		std::vector<std::pair<uint64_t, uint32_t>> gapHistV(gapHist.begin(), gapHist.end());
		std::sort(gapHistV.begin(), gapHistV.end(), [](const std::pair<uint64_t, uint32_t>& a,
			const std::pair<uint64_t, uint32_t>& b) {
				if (a.second != b.second) return a.second > b.second;
				return a.first < b.first;
			});
		for (int c = 0; c < 3 && c < (int)gapHistV.size(); ++c)
			gapCode[c] = gapHistV[(size_t)c].first;
	}
	blob_putu(out, grid);
	blob_putu(out, (uint64_t)kinds.size());
	for (uint32_t k : kinds) blob_putu(out, k);
	blob_putu(out, gapCode[0]);
	blob_putu(out, gapCode[1]);
	blob_putu(out, gapCode[2]);

	Fvc3BitW bw(out);
	bw.put(durGrid ? 1u : 0u, 1);
	if (durGrid) bw.putVarint(durUnit);
	prevPos = 0;
	int64_t prevDur = 0;
	size_t noteI = 0;
	for (const RowRec& r : rows) {
		const uint64_t gap = r.gpos - prevPos;
		int code = -1;
		for (int c = 0; c < 3; ++c)
			if (gapCode[c] == gap) { code = c; break; }
		if (code >= 0) bw.put((uint32_t)code, 2);
		else { bw.put(3u, 2); bw.putVarint(gap); }
		const uint64_t cnt = (uint64_t)(r.len - 1);
		if (cnt < 3) bw.put((uint32_t)cnt, 2);
		else { bw.put(3u, 2); bw.putVarint(cnt); }
		for (uint32_t m = 0; m < r.len; ++m, ++noteI) {
			bw.put(ids[noteI], kindBits);
			const uint32_t d = noteDur(notes[noteI]);
			if (d != 0) {
				bw.put(1u, 1);
				const int64_t abs = durGrid ? (int64_t)(d / durUnit) : (int64_t)d;
				const int64_t dv = abs - prevDur;
				bw.putVarint((uint64_t)((dv << 1) ^ (dv >> 63)));
				prevDur = abs;
			}
			else {
				bw.put(0u, 1);
			}
		}
		prevPos = r.gpos;
	}
	bw.flush();
}

static bool fvc3_rows_decode(const uint8_t* data, size_t size, uint32_t noteCount,
	std::vector<ChartNote>& out) {
	const uint8_t* p = data;
	const uint8_t* end = data + size;
	uint64_t grid = 0, kindCount = 0;
	p = blob_getu(p, end, grid);
	p = blob_getu(p, end, kindCount);
	if (!p || grid == 0 || kindCount == 0 || kindCount > FVC3_MAX_KINDS
		|| kindCount > noteCount) return false;
	std::vector<uint32_t> kinds((size_t)kindCount);
	for (uint64_t i = 0; i < kindCount; ++i) {
		uint64_t k = 0;
		p = blob_getu(p, end, k);
		if (!p || (k >> 24) != 0) return false;
		kinds[(size_t)i] = (uint32_t)k;
	}
	uint64_t gapCode[3] = { 1, 1, 1 };
	p = blob_getu(p, end, gapCode[0]);
	p = blob_getu(p, end, gapCode[1]);
	p = blob_getu(p, end, gapCode[2]);
	if (!p) return false;

	Fvc3BitR br(p, end);
	uint32_t durGridBit = 0;
	if (!br.take(durGridBit, 1)) return false;
	const bool durGrid = durGridBit != 0;
	uint64_t durUnit = 1;
	if (durGrid) {
		if (!br.takeVarint(durUnit) || durUnit < 2) return false;
	}
	const int kindBits = fvc3_kindBits(kindCount);
	out.clear();
	out.reserve(noteCount);
	uint64_t pos = 0;
	int64_t prevDur = 0;
	while (out.size() < noteCount) {
		uint32_t gc = 0;
		if (!br.take(gc, 2)) return false;
		uint64_t gap;
		if (gc < 3) gap = gapCode[gc];
		else { if (!br.takeVarint(gap)) return false; }
		if (pos > 0xFFFFFFFFFFFFULL - gap) return false;
		pos += gap;
		uint32_t cc = 0;
		if (!br.take(cc, 2)) return false;
		uint64_t cnt;
		if (cc < 3) cnt = cc + 1;
		else {
			uint64_t c1 = 0;
			if (!br.takeVarint(c1)) return false;
			if (c1 > FVC3_ROWS_MAX_ROW - 1) return false;
			cnt = c1 + 1;
		}
		if (cnt < 1 || cnt > FVC3_ROWS_MAX_ROW) return false;
		if (out.size() + cnt > (uint64_t)noteCount) return false;
		if (pos > 0xFFFFFFFFFFFFULL / grid) return false;
		const uint64_t absPos = pos * grid;
		for (uint64_t m = 0; m < cnt; ++m) {
			uint32_t id = 0, flag = 0;
			if (!br.take(id, kindBits)) return false;
			if (id >= kindCount) return false;
			if (!br.take(flag, 1)) return false;
			uint32_t dur = 0;
			if (flag) {
				uint64_t zz;
				if (!br.takeVarint(zz)) return false;
				const int64_t dv = (int64_t)((zz >> 1) ^ -(int64_t)(zz & 1));
				if (dv > (int64_t)0x7FFFFFFFFFFLL || dv < -(int64_t)0x7FFFFFFFFFFLL) return false;
				const int64_t raw = prevDur + dv;
				prevDur = raw;
				if (raw < 0 || raw > 0xFFFFFF) return false;
				if (durGrid) {
					if (raw > 0xFFFFFF / (int64_t)durUnit) return false;
					dur = (uint32_t)(raw * (int64_t)durUnit);
				}
				else {
					dur = (uint32_t)raw;
				}
			}
			const uint32_t k = kinds[id];
			out.push_back(packNote(absPos, dur, (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F));
		}
	}
	return br.consumedExactly();
}

struct Fvc3AcEnc {
	std::vector<uint8_t>& out;
	uint64_t low = 0;
	uint32_t range = 0xFFFFFFFFu;
	uint8_t cache = 0;
	uint64_t cacheSize = 1;
	explicit Fvc3AcEnc(std::vector<uint8_t>& o) : out(o) {}
	void shiftLow() {
		if ((uint32_t)low < 0xFF000000u || (int)(low >> 32) != 0) {
			const uint8_t carry = (uint8_t)(low >> 32);
			out.push_back((uint8_t)(cache + carry));
			while (--cacheSize) out.push_back((uint8_t)(0xFF + carry));
			cache = (uint8_t)(low >> 24);
		}
		cacheSize++;
		low = (uint32_t)((uint32_t)low << 8);
	}
	void bit(uint16_t& p, uint32_t b) {
		const uint32_t bound = (range >> 11) * p;
		if (b == 0) { range = bound; p = (uint16_t)(p + ((2048 - p) >> 5)); }
		else { low += bound; range -= bound; p = (uint16_t)(p - (p >> 5)); }
		while ((range >> 24) == 0) { shiftLow(); range <<= 8; }
	}
	void flush() { for (int i = 0; i < 5; ++i) shiftLow(); }
};

struct Fvc3AcDec {
	const uint8_t* p; const uint8_t* end;
	uint32_t range = 0xFFFFFFFFu;
	uint32_t code = 0;
	bool bad = false;
	Fvc3AcDec(const uint8_t* p_, const uint8_t* end_) : p(p_), end(end_) {
		for (int i = 0; i < 5; ++i) code = (code << 8) | nextByte();
	}
	uint8_t nextByte() { if (p >= end) { bad = true; return 0; } return *p++; }
	uint32_t bit(uint16_t& prob) {
		if (bad) return 0;
		const uint32_t bound = (range >> 11) * prob;
		uint32_t b;
		if (code < bound) { range = bound; prob = (uint16_t)(prob + ((2048 - prob) >> 5)); b = 0; }
		else { code -= bound; range -= bound; prob = (uint16_t)(prob - (prob >> 5)); b = 1; }
		while ((range >> 24) == 0) { range <<= 8; code = (code << 8) | nextByte(); }
		return b;
	}
};

static const uint16_t FVC3_AC_P_INIT = 1024;
static const int FVC3_AC_VARINT_GROUPS = 10;

static void fvc3_ac_putU(Fvc3AcEnc& rc, uint16_t* probs, uint64_t v) {
	int gi = 0;
	for (;;) {
		const uint32_t g = (uint32_t)(v & 0x7F);
		v >>= 7;
		const uint32_t cont = v != 0 ? 1u : 0u;
		for (int b = 0; b < 7; ++b) rc.bit(probs[gi * 8 + b], (g >> b) & 1u);
		rc.bit(probs[gi * 8 + 7], cont);
		if (!cont) break;
		if (++gi >= FVC3_AC_VARINT_GROUPS) break;
	}
}

static uint64_t fvc3_ac_getU(Fvc3AcDec& rc, uint16_t* probs) {
	uint64_t v = 0; int shift = 0;
	for (int gi = 0; gi < FVC3_AC_VARINT_GROUPS; ++gi) {
		uint32_t g = 0;
		for (int b = 0; b < 7; ++b) g |= rc.bit(probs[gi * 8 + b]) << b;
		v |= (uint64_t)g << shift;
		if (!rc.bit(probs[gi * 8 + 7])) break;
		shift += 7;
	}
	return v;
}

static void fvc3_ac_putTree(Fvc3AcEnc& rc, uint16_t* probs, int nbits, uint32_t sym) {
	uint32_t m = 1;
	for (int i = nbits - 1; i >= 0; --i) {
		const uint32_t b = (sym >> i) & 1u;
		rc.bit(probs[m], b);
		m = (m << 1) | b;
	}
}

static uint32_t fvc3_ac_getTree(Fvc3AcDec& rc, uint16_t* probs, int nbits) {
	uint32_t m = 1;
	for (int i = 0; i < nbits; ++i) m = (m << 1) | rc.bit(probs[m]);
	return m - (1u << nbits);
}

static uint32_t fvc3_ac_gapCtx(uint64_t g, bool inRun) {
	return (g == 0 ? 0u : g <= 4 ? (uint32_t)g : 5u) + (inRun ? 6u : 0u);
}

static uint32_t fvc3_ac_cntCtx(uint64_t c) { return c <= 3 ? (uint32_t)(c - 1) : 3u; }

static int fvc3_ac_kindBits(uint64_t kindCount) {
	int bits = 1;
	while ((1ULL << bits) < kindCount) ++bits;
	return bits;
}

struct Fvc3AcModels {
	static const int GCTX = 12;
	uint16_t gapSame[GCTX], gapIs0[GCTX], gapIs1[GCTX], gapIs2[GCTX],
		gapIs3[GCTX], gapIs4[GCTX];
	uint16_t gapVar[FVC3_AC_VARINT_GROUPS * 8];
	uint16_t cntSame[4], cntIs1[4], cntIs2[4], cntIs3[4];
	uint16_t cntVar[FVC3_AC_VARINT_GROUPS * 8];
	std::vector<uint16_t> kind;
	bool kindCtx = false;
	int kindBits = 1;
	uint64_t kindCount = 1;
	uint16_t flag[8];
	uint16_t durZero;
	uint16_t durVar[FVC3_AC_VARINT_GROUPS * 8];
	uint16_t tableVar[FVC3_AC_VARINT_GROUPS * 8];
	uint16_t matchBit[8];
	void init(uint64_t kindCount_) {
		for (int i = 0; i < GCTX; ++i)
			gapSame[i] = gapIs0[i] = gapIs1[i] = gapIs2[i] = gapIs3[i] = gapIs4[i] = FVC3_AC_P_INIT;
		for (auto& x : gapVar) x = FVC3_AC_P_INIT;
		for (int i = 0; i < 4; ++i)
			cntSame[i] = cntIs1[i] = cntIs2[i] = cntIs3[i] = FVC3_AC_P_INIT;
		for (auto& x : cntVar) x = FVC3_AC_P_INIT;
		kindCount = kindCount_;
		kindBits = fvc3_ac_kindBits(kindCount);
		kindCtx = kindCount > 1 && kindCount <= 64;
		const size_t trees = kindCtx ? (size_t)kindCount : 1;
		kind.assign(trees * ((size_t)1 << kindBits), FVC3_AC_P_INIT);
		for (auto& x : flag) x = FVC3_AC_P_INIT;
		durZero = FVC3_AC_P_INIT;
		for (auto& x : durVar) x = FVC3_AC_P_INIT;
		for (auto& x : tableVar) x = FVC3_AC_P_INIT;
		for (auto& x : matchBit) x = FVC3_AC_P_INIT;
	}
};

static uint64_t fvc3_ac_notesHash(const ChartNote* notes, size_t n) {
	uint64_t h = 0xcbf29ce484222325ull;
	for (size_t i = 0; i < n; ++i) {
		const uint8_t* b = reinterpret_cast<const uint8_t*>(&notes[i]);
		for (size_t k = 0; k < sizeof(ChartNote); ++k) { h ^= b[k]; h *= 0x100000001b3ull; }
	}
	return h;
}

static void fvc3_ac_encode(const ChartNote* notes, size_t n, uint64_t grid,
	std::vector<uint8_t>& out) {
	std::vector<uint32_t> kinds;
	std::unordered_map<uint32_t, uint32_t> kid;
	{
		for (size_t i = 0; i < n; ++i) {
			const uint32_t k = (noteIdx(notes[i]) << 16) | (noteType(notes[i]) << 8) | noteLane(notes[i]);
			if (kid.emplace(k, (uint32_t)kinds.size()).second) kinds.push_back(k);
		}
		std::sort(kinds.begin(), kinds.end());
		for (size_t i = 0; i < kinds.size(); ++i) kid[kinds[i]] = (uint32_t)i;
	}
	std::vector<uint32_t> ids(n);
	for (size_t i = 0; i < n; ++i) {
		const uint32_t k = (noteIdx(notes[i]) << 16) | (noteType(notes[i]) << 8) | noteLane(notes[i]);
		ids[i] = kid.find(k)->second;
	}
	uint64_t durUnit = 1;
	{
		uint64_t g = 0;
		for (size_t i = 0; i < n; ++i) {
			const uint32_t d = noteDur(notes[i]);
			if (d != 0) { g = g ? fvc3_gcd(g, d) : d; if (g == 1) break; }
		}
		if (g > 1) durUnit = g;
	}
	blob_putu(out, grid);
	blob_putu(out, (uint64_t)kinds.size());
	blob_putu(out, durUnit);
	const uint64_t hash = fvc3_ac_notesHash(notes, n);
	for (int i = 0; i < 8; ++i) out.push_back((uint8_t)(hash >> (8 * i)));

	Fvc3AcModels M;
	M.init(kinds.size());
	Fvc3AcEnc rc(out);
	{
		uint32_t prev = 0;
		for (uint32_t k : kinds) { fvc3_ac_putU(rc, M.tableVar, k - prev); prev = k; }
	}

	static const size_t FVC3_AC_MATCH_ROWS = 4096;
	std::vector<uint64_t> rowGap, rowCnt, rowOff;
	std::vector<uint32_t> rowKinds, rowDurs;
	rowOff.push_back(0);
	rowGap.reserve(n / 2 + 1);
	rowCnt.reserve(n / 2 + 1);
	rowOff.reserve(n / 2 + 2);
	rowKinds.reserve(n);
	rowDurs.reserve(n);
	std::vector<int32_t> matchTable(FVC3_AC_MATCH_ROWS, -1);

	uint64_t prevGap = 0, prevCount = 1, prevPos = 0;
	uint32_t prevKind = 0, prevKind2 = 0;
	int sinceSustain = 7;
	int64_t prevDur = 0;
	int32_t prevSrc = -1;
	bool prevWasHit = false;
	size_t i = 0;
	while (i < n) {
		size_t j = i;
		const uint64_t pos = notePos(notes[i]);
		while (j < n && notePos(notes[j]) == pos && (j - i) < FVC3_ROWS_MAX_ROW) ++j;
		const uint64_t gpos = pos / grid;
		const uint64_t gap = gpos - prevPos;
		const uint32_t h = (uint32_t)((prevGap * 0x9E3779B97F4A7C15ull
			+ prevCount * 0xC2B2AE3D27D4EB4Full
			+ (uint64_t)prevKind * 0x165667B19E3779F9ull
			+ (uint64_t)prevKind2 * 0x27D4EB2F165667C5ull
			+ (uint64_t)(sinceSustain < 7 ? sinceSustain : 7)) & (FVC3_AC_MATCH_ROWS - 1));
		int32_t predRow = -1;
		if (prevSrc >= 0 && prevSrc + 1 < (int32_t)rowGap.size())
			predRow = prevSrc + 1;
		if (predRow < 0) predRow = matchTable[h];
		if (predRow >= 0) {
			const size_t prBeg = (size_t)rowOff[(size_t)predRow];
			const size_t prLen = (size_t)rowCnt[(size_t)predRow];
			const uint64_t prGap = rowGap[(size_t)predRow];
			bool hit = prGap == gap && prLen == (size_t)(j - i);
			if (hit) {
				for (size_t m = i; m < j; ++m) {
					const uint32_t dd = noteDur(notes[m]);
					if (m - i >= prLen
						|| rowKinds[prBeg + (m - i)] != ids[m]
						|| rowDurs[prBeg + (m - i)] != (dd == 0 ? 0u : (durUnit > 1 ? dd / durUnit : dd))) {
						hit = false; break;
					}
				}
			}
			if (hit) {
				rc.bit(M.matchBit[prLen < 8 ? (uint32_t)prLen : 7], 0);
				for (size_t m = i; m < j; ++m) {
					const uint32_t dd = noteDur(notes[m]);
					rowKinds.push_back(ids[m]);
					rowDurs.push_back(dd == 0 ? 0u : (durUnit > 1 ? dd / durUnit : dd));
				}
				rowGap.push_back(gap); rowCnt.push_back((uint64_t)(j - i));
				rowOff.push_back(rowKinds.size());
				matchTable[h] = (int32_t)rowGap.size() - 1;
				prevGap = gap; prevCount = (uint64_t)(j - i); prevPos = gpos;
				for (size_t m = i; m < j; ++m) {
					if (M.kindCount > 1) { prevKind2 = prevKind; prevKind = ids[m]; }
					const uint32_t dd = noteDur(notes[m]);
					if (dd != 0) { sinceSustain = 0; prevDur = durUnit > 1 ? (int64_t)(dd / durUnit) : (int64_t)dd; }
					else ++sinceSustain;
				}
				prevSrc = predRow;
				prevWasHit = true;
				i = j;
				continue;
			}
			rc.bit(M.matchBit[prLen < 8 ? (uint32_t)prLen : 7], 1);
		}

		const uint32_t gctx = fvc3_ac_gapCtx(prevGap, prevWasHit);
		if (gap == prevGap) {
			rc.bit(M.gapSame[gctx], 0);
		}
		else {
			rc.bit(M.gapSame[gctx], 1);
			if (gap == 0) rc.bit(M.gapIs0[gctx], 0);
			else {
				rc.bit(M.gapIs0[gctx], 1);
				if (gap == 1) rc.bit(M.gapIs1[gctx], 0);
				else {
					rc.bit(M.gapIs1[gctx], 1);
					if (gap == 2) rc.bit(M.gapIs2[gctx], 0);
					else {
						rc.bit(M.gapIs2[gctx], 1);
						if (gap == 3) rc.bit(M.gapIs3[gctx], 0);
						else {
							rc.bit(M.gapIs3[gctx], 1);
							if (gap == 4) rc.bit(M.gapIs4[gctx], 0);
							else { rc.bit(M.gapIs4[gctx], 1); fvc3_ac_putU(rc, M.gapVar, gap); }
						}
					}
				}
			}
		}

		const uint64_t count = (uint64_t)(j - i);
		const uint32_t cctx = fvc3_ac_cntCtx(prevCount);
		if (count == prevCount) {
			rc.bit(M.cntSame[cctx], 0);
		}
		else {
			rc.bit(M.cntSame[cctx], 1);
			if (count == 1) rc.bit(M.cntIs1[cctx], 0);
			else {
				rc.bit(M.cntIs1[cctx], 1);
				if (count == 2) rc.bit(M.cntIs2[cctx], 0);
				else {
					rc.bit(M.cntIs2[cctx], 1);
					if (count == 3) rc.bit(M.cntIs3[cctx], 0);
					else { rc.bit(M.cntIs3[cctx], 1); fvc3_ac_putU(rc, M.cntVar, count - 1); }
				}
			}
		}

		for (size_t m = i; m < j; ++m) {
			if (M.kindCount > 1) {
				uint16_t* tree = M.kindCtx ? &M.kind[(size_t)prevKind << M.kindBits] : &M.kind[0];
				fvc3_ac_putTree(rc, tree, M.kindBits, ids[m]);
				prevKind2 = prevKind;
				prevKind = ids[m];
			}
			const uint32_t d = noteDur(notes[m]);
			if (d != 0) {
				rc.bit(M.flag[sinceSustain < 7 ? sinceSustain : 7], 1);
				sinceSustain = 0;
				const int64_t abs = durUnit > 1 ? (int64_t)(d / durUnit) : (int64_t)d;
				const int64_t dv = abs - prevDur;
				if (dv == 0) rc.bit(M.durZero, 0);
				else {
					rc.bit(M.durZero, 1);
					fvc3_ac_putU(rc, M.durVar, (uint64_t)((dv << 1) ^ (dv >> 63)));
				}
				prevDur = abs;
			}
			else {
				rc.bit(M.flag[sinceSustain < 7 ? sinceSustain : 7], 0);
				++sinceSustain;
			}
		}
		{
			for (size_t m = i; m < j; ++m) {
				const uint32_t d = noteDur(notes[m]);
				rowKinds.push_back(ids[m]);
				rowDurs.push_back(d == 0 ? 0u : (durUnit > 1 ? d / durUnit : d));
			}
			rowGap.push_back(gap); rowCnt.push_back(count);
			rowOff.push_back(rowKinds.size());
			matchTable[h] = (int32_t)rowGap.size() - 1;
		}
		prevSrc = (int32_t)rowGap.size() - 1;
		prevWasHit = false;
		prevGap = gap; prevCount = count; prevPos = gpos;
		i = j;
	}
	rc.flush();
}

static bool fvc3_ac_decode(const uint8_t* data, size_t size, uint32_t noteCount,
	std::vector<ChartNote>& out) {
	const uint8_t* p = data;
	const uint8_t* end = data + size;
	uint64_t grid = 0, kindCount = 0, durUnit = 1;
	p = blob_getu(p, end, grid);
	p = blob_getu(p, end, kindCount);
	if (!p || grid == 0 || kindCount == 0 || kindCount > FVC3_MAX_KINDS
		|| kindCount > noteCount) return false;
	p = blob_getu(p, end, durUnit);
	if (!p || durUnit == 0) return false;
	if (end - p < 8) return false;
	uint64_t wantHash = 0;
	for (int i = 0; i < 8; ++i) wantHash |= (uint64_t)(*p++) << (8 * i);

	Fvc3AcModels M;
	M.init(kindCount);
	Fvc3AcDec rc(p, end);
	std::vector<uint32_t> kinds((size_t)kindCount);
	{
		uint32_t prev = 0;
		for (uint64_t i = 0; i < kindCount; ++i) {
			const uint64_t d = fvc3_ac_getU(rc, M.tableVar);
			if (d > 0xFFFFFFu) return false;
			const uint64_t k = (uint64_t)prev + d;
			if (k > 0xFFFFFFu) return false;
			kinds[(size_t)i] = (uint32_t)k;
			prev = (uint32_t)k;
		}
	}

	static const size_t FVC3_AC_MATCH_ROWS_D = 4096;
	std::vector<uint64_t> rowGap, rowCnt, rowOff;
	std::vector<uint32_t> rowKinds, rowDurs;
	rowOff.push_back(0);
	rowGap.reserve((size_t)noteCount / 2 + 1);
	rowCnt.reserve((size_t)noteCount / 2 + 1);
	rowOff.reserve((size_t)noteCount / 2 + 2);
	rowKinds.reserve(noteCount);
	rowDurs.reserve(noteCount);
	std::vector<int32_t> matchTable(FVC3_AC_MATCH_ROWS_D, -1);

	out.clear();
	out.reserve(noteCount);
	uint64_t prevGap = 0, prevCount = 1, pos = 0;
	uint32_t prevKind = 0, prevKind2 = 0;
	int sinceSustain = 7;
	int64_t prevDur = 0;
	int32_t prevSrc = -1;
	bool prevWasHit = false;
	while (out.size() < noteCount) {
		const uint32_t h = (uint32_t)((prevGap * 0x9E3779B97F4A7C15ull
			+ prevCount * 0xC2B2AE3D27D4EB4Full
			+ (uint64_t)prevKind * 0x165667B19E3779F9ull
			+ (uint64_t)prevKind2 * 0x27D4EB2F165667C5ull
			+ (uint64_t)(sinceSustain < 7 ? sinceSustain : 7)) & (FVC3_AC_MATCH_ROWS_D - 1));
		int32_t predRow = -1;
		if (prevSrc >= 0 && prevSrc + 1 < (int32_t)rowGap.size())
			predRow = prevSrc + 1;
		if (predRow < 0) predRow = matchTable[h];
		if (predRow >= 0) {
			const uint64_t prCount = rowCnt[(size_t)predRow];
			const uint64_t prGap = rowGap[(size_t)predRow];
			if (!rc.bit(M.matchBit[prCount < 8 ? (uint32_t)prCount : 7])) {
				if (prCount < 1 || prCount > FVC3_ROWS_MAX_ROW) return false;
				if (out.size() + prCount > (uint64_t)noteCount) return false;
				if (pos > 0xFFFFFFFFFFFFULL - prGap) return false;
				pos += prGap;
				if (pos > 0xFFFFFFFFFFFFULL / grid) return false;
				const uint64_t absPos = pos * grid;
				const size_t prBeg = (size_t)rowOff[(size_t)predRow];
				for (size_t m = 0; m < prCount; ++m) {
					const uint32_t id = rowKinds[prBeg + m];
					const uint32_t du = rowDurs[prBeg + m];
					if (id >= kindCount) return false;
					const uint32_t k = kinds[id];
					uint32_t dur = 0;
					if (du != 0) {
						if (du > 0xFFFFFF) return false;
						if (durUnit > 1) {
							if (du > 0xFFFFFF / durUnit) return false;
							dur = du * (uint32_t)durUnit;
						}
						else {
							dur = du;
						}
					}
					out.push_back(packNote(absPos, dur, (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F));
					if (M.kindCount > 1) { prevKind2 = prevKind; prevKind = id; }
					if (du != 0) { sinceSustain = 0; prevDur = (int64_t)du; }
					else ++sinceSustain;
					rowKinds.push_back(id);
					rowDurs.push_back(du);
				}
				rowGap.push_back(prGap); rowCnt.push_back(prCount);
				rowOff.push_back(rowKinds.size());
				matchTable[h] = (int32_t)rowGap.size() - 1;
				prevGap = prGap; prevCount = prCount;
				prevSrc = predRow;
				prevWasHit = true;
				continue;
			}
		}

		uint64_t gap;
		if (!rc.bit(M.gapSame[fvc3_ac_gapCtx(prevGap, prevWasHit)])) gap = prevGap;
		else {
			const uint32_t gctx = fvc3_ac_gapCtx(prevGap, prevWasHit);
			if (!rc.bit(M.gapIs0[gctx])) gap = 0;
			else if (!rc.bit(M.gapIs1[gctx])) gap = 1;
			else if (!rc.bit(M.gapIs2[gctx])) gap = 2;
			else if (!rc.bit(M.gapIs3[gctx])) gap = 3;
			else if (!rc.bit(M.gapIs4[gctx])) gap = 4;
			else {
				gap = fvc3_ac_getU(rc, M.gapVar);
				if (gap < 5) return false;
			}
		}
		if (pos > 0xFFFFFFFFFFFFULL - gap) return false;
		pos += gap;

		uint64_t count;
		if (!rc.bit(M.cntSame[fvc3_ac_cntCtx(prevCount)])) count = prevCount;
		else {
			const uint32_t cctx = fvc3_ac_cntCtx(prevCount);
			if (!rc.bit(M.cntIs1[cctx])) count = 1;
			else if (!rc.bit(M.cntIs2[cctx])) count = 2;
			else if (!rc.bit(M.cntIs3[cctx])) count = 3;
			else {
				count = fvc3_ac_getU(rc, M.cntVar) + 1;
				if (count < 4) return false;
			}
		}
		if (count < 1 || count > FVC3_ROWS_MAX_ROW) return false;
		if (out.size() + count > (uint64_t)noteCount) return false;
		if (pos > 0xFFFFFFFFFFFFULL / grid) return false;
		const uint64_t absPos = pos * grid;

		uint32_t decIds[256];
		uint32_t decDurs[256];
		uint32_t decDurFin[256];
		for (uint64_t m = 0; m < count; ++m) {
			uint32_t id = 0;
			if (M.kindCount > 1) {
				uint16_t* tree = M.kindCtx ? &M.kind[(size_t)prevKind << M.kindBits] : &M.kind[0];
				id = fvc3_ac_getTree(rc, tree, M.kindBits);
				if (id >= kindCount) return false;
				prevKind2 = prevKind;
				prevKind = id;
			}
			decIds[m] = id;
			uint32_t dur = 0;
			if (rc.bit(M.flag[sinceSustain < 7 ? sinceSustain : 7])) {
				sinceSustain = 0;
				int64_t raw;
				if (!rc.bit(M.durZero)) raw = prevDur;
				else {
					const uint64_t zz = fvc3_ac_getU(rc, M.durVar);
					const int64_t dv = (int64_t)((zz >> 1) ^ -(int64_t)(zz & 1));
					if (dv > (int64_t)0x7FFFFFFFFFFLL || dv < -(int64_t)0x7FFFFFFFFFFLL) return false;
					raw = prevDur + dv;
				}
				if (raw < 0 || raw > 0xFFFFFF) return false;
				if (durUnit > 1) {
					if (raw > 0xFFFFFF / (int64_t)durUnit) return false;
					dur = (uint32_t)(raw * (int64_t)durUnit);
				}
				else {
					dur = (uint32_t)raw;
				}
				prevDur = raw;
				decDurs[m] = raw > 0 ? (uint32_t)raw : 0;
				decDurFin[m] = dur;
			}
			else {
				++sinceSustain;
				decDurs[m] = 0;
				decDurFin[m] = 0;
			}
		}
		for (uint64_t m = 0; m < count; ++m) {
			const uint32_t k = kinds[decIds[m]];
			out.push_back(packNote(absPos, decDurFin[m], (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F));
		}
		{
			for (uint64_t m = 0; m < count; ++m) {
				rowKinds.push_back(decIds[m]);
				rowDurs.push_back(decDurs[m]);
			}
			rowGap.push_back(gap); rowCnt.push_back(count);
			rowOff.push_back(rowKinds.size());
			matchTable[h] = (int32_t)rowGap.size() - 1;
		}
		prevSrc = (int32_t)rowGap.size() - 1;
		prevWasHit = false;
		prevGap = gap; prevCount = count;
	}
	return fvc3_ac_notesHash(out.data(), out.size()) == wantHash;
}

static std::vector<uint8_t> fvc3_encode(const ChartNote* notes, size_t n, bool twoThread) {
	const size_t rawSize = n * sizeof(ChartNote);
	uint64_t grid = 0;
	for (size_t i = 0; i < n; ++i) {
		const uint64_t p = notePos(notes[i]);
		grid = grid ? fvc3_gcd(grid, p) : p;
		if (grid == 1) break;
	}
	if (grid == 0) grid = 1;

	std::vector<uint32_t> kinds;
	std::unordered_map<uint32_t, uint32_t> kindId;
	std::vector<uint32_t> ids(n);
	for (size_t i = 0; i < n; ++i) {
		const uint32_t k = (noteIdx(notes[i]) << 16) | (noteType(notes[i]) << 8) | noteLane(notes[i]);
		auto it = kindId.find(k);
		uint32_t id;
		if (it == kindId.end()) {
			kinds.push_back(k);
			id = (uint32_t)(kinds.size() - 1);
			kindId.emplace(k, id);
		}
		else {
			id = it->second;
		}
		ids[i] = id;
	}

	const bool gkOk = kinds.size() <= FVC3_MAX_KINDS;
	std::vector<uint8_t> gk, rows, ac;
	bool gkTooBig = false;
	auto buildCheap = [&]() {
		if (!gkOk) return;
		gk.reserve(n * 3 + 32);
		blob_putu(gk, grid);
		blob_putu(gk, (uint64_t)kinds.size());
		for (uint32_t k : kinds) blob_putu(gk, k);
		uint64_t prevP = 0; int64_t prevD = 0;
		for (size_t i = 0; i < n; ++i) {
			const uint64_t p = notePos(notes[i]) / grid;
			blob_putu(gk, p - prevP); prevP = p;
			blob_puti(gk, (int64_t)noteDur(notes[i]) - prevD); prevD = (int64_t)noteDur(notes[i]);
			blob_putu(gk, ids[i]);
			if (gk.size() >= rawSize) { gkTooBig = true; break; }
		}
		fvc3_rows_encode(notes, n, grid, rows, &kinds, &ids);
		};
	auto buildAc = [&]() { if (gkOk) fvc3_ac_encode(notes, n, grid, ac); };
	if (twoThread && gkOk && n >= 2048) chart_dual_run(buildCheap, buildAc);
	else { buildCheap(); buildAc(); }

	const size_t gkCost = gkTooBig ? SIZE_MAX : gk.size();
	std::vector<uint8_t> payload;
	uint8_t codec;
	if (gkOk && !rows.empty() && rows.size() <= gkCost && rows.size() <= rawSize
		&& rows.size() <= ac.size()) {
		codec = FVC3_CODEC_ROWS; payload = std::move(rows);
	}
	else if (gkOk && !ac.empty() && ac.size() <= gkCost && ac.size() <= rawSize) {
		codec = FVC3_CODEC_AC; payload = std::move(ac);
	}
	else if (gkOk && !gkTooBig && gk.size() < rawSize) {
		codec = FVC3_CODEC_GRID_KIND; payload = std::move(gk);
	}
	else {
		codec = FVC3_CODEC_RAW;
		payload.resize(rawSize);
		if (n) std::memcpy(payload.data(), notes, rawSize);
	}

	std::vector<uint8_t> out;
	out.reserve(16 + payload.size());
	Fvc3Header hdr{};
	std::memcpy(hdr.magic, "FVC3", 4);
	hdr.noteCount = (uint32_t)n;
	hdr.codec = codec;
	hdr.payloadBytes = (uint32_t)payload.size();
	out.insert(out.end(), reinterpret_cast<const uint8_t*>(&hdr),
		reinterpret_cast<const uint8_t*>(&hdr) + sizeof(hdr));
	out.insert(out.end(), payload.begin(), payload.end());
	return out;
}

static std::vector<uint8_t> fvc3_encode(const ChartNote* notes, size_t n) {
	return fvc3_encode(notes, n, false);
}

static bool fvc3_decode(const uint8_t* data, size_t size, std::vector<ChartNote>& out) {
	if (size < sizeof(Fvc3Header)) return false;
	Fvc3Header hdr;
	std::memcpy(&hdr, data, sizeof(hdr));
	if (std::memcmp(hdr.magic, "FVC3", 4) != 0) return false;
	const uint8_t* p = data + sizeof(Fvc3Header);
	const uint8_t* end = data + size;
	if ((size_t)(end - p) < hdr.payloadBytes) return false;
	end = p + hdr.payloadBytes;

	if (hdr.codec == FVC3_CODEC_RAW) {
		if (hdr.payloadBytes % sizeof(ChartNote) != 0) return false;
		const size_t n = hdr.payloadBytes / sizeof(ChartNote);
		if ((uint64_t)n != hdr.noteCount) return false;
		out.resize(n);
		if (n) std::memcpy(out.data(), p, hdr.payloadBytes);
		return true;
	}
	if (hdr.codec == FVC3_CODEC_ROWS)
		return fvc3_rows_decode(p, (size_t)(end - p), hdr.noteCount, out);
	if (hdr.codec == FVC3_CODEC_AC)
		return fvc3_ac_decode(p, (size_t)(end - p), hdr.noteCount, out);
	if (hdr.codec != FVC3_CODEC_GRID_KIND) return false;

	uint64_t grid = 0, kindCount = 0;
	p = blob_getu(p, end, grid);
	p = blob_getu(p, end, kindCount);
	if (!p || grid == 0 || kindCount == 0 || kindCount > FVC3_MAX_KINDS
		|| kindCount > hdr.noteCount) return false;
	std::vector<uint32_t> kinds((size_t)kindCount);
	for (uint64_t i = 0; i < kindCount; ++i) {
		uint64_t k = 0;
		p = blob_getu(p, end, k);
		if (!p || (k >> 24) != 0) return false;
		kinds[(size_t)i] = (uint32_t)k;
	}
	out.resize(hdr.noteCount);
	uint64_t prevP = 0; int64_t prevD = 0;
	for (uint32_t i = 0; i < hdr.noteCount; ++i) {
		uint64_t dP = 0, id = 0; int64_t dD = 0;
		p = blob_getu(p, end, dP);
		p = blob_geti(p, end, dD);
		p = blob_getu(p, end, id);
		if (!p || id >= kindCount) return false;
		if (dP > 0xFFFFFFFFFFFFULL) return false;
		prevP += dP;
		prevD += dD;
		if (prevP > 0xFFFFFFFFFFFFULL / (grid ? grid : 1) + 1) return false;
		const uint64_t pos = prevP * grid;
		if (pos > 0xFFFFFFFFFFFFULL) return false;
		if (prevD < 0 || prevD > 0xFFFFFF) return false;
		const uint32_t k = kinds[(size_t)id];
		out[i] = packNote(pos, (uint32_t)prevD, (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F);
	}
	return p == end;
}

static void radix_sort_notes_inplace(ChartNote* notes, size_t n) {
	if (n <= 1) return;
	uint64_t maxVal = 0, prev = 0;
	bool sorted = true;
	for (size_t i = 0; i < n; ++i) {
		const uint64_t pos = notePos(notes[i]);
		if (pos < prev) sorted = false;
		prev = pos;
		if (pos > maxVal) maxVal = pos;
	}
	if (sorted || maxVal == 0) return;
	std::vector<ChartNote> buffer(n);
	ChartNote* src = notes;
	ChartNote* dst = buffer.data();
	int passes = 0;
	while (maxVal > 0) { passes++; maxVal >>= 8; }
	if (passes > 6) passes = 6;

	for (int shift = 0; shift < passes * 8; shift += 8) {
		uint32_t counts[256] = { 0 };
		for (size_t i = 0; i < n; ++i) counts[(notePos(src[i]) >> shift) & 0xFF]++;
		for (int j = 1; j < 256; ++j) counts[j] += counts[j - 1];
		for (int64_t j = (int64_t)n - 1; j >= 0; --j) {
			const uint8_t idx = (uint8_t)((notePos(src[j]) >> shift) & 0xFF);
			dst[--counts[idx]] = src[j];
		}
		std::swap(src, dst);
	}
	if (src != notes) std::memcpy(notes, src, n * sizeof(ChartNote));
}

struct ChartSegShard { uint64_t startTick; uint32_t noteCount; bool modified; };
struct ChartSegRange {
	size_t firstShard = 0, lastShard = 0;
	uint64_t startTick = 0;
	uint32_t noteCount = 0;
	bool dirty = false;
};

static std::vector<ChartSegRange> chart_plan_segments(const std::vector<ChartSegShard>& sh,
	uint64_t shardTicks, size_t minShards, size_t maxShards, uint32_t noteBudget) {
	std::vector<ChartSegRange> plan;
	for (size_t si = 0; si < sh.size(); ++si) {
		bool startNew = plan.empty();
		if (!startNew) {
			const ChartSegRange& b = plan.back();
			const size_t cnt = b.lastShard - b.firstShard + 1;
			const uint64_t gapTicks = sh[si].startTick - sh[si - 1].startTick;
			const bool gapped = gapTicks > shardTicks * (uint64_t)maxShards;
			startNew = (cnt >= maxShards)
				|| (cnt >= minShards && b.noteCount >= noteBudget)
				|| gapped;
			if (startNew && !gapped && si + 1 == sh.size() && cnt < maxShards)
				startNew = false;
		}
		if (startNew) {
			ChartSegRange r;
			r.firstShard = si;
			r.lastShard = si;
			r.startTick = sh[si].startTick;
			plan.push_back(r);
		}
		else {
			plan.back().lastShard = si;
		}
		plan.back().noteCount += sh[si].noteCount;
		if (sh[si].modified) plan.back().dirty = true;
	}
	return plan;
}

static void chart_encode_segments_mt(std::vector<std::vector<ChartNote>>& flats,
	std::vector<std::vector<uint8_t>>& images) {
	images.clear();
	images.resize(flats.size());
	if (flats.empty()) return;
	auto encodeRange = [&](size_t beg, size_t end) {
		for (size_t k = beg; k < end; ++k) {
			images[k] = fvc3_encode(flats[k].data(), flats[k].size());
			std::vector<ChartNote>().swap(flats[k]);
		}
		};
	if (flats.size() >= 2) {
		uint64_t totalN = 0;
		for (const auto& f : flats) totalN += f.size();
		uint64_t acc = 0; size_t half = 0;
		while (half < flats.size() - 1 && acc < (totalN + 1) / 2) {
			acc += flats[half].size(); ++half;
		}
		if (half == 0) half = 1;
		chart_dual_run([&] { encodeRange(0, half); },
			[&] { encodeRange(half, flats.size()); });
	}
	else {
		images[0] = fvc3_encode(flats[0].data(), flats[0].size(), true);
		std::vector<ChartNote>().swap(flats[0]);
	}
}

class ShardedNoteStore {
public:
	static constexpr uint64_t POS_MASK = 0x0000FFFFFFFFFFFFULL;
	static constexpr uint64_t SHARD_TICKS = 25000000ULL;
	static constexpr size_t OPEN_SHARD_BUDGET = 256;
	static constexpr size_t   SEGMENT_MIN_SHARDS = 2;
	static constexpr size_t   SEGMENT_MAX_SHARDS = 32;
	static constexpr uint32_t SEGMENT_NOTE_BUDGET = 4096;

	struct Segment {
		uint64_t startTick = 0;
		uint32_t noteCount = 0;
		std::vector<uint8_t> image;
	};

private:
	struct Unit {
		uint64_t startTick = 0;
		int64_t  baseId = 0;
		uint32_t noteCount = 0;
		bool open = false;
		bool dirty = false;
		std::vector<uint8_t> image;
		std::vector<ChartNote> buf;
		size_t gapStart = 0;
		size_t gapLen = 0;
		BitArray judge;
		BitArray hit;
		size_t gapEnd() const { return gapStart + gapLen; }
		size_t live() const { return buf.size() - gapLen; }
		size_t size() const { return open ? live() : (size_t)noteCount; }
		size_t physOf(size_t i) const { return i < gapStart ? i : i + gapLen; }
		ChartNote& note(size_t i) { return buf[physOf(i)]; }
		const ChartNote& note(size_t i) const { return buf[physOf(i)]; }
		void moveGap(size_t k) {
			if (k == gapStart) return;
			if (k < gapStart) {
				const size_t cnt = gapStart - k;
				std::memmove(buf.data() + gapEnd() - cnt, buf.data() + k,
					cnt * sizeof(ChartNote));
			}
			else {
				const size_t cnt = k - gapStart;
				std::memmove(buf.data() + gapStart, buf.data() + gapEnd(),
					cnt * sizeof(ChartNote));
			}
			gapStart = k;
		}
		void growHole(size_t need) {
			const size_t n = live();
			const size_t hole = std::max(need, n / 4 + 64);
			const size_t oldSize = buf.size();
			const size_t suffix = oldSize - gapEnd();
			buf.resize(oldSize + hole);
			if (suffix)
				std::memmove(buf.data() + gapEnd() + hole, buf.data() + gapEnd(),
					suffix * sizeof(ChartNote));
			gapLen += hole;
		}
		void insertAt(size_t k, const ChartNote& cn) {
			if (gapLen == 0) growHole(1);
			moveGap(k);
			buf[gapStart] = cn;
			++gapStart;
			--gapLen;
		}
		void eraseAt(size_t k) {
			moveGap(k);
			++gapLen;
		}
		const ChartNote* contiguous() {
			moveGap(live());
			return buf.data();
		}
		void freeBlock() {
			std::vector<ChartNote>().swap(buf);
			gapStart = 0;
			gapLen = 0;
		}
	};

	std::vector<Unit> units;
	int64_t totalNotes = 0;
	mutable size_t lastUnit = 0;
	size_t openCount = 0;
	std::vector<size_t> lru;
	BitArray modifiedBits;

	void touch(size_t ui) {
		for (size_t k = 0; k < lru.size(); ++k) {
			if (lru[k] == ui) {
				if (k != 0)
					std::rotate(lru.begin(), lru.begin() + (long)k, lru.begin() + (long)k + 1);
				return;
			}
		}
		lru.insert(lru.begin(), ui);
		while (lru.size() > OPEN_SHARD_BUDGET) {
			closeUnit(units[lru.back()]);
			lru.pop_back();
		}
	}

	void ensureOpen(size_t ui) {
		Unit& u = units[ui];
		if (!u.open) {
			u.buf.clear();
			u.gapStart = 0;
			u.gapLen = 0;
			const bool ok = !u.image.empty()
				&& fvc3_decode(u.image.data(), u.image.size(), u.buf)
				&& u.buf.size() == (size_t)u.noteCount;
			if (!ok) {
				std::cerr << "  [ Chart File ] CORRUPT SEGMENT — refusing to decode" << std::endl;
				u.freeBlock();
				u.image.clear();
				u.noteCount = 0;
				u.open = true;
				u.dirty = false;
				u.judge.init(0);
				u.hit.init(0);
				++openCount;
				rebuildTotals();
				touch(ui);
				return;
			}
			u.gapStart = u.buf.size();
			u.gapLen = 0;
			u.open = true;
			u.dirty = false;
			u.judge.init(u.buf.size());
			u.hit.init(u.buf.size());
			++openCount;
		}
		touch(ui);
	}

	void closeUnit(Unit& u) {
		if (!u.open) return;
		if (u.dirty) {
			u.image = fvc3_encode(u.contiguous(), u.live());
			u.noteCount = (uint32_t)u.live();
		}
		u.freeBlock();
		u.judge = BitArray();
		u.hit = BitArray();
		u.open = false;
		u.dirty = false;
		--openCount;
	}

	void closeAll() {
		for (Unit& u : units) closeUnit(u);
		lru.clear();
	}

	void rebuildTotals() {
		int64_t base = 0;
		for (Unit& u : units) { u.baseId = base; base += (int64_t)u.size(); }
		totalNotes = base;
	}

	size_t findUnitByPos(uint64_t pos) const {
		size_t lo = 0, hi = units.size();
		while (lo < hi) {
			const size_t mid = lo + (hi - lo) / 2;
			if (units[mid].startTick <= pos) lo = mid + 1;
			else hi = mid;
		}
		return lo == 0 ? units.size() : lo - 1;
	}

	size_t unitById(int64_t id) const {
		if (lastUnit < units.size()) {
			const Unit& c = units[lastUnit];
			if (id >= c.baseId && id < c.baseId + (int64_t)c.size()) return lastUnit;
		}
		size_t lo = 0, hi = units.size();
		while (lo < hi) {
			const size_t mid = lo + (hi - lo) / 2;
			if (units[mid].baseId <= id) lo = mid + 1;
			else hi = mid;
		}
		lastUnit = lo - 1;
		return lastUnit;
	}

public:
	ShardedNoteStore() = default;
	~ShardedNoteStore() = default;
	ShardedNoteStore(const ShardedNoteStore&) = delete;
	ShardedNoteStore& operator=(const ShardedNoteStore&) = delete;

	int64_t size() const { return totalNotes; }
	bool empty() const { return totalNotes == 0; }
	size_t shardCount() const { return units.size(); }
	size_t openShardCount() const { return openCount; }

	void clear() {
		units.clear();
		units.shrink_to_fit();
		totalNotes = 0;
		lastUnit = 0;
		openCount = 0;
		lru.clear();
		modifiedBits = BitArray();
	}

	uint64_t getFirst8(int64_t id) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		return u.note((size_t)(id - u.baseId)).first8;
	}

	uint32_t getLast4(int64_t id) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		return u.note((size_t)(id - u.baseId)).last4;
	}

	bool getJudge(int64_t id) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		return u.judge.get((size_t)(id - u.baseId));
	}

	void setJudge(int64_t id, bool value) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		u.judge.set((size_t)(id - u.baseId), value);
	}

	void setHit(int64_t id, bool value) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		u.hit.set((size_t)(id - u.baseId), value);
	}

	bool getHit(int64_t id) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		return u.hit.get((size_t)(id - u.baseId));
	}

	int64_t add(const ChartNote& cn) {
		const uint64_t pos = notePos(cn);
		size_t ui = findUnitByPos(pos);
		if (ui == units.size()) {
			Unit u;
			u.startTick = pos - (pos % SHARD_TICKS);
			u.open = true;
			u.dirty = true;
			u.noteCount = 0;
			u.judge.init(0);
			u.hit.init(0);
			units.insert(units.begin(), std::move(u));
			for (size_t& idx : lru) ++idx;
			modifiedBits.insert(0, true);
			++openCount;
			rebuildTotals();
			lastUnit = 0;
			ui = 0;
			touch(0);
		}
		else {
			ensureOpen(ui);
			if (ui + 1 == units.size() && units[ui].live() != 0) {
				const uint64_t maxPos = notePos(units[ui].note(units[ui].live() - 1));
				if (pos > maxPos && pos - units[ui].startTick >= SHARD_TICKS * SEGMENT_MAX_SHARDS) {
					Unit nu;
					nu.startTick = pos - (pos % SHARD_TICKS);
					nu.baseId = units[ui].baseId + (int64_t)units[ui].size();
					nu.open = true;
					nu.dirty = true;
					nu.noteCount = 0;
					nu.judge.init(0);
					nu.hit.init(0);
					units.push_back(std::move(nu));
					modifiedBits.insert(units.size() - 1, true);
					++openCount;
					ui = units.size() - 1;
					lastUnit = ui;
					touch(ui);
				}
			}
		}
		Unit& u = units[ui];
		const size_t n = u.live();
		size_t slot;
		if (n == 0) {
			slot = 0;
		}
		else if (pos > notePos(u.note(n - 1))) {
			slot = n;
		}
		else if (pos < notePos(u.note(0))) {
			slot = 0;
		}
		else {
			const size_t g = u.gapStart;
			if (g < n && pos <= notePos(u.note(g))
				&& (g == 0 || pos > notePos(u.note(g - 1)))) {
				slot = g;
			}
			else {
				size_t lo = 0, hi = n;
				while (lo < hi) {
					const size_t mid = lo + (hi - lo) / 2;
					if (notePos(u.note(mid)) < pos) lo = mid + 1;
					else hi = mid;
				}
				slot = lo;
			}
		}
		u.insertAt(slot, cn);
		u.judge.insert(slot, false);
		u.hit.insert(slot, false);
		u.dirty = true;
		modifiedBits.set(ui, true);
		++totalNotes;
		for (size_t k = ui + 1; k < units.size(); ++k) ++units[k].baseId;
		lastUnit = ui;
		return u.baseId + (int64_t)slot;
	}

	void remove(int64_t id) {
		const size_t ui = unitById(id);
		ensureOpen(ui);
		Unit& u = units[ui];
		const size_t slot = (size_t)(id - u.baseId);
		u.eraseAt(slot);
		u.judge.erase(slot);
		u.hit.erase(slot);
		u.dirty = true;
		modifiedBits.set(ui, true);
		--totalNotes;
		const bool gone = (u.live() == 0);
		if (gone) {
			for (size_t k = 0; k < lru.size(); ) {
				if (lru[k] == ui) { lru.erase(lru.begin() + (long)k); continue; }
				if (lru[k] > ui) --lru[k];
				++k;
			}
			u.freeBlock();
			u.judge = BitArray();
			u.hit = BitArray();
			if (u.open) { u.open = false; --openCount; }
			u.dirty = false;
			units.erase(units.begin() + ui);
			modifiedBits.erase(ui);
		}
		for (size_t k = (gone ? ui : ui + 1); k < units.size(); ++k) --units[k].baseId;
		lastUnit = 0;
	}

	void adoptSegments(std::vector<Segment>&& segs) {
		clear();
		units.reserve(segs.size());
		int64_t base = 0;
		for (Segment& s : segs) {
			Unit u;
			u.startTick = s.startTick;
			u.noteCount = s.noteCount;
			u.baseId = base;
			base += (int64_t)s.noteCount;
			u.image = std::move(s.image);
			units.push_back(std::move(u));
		}
		totalNotes = base;
		modifiedBits.init(units.size());
	}

	bool writeTo(const char* path) {
		struct Piece {
			uint64_t startTick = 0;
			uint32_t noteCount = 0;
			const std::vector<uint8_t>* cached = nullptr;
			std::vector<uint8_t> image;
			size_t srcUnit = 0;
		};
		std::vector<Piece> pieces;
		std::vector<std::vector<ChartNote>> flats;
		for (size_t ui = 0; ui < units.size(); ++ui) {
			Unit& u = units[ui];
			if (!u.dirty && !u.image.empty()) {
				Piece p;
				p.startTick = u.startTick;
				p.noteCount = u.noteCount;
				p.cached = &u.image;
				p.srcUnit = ui;
				pieces.push_back(std::move(p));
				continue;
			}
			if (u.live() == 0) continue;
			const ChartNote* data = u.contiguous();
			const size_t n = u.live();
			std::vector<ChartSegShard> infos;
			std::vector<size_t> offs;
			size_t i = 0;
			while (i < n) {
				const uint64_t st = notePos(data[i]) - (notePos(data[i]) % SHARD_TICKS);
				size_t j = i;
				while (j < n && notePos(data[j]) - st < SHARD_TICKS) ++j;
				offs.push_back(i);
				ChartSegShard inf; inf.startTick = st; inf.noteCount = (uint32_t)(j - i); inf.modified = false;
				infos.push_back(inf);
				i = j;
			}
			const std::vector<ChartSegRange> ranges = chart_plan_segments(infos,
				SHARD_TICKS, SEGMENT_MIN_SHARDS, SEGMENT_MAX_SHARDS, SEGMENT_NOTE_BUDGET);
			for (const ChartSegRange& r : ranges) {
				const size_t beg = offs[r.firstShard];
				const size_t end = offs[r.lastShard] + infos[r.lastShard].noteCount;
				Piece p;
				p.startTick = r.startTick;
				p.noteCount = r.noteCount;
				p.srcUnit = ui;
				pieces.push_back(std::move(p));
				flats.emplace_back(data + beg, data + end);
			}
		}
		std::vector<std::vector<uint8_t>> images;
		chart_encode_segments_mt(flats, images);
		{
			size_t k = 0;
			for (Piece& p : pieces)
				if (!p.cached) p.image = std::move(images[k++]);
		}
		std::vector<uint8_t> out;
		size_t totalOut = sizeof(Fvc4Header) + pieces.size() * sizeof(Fvc4SegEntry);
		for (const Piece& p : pieces) totalOut += p.cached ? p.cached->size() : p.image.size();
		out.reserve(totalOut);
		Fvc4Header hdr{};
		std::memcpy(hdr.magic, "FVC4", 4);
		hdr.noteCount = (uint32_t)totalNotes;
		hdr.segCount = (uint32_t)pieces.size();
		out.insert(out.end(), reinterpret_cast<const uint8_t*>(&hdr),
			reinterpret_cast<const uint8_t*>(&hdr) + sizeof(hdr));
		for (const Piece& p : pieces) {
			Fvc4SegEntry se{};
			se.startTick = p.startTick;
			se.noteCount = p.noteCount;
			se.imageBytes = (uint32_t)(p.cached ? p.cached->size() : p.image.size());
			out.insert(out.end(), reinterpret_cast<const uint8_t*>(&se),
				reinterpret_cast<const uint8_t*>(&se) + sizeof(se));
		}
		for (const Piece& p : pieces) {
			const std::vector<uint8_t>& img = p.cached ? *p.cached : p.image;
			out.insert(out.end(), img.begin(), img.end());
		}
		std::ofstream fout(path, std::ios::binary | std::ios::trunc);
		if (!fout) return false;
		fout.write(reinterpret_cast<const char*>(out.data()), (std::streamsize)out.size());
		if (!fout.good()) return false;

		std::vector<Unit> next;
		next.reserve(pieces.size());
		std::vector<size_t> newLru;
		size_t newOpen = 0;
		int64_t base = 0;
		size_t pi = 0;
		for (size_t ui = 0; ui < units.size(); ++ui) {
			Unit& u = units[ui];
			if (!u.dirty && !u.image.empty()) {
				Unit nu = std::move(u);
				nu.baseId = base;
				base += (int64_t)nu.size();
				if (nu.open) { newLru.push_back(next.size()); ++newOpen; }
				next.push_back(std::move(nu));
				++pi;
			}
			else {
				while (pi < pieces.size() && pieces[pi].srcUnit == ui) {
					Unit nu;
					nu.startTick = pieces[pi].startTick;
					nu.noteCount = pieces[pi].noteCount;
					nu.baseId = base;
					base += (int64_t)nu.noteCount;
					nu.image = std::move(pieces[pi].image);
					next.push_back(std::move(nu));
					++pi;
				}
				u.freeBlock();
				u.judge = BitArray();
				u.hit = BitArray();
				u.open = false;
				u.dirty = false;
			}
		}
		units.swap(next);
		lru.swap(newLru);
		openCount = newOpen;
		lastUnit = 0;
		modifiedBits.init(units.size());
		return true;
	}

	bool isSorted() const {
		uint64_t prev = 0;
		for (const Unit& u : units) {
			if (!u.open) continue;
			const size_t n = u.live();
			for (size_t i = 0; i < n; ++i) {
				const uint64_t p = notePos(u.note(i));
				if (p < prev) return false;
				prev = p;
			}
		}
		return true;
	}

	bool shardIsOpen(size_t si) const { return units.at(si).open; }
	size_t blobBytes(size_t si) const {
		const Unit& u = units.at(si);
		return u.dirty ? 0 : u.image.size();
	}
	uint32_t blobNoteCount(size_t si) const {
		const Unit& u = units.at(si);
		return (u.dirty || u.image.empty()) ? 0 : u.noteCount;
	}
	void forceCloseShard(size_t si) { closeUnit(units.at(si)); }
	void forceCloseAll() { closeAll(); }
	size_t openShardCountPublic() const { return openCount; }
	bool modifiedBit(size_t si) const { return modifiedBits.get(si); }
	size_t segmentCount() const { return units.size(); }
	void testMarkModified(size_t si) {
		ensureOpen(si);
		units[si].dirty = true;
		modifiedBits.set(si, true);
	}
};

static bool ends_with_fvc(const std::string& str) {
	static const std::string suffix = ".fvc";
	if (suffix.size() > str.size()) return false;
	return str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
}

class ChartFileReader {
private:
	std::string filename;
	ShardedNoteStore store;
	bool loadedFromDisk = false;
	bool dirty = false;
	bool editorMode = false;
	bool applyingNotes = false;
	mutable std::mutex dataMutex;

	bool loadFromFvc(const char* path) {
		std::ifstream in(path, std::ios::binary | std::ios::ate);
		if (!in) {
			std::cerr << "  [ Chart File ] Failed to open " << path << std::endl;
			return false;
		}
		const std::streamsize fileSize = in.tellg();
		if (fileSize < 0) return false;
		in.seekg(0, std::ios::beg);

		if (fileSize < (std::streamsize)sizeof(Fvc4Header)) {
			std::cerr << "  [ Chart File ] File too small for FVC4 " << path << std::endl;
			return false;
		}

		Fvc4Header h4;
		in.read(reinterpret_cast<char*>(&h4), sizeof(h4));
		if (in.gcount() != (std::streamsize)sizeof(h4)
			|| std::memcmp(h4.magic, "FVC4", 4) != 0) {
			std::cerr << "  [ Chart File ] Not an FVC4 file " << path << std::endl;
			return false;
		}

		if (h4.segCount > (uint32_t)((fileSize - (std::streamsize)sizeof(Fvc4Header))
			/ (std::streamsize)sizeof(Fvc4SegEntry))) {
			std::cerr << "  [ Chart File ] FVC4 directory overruns file " << path << std::endl;
			return false;
		}

		std::vector<Fvc4SegEntry> dir(h4.segCount);
		if (h4.segCount) {
			in.read(reinterpret_cast<char*>(dir.data()),
				(std::streamsize)h4.segCount * (std::streamsize)sizeof(Fvc4SegEntry));
			if (in.gcount() != (std::streamsize)h4.segCount * (std::streamsize)sizeof(Fvc4SegEntry)) {
				std::cerr << "  [ Chart File ] Truncated FVC4 directory in " << path << std::endl;
				return false;
			}
		}

		const std::streamsize payload =
			fileSize - (std::streamsize)sizeof(Fvc4Header)
			- (std::streamsize)h4.segCount * (std::streamsize)sizeof(Fvc4SegEntry);
		std::vector<uint8_t> images((size_t)payload);
		if (payload > 0) {
			in.read(reinterpret_cast<char*>(images.data()), payload);
			if (in.gcount() != payload) {
				std::cerr << "  [ Chart File ] Truncated FVC4 payload in " << path << std::endl;
				return false;
			}
		}

		const uint8_t* ip = images.data();
		const uint8_t* const iend = images.data() + images.size();
		uint64_t sumNotes = 0;
		std::vector<ShardedNoteStore::Segment> loadedSegments;
		for (uint32_t s = 0; s < h4.segCount; ++s) {
			const Fvc4SegEntry& se = dir[s];
			if (se.startTick % ShardedNoteStore::SHARD_TICKS != 0
				|| (s > 0 && se.startTick <= dir[s - 1].startTick)) {
				std::cerr << "  [ Chart File ] Bad FVC4 directory order in " << path << std::endl;
				return false;
			}
			if (se.imageBytes == 0 || (size_t)(iend - ip) < (size_t)se.imageBytes) {
				std::cerr << "  [ Chart File ] FVC4 segment " << s << " overruns payload in " << path << std::endl;
				return false;
			}
			ShardedNoteStore::Segment seg;
			seg.startTick = se.startTick;
			seg.noteCount = se.noteCount;
			seg.image.assign(ip, ip + se.imageBytes);
			loadedSegments.push_back(std::move(seg));
			ip += se.imageBytes;
			sumNotes += se.noteCount;
		}
		if (ip != iend || sumNotes != h4.noteCount) {
			std::cerr << "  [ Chart File ] FVC4 totals mismatch in " << path << std::endl;
			return false;
		}

		std::cout << "  [ Chart File ] FVC4 lazy snapshot (" << h4.noteCount
			<< " notes, " << h4.segCount << " segments, " << fileSize
			<< " bytes on disk)" << std::endl;

		in.close();
		std::lock_guard<std::mutex> lk(dataMutex);
		store.adoptSegments(std::move(loadedSegments));
		return true;
	}

#ifndef CHART_FILE_NO_TRANSPILER
	void writeHeaderFile(const std::string& songDir, const rapidjson::Document& doc, int totalColumns) {
		std::string headerPath = songDir + "/header.txt";
		std::ifstream test(headerPath);
		if (test.good()) {
			test.close();
			return;
		}
		test.close();

		std::string title = "N/A";
		std::string artist = "N/A";
		std::string genre = "N/A";
		double speed = 1.0;
		double bpm = 100.0;
		std::string stage = "stage";
		std::string player1 = "dad";
		std::string player2 = "bf";
		std::string gf = "gf";

		if (doc.HasMember("song") && doc["song"].IsObject()) {
			const auto& song = doc["song"];
			if (song.HasMember("song") && song["song"].IsString()) title = song["song"].GetString();
			if (song.HasMember("bpm") && song["bpm"].IsNumber()) bpm = song["bpm"].GetDouble();
			if (song.HasMember("speed") && song["speed"].IsNumber()) speed = song["speed"].GetDouble();
			if (song.HasMember("player1") && song["player1"].IsString()) player1 = song["player1"].GetString();
			if (song.HasMember("player2") && song["player2"].IsString()) player2 = song["player2"].GetString();
			if (song.HasMember("gfVersion") && song["gfVersion"].IsString()) gf = song["gfVersion"].GetString();
			if (song.HasMember("stage") && song["stage"].IsString()) stage = song["stage"].GetString();
		}

		speed *= 0.45;

		std::ofstream out(headerPath);
		if (!out) return;
		out << "Title: " << title << "\n";
		out << "Artist: " << artist << "\n";
		out << "Genre: " << genre << "\n";
		out << "Speed: " << speed << "\n";
		out << "BPM: " << bpm << "\n";
		out << "Time Signature: 4/4\n";
		out << "Stage: " << stage << "\n";
		out << "Instrumental: " << songDir << "/Inst.ogg\n";
		std::ifstream voicesPlayer(songDir + "/Voices-Player.ogg");
		std::ifstream voicesOpponent(songDir + "/Voices-Opponent.ogg");
		bool useTwoVoiceFiles = false;
		if (voicesPlayer.good()) { voicesPlayer.close(); useTwoVoiceFiles = true; }
		if (voicesOpponent.good()) { voicesOpponent.close(); useTwoVoiceFiles = true; }
		if (useTwoVoiceFiles) {
			std::cout << "  [ Transpiler ] Detected Voices-Player.ogg/Voices-Opponent.ogg for " << title << std::endl;
			out << "Voices: " << songDir << "/Voices-Player.ogg, " << songDir << "/Voices-Opponent.ogg\n";
		}
		else {
			std::cout << "  [ Transpiler ] Detected Voices.ogg for " << title << std::endl;
			out << "Voices: " << songDir << "/Voices.ogg\n";
		}
		out << "Mania: " << totalColumns << "\n";
		out << "Difficulty: #8\n";
		out << "Game Over:\n";
		out << "Theme: vanilla\n";
		out << "BPM: " << bpm << "\n";
		out << "Characters:\n";
		out << player1 << ", enemy\n";
		out << "pos -700 300\n";
		out << "cam 0 45\n";
		out << gf << ", other\n";
		out << "pos -100 300\n";
		out << "cam 0 45\n";
		out << player2 << ", player\n";
		out << "pos 200 300\n";
		out << "cam 0 45";
		out.close();
		std::cout << "  [ Transpiler ] Generated header.txt for " << title << std::endl;
	}

	void generateEventJson(const std::string& songDir, const rapidjson::Document& doc) {
		std::string eventsPath = songDir + "/eventList.json";
		std::ifstream test(eventsPath);
		if (test.good()) {
			test.close();
			return;
		}
		test.close();

		rapidjson::Document outDoc;
		outDoc.SetObject();
		rapidjson::Document::AllocatorType& allocator = outDoc.GetAllocator();
		rapidjson::Value eventsArray(rapidjson::kArrayType);

		if (doc.IsObject() && doc.HasMember("song") && doc["song"].IsObject()) {
			const auto& song = doc["song"];
			if (song.HasMember("events") && song["events"].IsArray()) {
				const auto& psychEvents = song["events"];
				for (auto& eventGroup : psychEvents.GetArray()) {
					if (!eventGroup.IsArray() || eventGroup.Size() < 2) continue;
					double time_ms = 0.0;
					if (eventGroup[0].IsNumber()) time_ms = eventGroup[0].GetDouble();
					if (!eventGroup[1].IsArray()) continue;
					for (auto& subEvent : eventGroup[1].GetArray()) {
						if (!subEvent.IsArray() || subEvent.Size() < 1) continue;
						std::string evName = subEvent[0].IsString() ? subEvent[0].GetString() : "";
						std::string val1 = "";
						std::string val2 = "";
						if (subEvent.Size() > 1 && subEvent[1].IsString()) val1 = subEvent[1].GetString();
						else if (subEvent.Size() > 1 && subEvent[1].IsNumber()) {
							val1 = subEvent[1].IsInt() ? std::to_string(subEvent[1].GetInt()) : std::to_string(subEvent[1].GetDouble());
						}
						if (subEvent.Size() > 2 && subEvent[2].IsString()) val2 = subEvent[2].GetString();
						else if (subEvent.Size() > 2 && subEvent[2].IsNumber()) {
							val2 = subEvent[2].IsInt() ? std::to_string(subEvent[2].GetInt()) : std::to_string(subEvent[2].GetDouble());
						}
						rapidjson::Value newEventObj(rapidjson::kObjectType);
						newEventObj.AddMember("evName", rapidjson::Value(evName.c_str(), allocator).Move(), allocator);
						newEventObj.AddMember("value1", rapidjson::Value(val1.c_str(), allocator).Move(), allocator);
						newEventObj.AddMember("value2", rapidjson::Value(val2.c_str(), allocator).Move(), allocator);
						newEventObj.AddMember("evTime", time_ms, allocator);
						eventsArray.PushBack(newEventObj, allocator);
					}
				}
			}

			if (song.HasMember("notes") && song["notes"].IsArray()) {
				for (auto& section : song["notes"].GetArray()) {
					if (!section.IsObject() || !section.HasMember("sectionNotes") || !section["sectionNotes"].IsArray()) continue;
					for (auto& note : section["sectionNotes"].GetArray()) {
						if (!note.IsArray() || note.Size() < 3) continue;
						if (note[1].IsNumber() && note[1].GetDouble() == -1.0) {
							double time_ms = note[0].IsNumber() ? note[0].GetDouble() : 0.0;
							std::string evName = note[2].IsString() ? note[2].GetString() : "";
							std::string val1 = (note.Size() > 3 && note[3].IsString()) ? note[3].GetString() : "";
							std::string val2 = (note.Size() > 4 && note[4].IsString()) ? note[4].GetString() : "";
							rapidjson::Value newEventObj(rapidjson::kObjectType);
							newEventObj.AddMember("evName", rapidjson::Value(evName.c_str(), allocator).Move(), allocator);
							newEventObj.AddMember("value1", rapidjson::Value(val1.c_str(), allocator).Move(), allocator);
							newEventObj.AddMember("value2", rapidjson::Value(val2.c_str(), allocator).Move(), allocator);
							newEventObj.AddMember("evTime", time_ms, allocator);
							eventsArray.PushBack(newEventObj, allocator);
						}
					}
				}
			}
		}

		size_t eventCount = eventsArray.Size();
		outDoc.AddMember("events", eventsArray, allocator);
		std::ofstream ofs(eventsPath);
		if (!ofs) return;
		rapidjson::OStreamWrapper osw(ofs);
		rapidjson::PrettyWriter<rapidjson::OStreamWrapper> writer(osw);
		outDoc.Accept(writer);
		ofs.close();
		std::cout << "  [ Transpiler ] Generated eventList.json with " << eventCount << " events." << std::endl;
	}

	inline bool writeNote(ChartNote& outNote, double time_ms, int lane, double sustain_ms, bool mustHitSection, bool isPsychV1, bool isVSlice, int totalColumns) {
		if (lane < 0) return false;
		int strumline;
		if (isVSlice) {
			strumline = (lane >= totalColumns) ? 1 : 0;
		}
		else if (isPsychV1) {
			strumline = (lane < totalColumns) ? 1 : 0;
		}
		else {
			bool gottaHitNote = (lane < totalColumns) ? mustHitSection : !mustHitSection;
			strumline = gottaHitNote ? 1 : 0;
		}
		const int index = lane % totalColumns;
		const int type = strumline;
		const uint64_t pos = (uint64_t)(time_ms * 100000.0);
		const uint32_t dur = (uint32_t)(sustain_ms);
		outNote = packNote(pos, dur, (uint32_t)index, (uint32_t)type, (uint32_t)strumline);
		return true;
	}

	void transpileJsonToFvc(const char* jsonPath) {
		std::ifstream ifs(jsonPath);
		if (!ifs) {
			std::cerr << "  [ Transpiler ] Failed to open JSON: " << jsonPath << std::endl;
			return;
		}
		rapidjson::IStreamWrapper isw(ifs);
		rapidjson::Document doc;
		doc.ParseStream(isw);
		ifs.close();
		if (doc.HasParseError()) {
			std::cerr << "  [ Transpiler ] JSON Parse Error at offset " << doc.GetErrorOffset() << std::endl;
			return;
		}

		std::string jsonStr(jsonPath);
		size_t lastSlash = jsonStr.find_last_of("/\\");
		std::string songDir = (lastSlash == std::string::npos) ? "." : jsonStr.substr(0, lastSlash);

		bool isVSlice = doc.HasMember("chart");
		bool isPsych = doc.HasMember("song");
		bool isPsychV1 = false;
		if (isPsych) {
			const auto& song = doc["song"];
			if (song.HasMember("format") && song["format"].IsString()) {
				std::string fmt = song["format"].GetString();
				if (fmt.find("psych_v1") != std::string::npos) isPsychV1 = true;
			}
		}

		int ammo[] = { 4, 6, 7, 9 };
		int totalColumns = 4;
		if (isPsych) {
			const auto& song = doc["song"];
			if (song.HasMember("mania") && song["mania"].IsInt()) totalColumns = song["mania"].GetInt();
		}
		else if (isVSlice) {
			if (doc.HasMember("mania") && doc["mania"].IsInt()) totalColumns = doc["mania"].GetInt();
		}
		if (totalColumns < 4) totalColumns = ammo[totalColumns];
		std::cout << "  [ Transpiler ] Detected Mania/Key Count: " << totalColumns << "K" << std::endl;

		std::string fvcPath = std::string(jsonPath);
		size_t dot = fvcPath.find_last_of('.');
		if (dot != std::string::npos) fvcPath = fvcPath.substr(0, dot);
		fvcPath += ".fvc";

		std::ofstream out(fvcPath, std::ios::binary | std::ios::trunc);
		if (!out) {
			std::cerr << "  [ Transpiler ] Failed to create .fvc file." << std::endl;
			return;
		}

		std::vector<ChartNote> collected;
		size_t writeIndex = 0;
		ChartNote currentNote;

		if (isVSlice) {
			const auto& chart = doc["chart"];
			if (chart.HasMember("notes") && chart["notes"].IsObject()) {
				for (auto& diff : chart["notes"].GetObject()) {
					if (diff.value.IsArray()) {
						for (const auto& note : diff.value.GetArray()) {
							if (note.IsObject() && note.HasMember("t") && note.HasMember("d")) {
								double t = note["t"].GetDouble();
								int d = note["d"].GetInt();
								double l = note.HasMember("l") && note["l"].IsNumber() ? note["l"].GetDouble() : 0;
								if (writeNote(currentNote, t, d, l, true, false, true, totalColumns))
									collected.push_back(currentNote);
							}
						}
					}
				}
			}
		}
		else if (isPsych) {
			const auto& song = doc["song"];
			if (song.HasMember("notes") && song["notes"].IsArray()) {
				for (const auto& section : song["notes"].GetArray()) {
					if (section.IsObject() && section.HasMember("sectionNotes") && section["sectionNotes"].IsArray()) {
						bool mustHit = true;
						if (section.HasMember("mustHitSection") && section["mustHitSection"].IsBool())
							mustHit = section["mustHitSection"].GetBool();
						for (const auto& note : section["sectionNotes"].GetArray()) {
							if (note.IsArray() && note.Size() >= 3) {
								if (note[1].IsNumber() && note[1].GetInt() == -1) continue;
								double t = note[0].IsNumber() ? note[0].GetDouble() : 0.0;
								int lane = note[1].IsNumber() ? note[1].GetInt() : 0;
								double sustain = note[2].IsNumber() ? note[2].GetDouble() : 0.0;
								if (writeNote(currentNote, t, lane, sustain, mustHit, isPsychV1, false, totalColumns))
									collected.push_back(currentNote);
							}
						}
					}
				}
			}
		}

		radix_sort_notes_inplace(collected.data(), collected.size());
		writeIndex = collected.size();
		if (writeIndex == 0) {
			out.close();
			std::cerr << "  [ Transpiler ] No valid notes found." << std::endl;
			std::remove(fvcPath.c_str());
			return;
		}

		std::vector<ChartSegShard> infos;
		std::vector<size_t> shardOff;
		{
			size_t i = 0;
			while (i < collected.size()) {
				const uint64_t st = notePos(collected[i])
					- (notePos(collected[i]) % ShardedNoteStore::SHARD_TICKS);
				size_t j = i;
				while (j < collected.size()
					&& notePos(collected[j]) - st < ShardedNoteStore::SHARD_TICKS) ++j;
				shardOff.push_back(i);
				ChartSegShard inf; inf.startTick = st; inf.noteCount = (uint32_t)(j - i); inf.modified = false;
				infos.push_back(inf);
				i = j;
			}
		}
		const std::vector<ChartSegRange> ranges = chart_plan_segments(infos,
			ShardedNoteStore::SHARD_TICKS, ShardedNoteStore::SEGMENT_MIN_SHARDS,
			ShardedNoteStore::SEGMENT_MAX_SHARDS, ShardedNoteStore::SEGMENT_NOTE_BUDGET);
		std::vector<std::vector<ChartNote>> flats(ranges.size());
		for (size_t r = 0; r < ranges.size(); ++r) {
			const size_t beg = shardOff[ranges[r].firstShard];
			const size_t end = shardOff[ranges[r].lastShard] + infos[ranges[r].lastShard].noteCount;
			flats[r].assign(collected.begin() + (long)beg, collected.begin() + (long)end);
		}
		std::vector<std::vector<uint8_t>> images;
		chart_encode_segments_mt(flats, images);

		std::vector<uint8_t> file;
		size_t totalOut = sizeof(Fvc4Header) + ranges.size() * sizeof(Fvc4SegEntry);
		for (const auto& img : images) totalOut += img.size();
		file.reserve(totalOut);
		Fvc4Header h4{};
		std::memcpy(h4.magic, "FVC4", 4);
		h4.noteCount = (uint32_t)writeIndex;
		h4.segCount = (uint32_t)ranges.size();
		file.insert(file.end(), reinterpret_cast<const uint8_t*>(&h4),
			reinterpret_cast<const uint8_t*>(&h4) + sizeof(h4));
		for (size_t r = 0; r < ranges.size(); ++r) {
			Fvc4SegEntry se{};
			se.startTick = ranges[r].startTick;
			se.noteCount = ranges[r].noteCount;
			se.imageBytes = (uint32_t)images[r].size();
			file.insert(file.end(), reinterpret_cast<const uint8_t*>(&se),
				reinterpret_cast<const uint8_t*>(&se) + sizeof(se));
		}
		for (const auto& img : images) file.insert(file.end(), img.begin(), img.end());
		out.write(reinterpret_cast<const char*>(file.data()), (std::streamsize)file.size());
		out.close();
		std::cout << "  [ Transpiler ] Wrote " << writeIndex << " notes through the FVC4 codec ("
			<< ranges.size() << " segments)." << std::endl;

		writeHeaderFile(songDir, doc, totalColumns);

		std::string evtPath = songDir + "/events.json";
		std::ifstream ifs_(evtPath);
		if (!ifs_) {
			generateEventJson(songDir, doc);
		}
		else {
			rapidjson::IStreamWrapper jsw(ifs_);
			rapidjson::Document evtDoc;
			evtDoc.ParseStream(jsw);
			ifs_.close();
			if (evtDoc.HasParseError()) {
				std::cerr << "  [ Transpiler ] JSON Parse Error in events.json at offset " << evtDoc.GetErrorOffset() << std::endl;
				return;
			}
			generateEventJson(songDir, evtDoc);
		}
		filename = fvcPath;
	}

	void generateHeaderOnly(const char* jsonPath, const std::string& songDir) {
		std::ifstream ifs(jsonPath);
		if (!ifs) {
			std::cerr << "  [ Transpiler ] Failed to open JSON for header generation: " << jsonPath << std::endl;
			return;
		}
		rapidjson::IStreamWrapper isw(ifs);
		rapidjson::Document doc;
		doc.ParseStream(isw);
		ifs.close();
		if (doc.HasParseError()) {
			std::cerr << "  [ Transpiler ] JSON Parse Error at offset " << doc.GetErrorOffset() << std::endl;
			return;
		}
		bool isPsych = doc.HasMember("song");
		bool isVSlice = doc.HasMember("chart");
		int ammo[] = { 4, 6, 7, 9 };
		int totalColumns = 4;
		if (isPsych) {
			const auto& song = doc["song"];
			if (song.HasMember("mania") && song["mania"].IsInt()) totalColumns = song["mania"].GetInt();
		}
		else if (isVSlice) {
			if (doc.HasMember("mania") && doc["mania"].IsInt()) totalColumns = doc["mania"].GetInt();
		}
		if (totalColumns < 4) totalColumns = ammo[0];
		writeHeaderFile(songDir, doc, totalColumns);
		generateEventJson(songDir, doc);
		std::cout << "  [ Transpiler ] Generated missing header.txt from " << jsonPath << std::endl;
	}

	bool ends_with(const std::string& str, const std::string& suffix) {
		if (suffix.size() > str.size()) return false;
		return str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
	}
#endif

public:
	bool open(const char* path) {
		std::string pathStr(path);
		size_t lastSlash = pathStr.find_last_of("/\\");
		std::string songDir = (lastSlash == std::string::npos) ? "." : pathStr.substr(0, lastSlash);

#ifdef CHART_FILE_NO_TRANSPILER
		if (!ends_with_fvc(pathStr)) {
			std::cerr << "  [ Chart File ] Non-.fvc input '" << pathStr
				<< "' needs the transpiler (built with CHART_FILE_NO_TRANSPILER)." << std::endl;
			return false;
		}
		filename = pathStr;
#else
		std::string headerPath = songDir + "/header.txt";
		std::ifstream headerTest(headerPath);
		bool headerExists = headerTest.good();
		headerTest.close();

		if (ends_with(pathStr, ".fvc")) {
			filename = pathStr;
			if (!headerExists) {
				std::string jsonPath = pathStr.substr(0, pathStr.length() - 4) + ".json";
				std::ifstream jsonTest(jsonPath);
				bool jsonExists = jsonTest.good();
				jsonTest.close();
				if (jsonExists) {
					generateHeaderOnly(jsonPath.c_str(), songDir);
				}
				else {
					std::cerr << "[Transpiler] Cannot generate header.txt: " << jsonPath << " not found." << std::endl;
				}
			}
		}
		else {
			std::string fvcPath = pathStr.substr(0, pathStr.length() - 5) + ".fvc";
			std::ifstream fvcTest(fvcPath);
			bool fvcExists = fvcTest.good();
			fvcTest.close();
			if (fvcExists) {
				bool fvcIsCurrent = false;
				{
					std::ifstream fvcHead(fvcPath, std::ios::binary);
					char magic[4] = { 0, 0, 0, 0 };
					if (fvcHead.read(magic, 4) && fvcHead.gcount() == 4)
						fvcIsCurrent = (std::memcmp(magic, "FVC4", 4) == 0);
					fvcHead.close();
				}
				if (fvcIsCurrent) {
					filename = fvcPath;
				}
				else {
					std::cout << "  [ Transpiler ] Existing .fvc is not FVC4 — re-transpiling "
						<< pathStr << std::endl;
					transpileJsonToFvc(pathStr.c_str());
				}
				if (!headerExists) generateHeaderOnly(pathStr.c_str(), songDir);
			}
			else {
				transpileJsonToFvc(pathStr.c_str());
			}
		}
#endif

		if (!loadFromFvc(filename.c_str())) return false;
		loadedFromDisk = true;
		std::cout << "  [ Chart File ] Loaded " << store.size() << " notes ("
			<< store.shardCount() << " segments) from " << filename << std::endl;
		return true;
	}

public:
	ChartFileReader() = default;
	~ChartFileReader() {
		if (dirty && loadedFromDisk && !filename.empty()) save();
	}

	void setEditorMode(bool enabled) { editorMode = enabled; }
	void setApplyingNotes(bool enabled) { applyingNotes = enabled; }

	ShardedNoteStore* testStore() { return &store; }

	int64_t getLength() const { return store.size(); }

	uint64_t getNote_first8(int64_t index) {
		if (index < 0 || index >= store.size()) return 0;
		std::lock_guard<std::mutex> lk(dataMutex);
		return store.getFirst8(index);
	}

	uint32_t getNote_last4(int64_t index) {
		if (index < 0 || index >= store.size()) return 0;
		std::lock_guard<std::mutex> lk(dataMutex);
		return store.getLast4(index);
	}

	int64_t addNote(uint64_t position, uint32_t duration, uint32_t index, uint32_t type, uint32_t lane) {
		const ChartNote cn = packNote(position, duration, index, type, lane);
		std::lock_guard<std::mutex> lk(dataMutex);
		const int64_t id = store.add(cn);
		dirty = true;
		return id;
	}

	void insertNote(uint64_t pos, uint16_t dur, uint8_t idx, uint8_t type) {
		addNote(pos, dur, idx, type, type == 0 ? 0 : 1);
	}

	void removeNote(int64_t id) {
		if (id < 0 || id >= store.size()) return;
		std::lock_guard<std::mutex> lk(dataMutex);
		store.remove(id);
		dirty = true;
	}

	bool getJudgement(int64_t index) {
		if (index < 0 || index >= store.size()) return false;
		std::lock_guard<std::mutex> lk(dataMutex);
		return store.getJudge(index);
	}

	void setJudgement(int64_t index, bool value) {
		if (index < 0 || index >= store.size()) return;
		std::lock_guard<std::mutex> lk(dataMutex);
		store.setJudge(index, value);
	}

	bool getHitFlag(int64_t index) {
		if (index < 0 || index >= store.size()) return false;
		std::lock_guard<std::mutex> lk(dataMutex);
		return store.getHit(index);
	}

	void setHitFlag(int64_t index, bool value) {
		if (index < 0 || index >= store.size()) return;
		std::lock_guard<std::mutex> lk(dataMutex);
		store.setHit(index, value);
	}

	bool save() {
		std::lock_guard<std::mutex> lk(dataMutex);
		if (filename.empty() || !store.writeTo(filename.c_str())) return false;
		dirty = false;
		return true;
	}

	bool saveAs(const char* path) {
		std::lock_guard<std::mutex> lk(dataMutex);
		if (!store.writeTo(path)) return false;
		filename = path;
		loadedFromDisk = true;
		dirty = false;
		return true;
	}

	void createNew(const char* path, int64_t initialCapacity = 4096) {
		(void)initialCapacity;
		std::lock_guard<std::mutex> lk(dataMutex);
		store.clear();
		filename = path;
		dirty = false;
		loadedFromDisk = true;
		std::ofstream file(path, std::ios::binary | std::ios::trunc);
		std::cout << "  [ Chart File ] Created new chart: " << path << std::endl;
	}
};

static ChartFileReader* gReader = nullptr;

void core_loadChart(const char* path) {
	if (gReader) { delete gReader; gReader = nullptr; }
	gReader = new ChartFileReader();
	gReader->open(path);
}

void core_createChart(const char* path) {
	if (gReader) { delete gReader; gReader = nullptr; }
	gReader = new ChartFileReader();
	gReader->createNew(path);
}

void core_destroyChart() {
	if (gReader) { delete gReader; gReader = nullptr; }
}

bool core_saveChart() { if (!gReader) return false; return gReader->save(); }
void core_setEditorMode(bool enabled) { if (gReader) gReader->setEditorMode(enabled); }
void core_setApplyingNotes(bool enabled) { if (gReader) gReader->setApplyingNotes(enabled); }
int64_t core_getNote_first8(int64_t index) { if (!gReader) return 0; return (int64_t)gReader->getNote_first8(index); }
int core_getNote_last4(int64_t index) { if (!gReader) return 0; return (int)gReader->getNote_last4(index); }

int64_t core_addNote(int64_t position, int duration, int index, int type, int lane) {
	if (!gReader) return -1;
	return gReader->addNote(static_cast<uint64_t>(position), static_cast<uint32_t>(duration),
		static_cast<uint32_t>(index), static_cast<uint32_t>(type),
		static_cast<uint32_t>(lane));
}

void core_insertNote(int64_t globalPosition, int duration, int index, int type) {
	if (!gReader) return;
	gReader->insertNote(static_cast<uint64_t>(globalPosition), static_cast<uint16_t>(duration),
		static_cast<uint8_t>(index), static_cast<uint8_t>(type));
}

void core_removeNote(int64_t globalIndex) { if (!gReader) return; gReader->removeNote(globalIndex); }
int64_t core_getLength() { if (!gReader) return 0; return gReader->getLength(); }

bool core_getJudgement(int64_t globalIndex) {
	if (!gReader) return false;
	return gReader->getJudgement(globalIndex);
}

void core_setJudgement(int64_t globalIndex, bool value) {
	if (!gReader) return;
	gReader->setJudgement(globalIndex, value);
}

bool core_getHitFlag(int64_t globalIndex) {
	if (!gReader) return false;
	return gReader->getHitFlag(globalIndex);
}

ShardedNoteStore* core_testStore() { return gReader ? gReader->testStore() : nullptr; }

void core_setHitFlag(int64_t globalIndex, bool value) {
	if (!gReader) return;
	gReader->setHitFlag(globalIndex, value);
}