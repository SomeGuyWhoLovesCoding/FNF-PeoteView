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
// RapidJSON — only needed for the .json -> .fvc transpiler. Builds that
// only ever consume .fvc snapshots (the gameplay runtime) can define
// CHART_FILE_NO_TRANSPILER to drop the dependency entirely.
#ifndef CHART_FILE_NO_TRANSPILER
#include "./include/rapidjson/document.h"
#include "./include/rapidjson/istreamwrapper.h"
#include "./include/rapidjson/ostreamwrapper.h"
#include "./include/rapidjson/prettywriter.h"
#include "./include/rapidjson/error/en.h"
#endif

// ---------------------------------------------------------------------------
// Two-thread execution helper: the CALLING thread runs mainFn while ONE
// worker runs workerFn; both join before return. In-flight threads never
// exceed 2 (the multi-segment paths pass twoThread=false into fvc3_encode,
// so candidate-level threading never nests inside segment-level threading).
// A worker exception is rethrown on the caller; if the OS refuses the
// thread, both halves run inline — same results, just serial.
// ---------------------------------------------------------------------------
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

// ============================================================================
// 1-Bit Dynamic Flag Array (Strictly 1 bit per element in RAM)
// ============================================================================
class BitArray {
    std::vector<uint8_t> data;
    size_t count = 0;
public:
    void init(size_t n) {
        count = n;
        data.assign((n + 7) / 8, 0);
    }
    bool get(size_t i) const {
        if (i >= count) return false;
        return (data[i >> 3] >> (i & 7)) & 1;
    }
    void set(size_t i, bool val) {
        if (i >= count) return;
        if (val) data[i >> 3] |= (1 << (i & 7));
        else data[i >> 3] &= ~(1 << (i & 7));
    }
    void insert(size_t i, bool val) {
        if (i > count) i = count;
        size_t newCount = count + 1;
        size_t newBytes = (newCount + 7) / 8;
        if (data.size() < newBytes) data.push_back(0);
        // Word-wise ripple: every bit from `i` up moves one place right.
        // Whole bytes first, TOP-DOWN (each takes the still-original bit
        // 7 of the byte below it), then the partial byte at the insert
        // point — O(bytes), not O(bits).
        // endByte must span the NEW top byte ((count)>>3): when count is a
        // multiple of 8 the old top bit crosses into a fresh byte, and the
        // old (count+7)>>3 bound stopped one short — silently dropping
        // that bit whenever it was set (latent flag-corruption bug, now
        // load-bearing for the modified-bit array too).
        const size_t startByte = i >> 3;
        const size_t endByte = (count >> 3) + 1;
        for (size_t b = endByte; b-- > startByte + 1;) {
            data[b] = (uint8_t)((data[b] << 1) | ((data[b-1] >> 7) & 1u));
        }
        const uint8_t shift = (uint8_t)(i & 7);
        const uint8_t lo = data[startByte] & (uint8_t)((1u << shift) - 1);
        const uint8_t hi = (uint8_t)(data[startByte] >> shift); // bits at/above i
        data[startByte] = (uint8_t)(lo
            | ((uint8_t)(val ? 1u : 0u) << shift)
            | (uint8_t)(hi << 1)); // hi's bit-7 overflow already carried up
        count = newCount;
    }
    void erase(size_t i) {
        if (i >= count) return;
        // Mirror of insert: bits from `i` up move one place left. Whole
        // bytes first, ASCENDING (each takes the still-original bit 0 of
        // the byte above it), then the partial byte at the erase point.
        const size_t startByte = i >> 3;
        const size_t endByte = (count + 7) >> 3;
        const uint8_t shift = (uint8_t)(i & 7);
        const uint8_t nextBit0 = (startByte + 1 < endByte)
            ? (uint8_t)(data[startByte + 1] << 7) : 0; // captured before the loop rewrites it
        for (size_t b = startByte + 1; b < endByte; ++b) {
            const uint8_t carry = (b + 1 < endByte) ? (uint8_t)(data[b + 1] << 7) : 0;
            data[b] = (uint8_t)((data[b] >> 1) | carry);
        }
        const uint8_t lo = data[startByte] & (uint8_t)((1u << shift) - 1);
        const uint8_t hi = (uint8_t)(data[startByte] >> (shift + 1)); // bits above i, one down
        data[startByte] = (uint8_t)(lo | (uint8_t)(hi << shift) | nextBit0);
        count--;
        if (count % 8 != 0) {
            set(count, false); // Clear the orphaned bit
        } else if (!data.empty()) {
            data.pop_back(); // Shrink the byte array
        }
    }
    size_t size() const { return count; }
};

// ============================================================================
// 12-Byte Packed Note Struct (96-bit bit-stream)
// ----------------------------------------------------------------------------
//   [0..47]  position (100ns ticks)      — first8 bits [0..47]
//   [48..71] duration (1ms ticks)        — LOW 16 bits in first8 [48..63],
//                                           HIGH 8 bits in last4 [0..7]
//   [72..81] index   (column, 10 bits)   — last4 [8..17]
//   [82..89] type    (notetype, 8 bits)  — last4 [18..25]
//   [90..95] lane    (strumline, 6 bits) — last4 [26..31]
// The lane (which strumline owns the note) is stored WITH the note — the
// chart editor needs a per-note lane property and the old 10-byte format
// had nowhere to put one (the lane used to be re-derived from the
// notetype routing table at every read). 12 bytes is the minimum element
// size that fits these fields, and it divides by 4: every element in a
// packed array lands on a 4-byte boundary (the old 10-byte records only
// managed 2).
// ============================================================================
#pragma pack(push, 1)
struct ChartNote {
    uint64_t first8; // position + duration's low 16 bits
    uint32_t last4;  // duration's high 8 bits, index, type, lane
};
#pragma pack(pop)
static_assert(sizeof(ChartNote) == 12, "ChartNote must be exactly 12 bytes!");
static_assert(sizeof(ChartNote) % 4 == 0, "ChartNote must stay 4-byte aligned!");

// Field pack/unpack — the ONLY places that know the bit positions.
static inline ChartNote packNote(uint64_t position, uint32_t duration, uint32_t index, uint32_t type, uint32_t lane) {
    ChartNote n;
    n.first8 = (position & 0x0000FFFFFFFFFFFFULL) | ((uint64_t)(duration & 0xFFFF) << 48);
    n.last4 = ((duration >> 16) & 0xFF)
        | ((index & 0x3FF) << 8)
        | ((type & 0xFF) << 18)
        | ((lane & 0x3F) << 26);
    return n;
}
static inline uint64_t notePos(const ChartNote& n)  { return n.first8 & 0x0000FFFFFFFFFFFFULL; }
static inline uint32_t noteDur(const ChartNote& n)  { return (uint32_t)(n.first8 >> 48) | ((n.last4 & 0xFF) << 16); }
static inline uint32_t noteIdx(const ChartNote& n)  { return (n.last4 >> 8) & 0x3FF; }
static inline uint32_t noteType(const ChartNote& n) { return (n.last4 >> 18) & 0xFF; }
static inline uint32_t noteLane(const ChartNote& n) { return (n.last4 >> 26) & 0x3F; }

// .fvc snapshot file header (v2). A file WITHOUT this magic is the legacy
// v1 format: a bare run of 10-byte notes ([0..47] pos, [48..63] dur16,
// [64..71] index, [72..79] type — no lane field).
#pragma pack(push, 1)
struct FvcFileHeader {
    char     magic[4];   // "FVC2"
    uint32_t noteCount;  // notes following the header
    uint32_t noteSize;   // sizeof(ChartNote) — the reader rejects mismatches
    uint32_t flags;      // 0 (reserved)
};
#pragma pack(pop)
static_assert(sizeof(FvcFileHeader) == 16, "FvcFileHeader must be exactly 16 bytes!");

// Helper function to sort an array of ChartNote in-place
static void radix_sort_notes_inplace(ChartNote* notes, size_t n) {
    if (n <= 1) return;
    // One pass: max position + sortedness. Already-sorted input (the
    // common transpiler case) skips the n*12-byte buffer entirely.
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
    // LSD Radix Sort
    for (int shift = 0; shift < passes * 8; shift += 8) {
        uint32_t counts[256] = {0};
        for (size_t i = 0; i < n; ++i) {
            uint64_t val = notePos(src[i]);
            counts[(val >> shift) & 0xFF]++;
        }
        for (int j = 1; j < 256; ++j) counts[j] += counts[j-1];
        for (int64_t j = (int64_t)n - 1; j >= 0; --j) {
            uint64_t val = notePos(src[j]);
            uint8_t idx = (val >> shift) & 0xFF;
            dst[--counts[idx]] = src[j];
        }
        std::swap(src, dst);
    }
    if (src != notes) {
        std::memcpy(notes, src, n * sizeof(ChartNote));
    }
}

// ============================================================================
// Sharded Note Store — the "split structure"
// ----------------------------------------------------------------------------
// The chart is split into fixed-width TIME SHARDS: 1/4 second segments
// (25,000,000 ticks of 100ns), exactly the "shards" the Chart.hx docs
// describe. Each shard is one of two things at any moment:
//
//   OPEN    — the editable layout: notes split into RUNS of at most
//             RUN_MAX notes (see below), plus judge/hit flag bits.
//   CLOSED  — one opaque compressed blob: the two note halves planar-
//             separated (first-64-bit plane, then last-32-bit plane),
//             each zigzag-delta varint coded, plus RLE'd flag planes.
//             The blob header lists its note count.
//
// A shard opens (decode) on ANY touch — read, insert, remove, flag
// write, save — and the decoded runs REPLACE nothing about the blob:
// the old compressed bytes stay intact until the shard is edited, so a
// read-only touch keeps the exact blob it came from. When a shard is
// closed (LRU eviction, or store-level closeAll), the editable runs
// are destroyed; only an EDITED shard is recompressed (a clean one
// keeps its original blob, byte-identical — free idempotence).
//
//   READ   id -> shard (binary search, or the last-shard cache during
//          sequential sweeps) -> run by arithmetic -> O(1) slot.
//   ADD    position -> shard -> open if closed -> run by arithmetic ->
//          one small sorted insert inside that run (memmove of at most
//          RUN_MAX * 12 bytes, not the shard, never the chart).
//          When a run overflows RUN_MAX it SPLITS in place (the back
//          half moves to a new run), keeping inserts O(run) forever.
//   REMOVE id -> shard -> run -> one small erase; an underflowed run
//          (0 notes) is dropped; empty shards are dropped.
//
// The .fvc file on disk is the segmented FVC4 snapshot (or a legacy FVC3/
// FVC2/v1 image, upgraded on the next save): load is one sequential pass,
// save re-encodes only modified segments (see the Fvc4Header comment), and
// structural edits never touch the disk until saveChart()/destroy (which
// mirrors the old mmap semantics). Compression is a RAM measure.
// ============================================================================

// ---------------------------------------------------------------------------
// Varint codec for the compressed blob: LEB128 u64. Zigzag handles signed
// deltas (durations can go down as well as up between notes).
// ---------------------------------------------------------------------------
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
        if (shift > 63) break; // corrupt stream — stop rather than loop
    }
    return nullptr;
}
static inline void blob_puti(std::vector<uint8_t>& out, int64_t v) {
    blob_putu(out, (uint64_t)((v << 1) ^ (v >> 63))); // zigzag
}
static inline const uint8_t* blob_geti(const uint8_t* p, const uint8_t* end, int64_t& v) {
    uint64_t u;
    p = blob_getu(p, end, u);
    if (!p) return nullptr;
    v = (int64_t)((u >> 1) ^ (~(u & 1) + 1)); // un-zigzag
    return p;
}

// ============================================================================
// FVC3 — COMPRESSED DISK FORMAT (v3)
// ----------------------------------------------------------------------------
// The v2 snapshot stores each note as its raw 12 bytes; a chart whose notes
// sit on an editor grid (they almost always do) wastes nearly all of the
// 48-bit position field. FVC3 factors that structure out:
//
//   header : "FVC3" | u32 noteCount | u8 codec | u32 payloadBytes
//   codec 0 (GRID_KIND): u64 gridDivisor | u16 kindCount | kinds...
//                        then varint planes over the SORTED notes:
//                        positionDelta (grid units), duration (zz), kindId
//   codec 2 (ROWS): u64 gridDivisor | kinds... then ONE bitstream of
//                        row-grouped records (see fvc3_rows_encode) —
//                        the compact path real charts take
//   codec 1 (RAW): the v2 payload verbatim (n * 12 raw bytes)
//
// gridDivisor is the GCD of every position: a 4-minute chart at a 1/16 grid
// collapses from ~2.4e9 100ns-ticks to a few thousand grid steps. A "kind"
// is the (index|type|lane) triple — charts use a handful of distinct
// triples, so the dictionary turns 3 planes into one tiny id per note.
//
// ROWS groups notes that share a position into rows and codes the whole
// chart as a single LSB-first bitstream: per row a 2-bit gap code (1/2/4
// common gaps, escape -> varint), a 2-bit count code (1/2/3, escape), per
// note a ceil(log2(kindCount))-bit kind id and a sustain flag, and only
// flagged sustains carry a zigzag-delta varint (durations come in bursts,
// so the delta chain is tiny). A gridded stream lands at ~1 B/note vs 12
// raw. The writer encodes ALL candidates and keeps the smallest: charts
// with no grid at all (positions with GCD 1) still compress (varint gaps),
// and a truly hostile payload falls back to RAW.
// ============================================================================
#pragma pack(push, 1)
struct Fvc3Header {
    char     magic[4];   // "FVC3"
    uint32_t noteCount;
    uint32_t payloadBytes;
    uint8_t  codec;      // 0 = grid+kind, 1 = raw fallback
    uint8_t  pad[3];     // zero — keeps the header a clean 16 bytes
};
#pragma pack(pop)
static_assert(sizeof(Fvc3Header) == 16, "Fvc3Header must be exactly 16 bytes!");

static constexpr uint8_t  FVC3_CODEC_GRID_KIND = 0;
static constexpr uint8_t  FVC3_CODEC_RAW       = 1;
static constexpr uint8_t  FVC3_CODEC_ROWS      = 2;
static constexpr uint8_t  FVC3_CODEC_AC        = 3; // adaptive range coder + LZP row matches
static constexpr uint16_t FVC3_MAX_KINDS       = 4096; // fallback to RAW beyond this
// Max notes one ROWS row may code (count-1 must fit a small varint; a
// position with more notes splits into continuation rows coded gap 0).
static constexpr uint32_t FVC3_ROWS_MAX_ROW    = 255;

// ============================================================================
// FVC4 segmented container — the incremental save format.
// ----------------------------------------------------------------------------
// A v3 file is ONE fvc3_encode image of the whole chart, so any single-note
// edit forces a full-chart re-encode on save. FVC4 keeps the v3 codec (and
// its FNV) EXACTLY as it is, but splits the chart into ADAPTIVE SEGMENTS of
// 2..32 consecutive shards (0.5 s .. 8 s of chart), each written as a
// complete standalone FVC3 image:
//
//   Fvc4Header{ "FVC4", noteCount, segCount } followed by segCount
//   Fvc4SegEntry{ startTick, noteCount, imageBytes } records, then the
//   segment images back to back (in tick order).
//
// A segment closes early once it holds >= 2 shards AND SEGMENT_NOTE_BUDGET
// notes — dense regions re-encode in cheap units on edit-save, sparse
// regions keep the long AC/LZP history compression wants — or across a
// silence gap wider than 32 shards. A segment image is byte-identical to
// what fvc3_encode produced for those notes alone — nothing about the codec
// changed. Saving re-encodes only the segments whose shards were
// structurally modified (the store's 1-bit modified array, below);
// untouched segments are memcpy'd to disk without even opening their
// shards. Old FVC3 (and FVC2/v1) files load as one segment and upgrade on
// the next save.
// ============================================================================
#pragma pack(push, 1)
struct Fvc4Header {
    char     magic[4];   // "FVC4"
    uint32_t noteCount;  // whole-chart total (cross-checks the directory)
    uint32_t segCount;   // number of Fvc4SegEntry records that follow
};
struct Fvc4SegEntry {
    uint64_t startTick;  // tick of the segment's first shard (shard-aligned; adaptive width)
    uint32_t noteCount;  // notes in this segment (cross-checks the decode)
    uint32_t imageBytes; // length of this segment's FVC3 image
};
#pragma pack(pop)
static_assert(sizeof(Fvc4Header) == 12, "Fvc4Header must be exactly 12 bytes!");
static_assert(sizeof(Fvc4SegEntry) == 16, "Fvc4SegEntry must be exactly 16 bytes!");

// Euclidean GCD — std::__gcd is a GCC/Clang extension, not on MSVC.
static uint64_t fvc3_gcd(uint64_t a, uint64_t b) {
    while (b) { const uint64_t t = a % b; a = b; b = t; }
    return a;
}

// ---- LSB-first bit writer/reader for the ROWS codec ----------------------
// Varints inside the bitstream use the same 7+1 LEB128 coding as
// blob_putu, just not byte-aligned (8-bit groups through the bit layer).
struct Fvc3BitW {
    std::vector<uint8_t>& out;
    uint32_t acc = 0; int nbits = 0;
    explicit Fvc3BitW(std::vector<uint8_t>& o) : out(o) {}
    void put(uint32_t v, int bits) { // v < (1u << bits), bits <= 16
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
        // The encoder flushes <= 7 padding bits; the reader must land on
        // the final byte with no whole byte left over.
        return p == end && nbits < 8;
    }
};

// ceil(log2(kindCount)) — the kind-id bit width. kindCount is 1..4096,
// so this is 1..12 bits. A single-kind chart codes every id in 1 bit.
static int fvc3_kindBits(uint64_t kindCount) {
    int bits = 1;
    while ((1ULL << bits) < kindCount) ++bits;
    return bits;
}

// ---- ROWS codec (codec 2) -------------------------------------------------
// Payload: varint grid | varint kindCount | varint kinds... |
//          varint gapA | varint gapB | varint gapC | bitstream
//   gapA/B/C = the three most frequent row gaps in this chart (histogram
//   top-3; duplicates when fewer distinct gaps exist) — the common gaps
//   code in 2 bits each, whatever they are. A grid misaligned by a
//   lead-in offset (e.g. every gap = 3) still codes at the minimum.
//   bitstream:
//     1 bit  durMode (1 = durations coded in durUnit units, see below)
//     [durMode 1] varint durUnit (GCD of all sustain durations)
//     per row (rows self-terminate when noteCount notes are decoded):
//       gap   2 bits: 0->gapA, 1->gapB, 2->gapC, 3->escape varint(gap)
//             gap = grid units from the previous row's position (the
//             first row measures from 0; gap 0 = continuation row for a
//             position with > FVC3_ROWS_MAX_ROW notes)
//       count 2 bits: 0->1, 1->2, 2->3, 3->escape varint(count-1)
//       per note: kindId (fvc3_kindBits(kindCount) bits), sustain flag
//                 (1 bit), and if flagged a zigzag-delta varint of the
//                 duration in coded units, chained in decode order
// ---------------------------------------------------------------------------
static void fvc3_rows_encode(const ChartNote* notes, size_t n, uint64_t grid,
    std::vector<uint8_t>& out,
    const std::vector<uint32_t>* kindsIn = nullptr,
    const std::vector<uint32_t>* idsIn = nullptr) {
    // kinds (order of first appearance — the decoder rebuilds it; hashed
    // lookup because a megachart can carry hundreds of distinct kinds and
    // the old linear scan was O(n*kinds)). fvc3_encode already built this
    // exact dictionary for GRID_KIND; reuse it when handed in — identical
    // bytes, one hash pass instead of two.
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
            } else {
                id = it->second;
            }
            idsLocal[i] = id;
        }
    }
    const std::vector<uint32_t>& kinds = kindsIn ? *kindsIn : kindsLocal;
    const std::vector<uint32_t>& ids   = idsIn   ? *idsIn   : idsLocal;
    // Durations in their OWN grid (GCD of all sustain durations) when one
    // exists — a chart-snapped sustain codes as a tiny delta in durUnit
    // units instead of a multi-byte raw-tick varint. durUnit 1 = raw ticks.
    // 1 is the floor — stop the moment it is reached.
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
    // Row pass 1: group positions, histogram the gaps, pick the top-3
    // codes (count desc, then value asc for determinism).
    struct RowRec { uint64_t gpos; uint32_t len; };
    std::vector<RowRec> rows;
    rows.reserve(n);
    // gap -> histogram slot (hashed — "distinct gaps are few" is a lie on
    // a free-timed megachart, where nearly every row introduces a new gap
    // and the old linear scan went quadratic)
    std::unordered_map<uint64_t, uint32_t> gapHist;
    uint64_t prevPos = 0;
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        const uint64_t pos = notePos(notes[i]);
        while (j < n && notePos(notes[j]) == pos
            && (j - i) < (size_t)FVC3_ROWS_MAX_ROW) ++j;
        const uint64_t gpos = pos / grid;
        const uint64_t gap = gpos - prevPos;
        ++gapHist[gap];
        rows.push_back({gpos, (uint32_t)(j - i)});
        prevPos = gpos;
        i = j;
    }
    uint64_t gapCode[3] = {1, 1, 1}; // safe defaults (any value; unused codes just never fire)
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
    // Row pass 2: emit the bitstream.
    Fvc3BitW bw(out);
    bw.put(durGrid ? 1u : 0u, 1);
    if (durGrid) bw.putVarint(durUnit);
    prevPos = 0;
    int64_t prevDur = 0;   // absolute, in coded units
    size_t noteI = 0;
    for (const RowRec& r : rows) {
        const uint64_t gap = r.gpos - prevPos;
        int code = -1;
        for (int c = 0; c < 3; ++c)
            if (gapCode[c] == gap) { code = c; break; }
        if (code >= 0) bw.put((uint32_t)code, 2);
        else { bw.put(3u, 2); bw.putVarint(gap); }
        const uint64_t cnt = (uint64_t)(r.len - 1); // count-1
        if (cnt < 3) bw.put((uint32_t)cnt, 2);
        else { bw.put(3u, 2); bw.putVarint(cnt); }
        for (uint32_t m = 0; m < r.len; ++m, ++noteI) {
            bw.put(ids[noteI], kindBits);
            const uint32_t d = noteDur(notes[noteI]);
            if (d != 0) {
                bw.put(1u, 1);
                const int64_t abs = durGrid ? (int64_t)(d / durUnit) : (int64_t)d;
                const int64_t dv = abs - prevDur; // delta vs previous sustain
                bw.putVarint((uint64_t)((dv << 1) ^ (dv >> 63))); // zigzag
                prevDur = abs;
            } else {
                bw.put(0u, 1);
            }
        }
        prevPos = r.gpos;
    }
    bw.flush();
}

// Decode a ROWS payload (after the FVC3 file header). Same validation
// contract as the GRID_KIND decoder: any inconsistency rejects the file.
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
        if (!p || (k >> 24) != 0) return false; // idx(10b)|type(8b)|lane(6b) fits 24 bits
        kinds[(size_t)i] = (uint32_t)k;
    }
    uint64_t gapCode[3] = {1, 1, 1};
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
    uint64_t pos = 0;    // grid units
    int64_t prevDur = 0; // absolute, in coded units
    while (out.size() < noteCount) {
        uint32_t gc = 0;
        if (!br.take(gc, 2)) return false;
        uint64_t gap;
        if (gc < 3) gap = gapCode[gc];
        else { if (!br.takeVarint(gap)) return false; }
        // gap 0 = same position (chord at 0, or a >255-note continuation
        // row). Positions can never decrease: the gap decodes unsigned.
        if (pos > 0xFFFFFFFFFFFFULL - gap) return false; // pos+gap must stay 48-bit
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
        if (pos > 0xFFFFFFFFFFFFULL / grid) return false; // pos*grid must stay 48-bit
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
                // Durations are 24-bit; a delta beyond +/-2^43 is a
                // corrupt stream (also guards prevDur+dv from overflow —
                // prevDur is already bounded to [0, 0xFFFFFF]).
                if (dv > (int64_t)0x7FFFFFFFFFFLL || dv < -(int64_t)0x7FFFFFFFFFFLL) return false;
                const int64_t raw = prevDur + dv;
                prevDur = raw;
                if (raw < 0 || raw > 0xFFFFFF) return false;
                if (durGrid) {
                    if (raw > 0xFFFFFF / (int64_t)durUnit) return false; // raw*durUnit <= 0xFFFFFF
                    dur = (uint32_t)(raw * (int64_t)durUnit);
                } else {
                    dur = (uint32_t)raw;
                }
            }
            const uint32_t k = kinds[id];
            out.push_back(packNote(absPos, dur, (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F));
        }
    }
    return br.consumedExactly();
}

// ---- AC codec (codec 3): adaptive range coder + LZP row matches -------
// Same row stream as ROWS (notes grouped by position, 255-note row cap),
// but every field is arithmetic-coded with adaptive probabilities instead
// of fixed bit codes, plus an LZP match layer that predicts the ENTIRE
// next row from history:
//   payload: varint grid | varint kindCount | varint durUnit | u64 FNV |
//            rc bitstream (kind table deltas, then rows)
//   row   : [LZP hit? 1 bit] — on hit the whole row replays from history;
//           on miss: gap (same-as-prev bit, is0/is1/is2/is3/is4 probes,
//           varint escape; context = class of prev gap x prev-was-hit),
//           count (same-as-prev, is1/is2/is3, escape; ctx = class of prev
//           count), then per note: kind (order-1 bit tree on prev kind),
//           sustain flag (ctx = notes since last sustain), duration
//           (zero-delta shortcut, else adaptive-varint zigzag delta in
//           durUnit units).
// The LZP predictor hashes (prevGap, prevCount, prevKind, prevKind2,
// sinceSustainClass); after a hit the next row is predicted from
// stream[srcIdx(prev)+1] (LZ77-style match extension), so a repeating
// section costs ~1 bit per ROW. The u64 FNV-1a over the decoded note
// bytes is the integrity check — range decoding is chaotic, so any bit
// flip that changes the output fails the hash.
// Overflow-hardened like ROWS: pos*grid and raw*durUnit checked BEFORE
// the multiply, 48-bit pos, 24-bit dur, 255 row, table deltas bounded to
// 24-bit kind keys.
// LZMA-style binary range coder: 11-bit probabilities, adapt shift 5,
// carry-propagating ShiftLow, 5-byte flush. The decoder reads 5 bytes
// upfront; hitting end-of-stream only feeds zeros (flush slack) —
// integrity is the FNV hash's job, not rc.bad.
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
        low = (uint32_t)((uint32_t)low << 8); // shifted-out byte + carry
        // belong to cache/carry — LZMA SDK semantics
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
// adaptive varint: per group 7 value bits + 1 continuation bit, each bit
// its own probability; group index is the context (capped at 10 groups =
// 70 bits, callers stay below 2^56 anyway)
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
// bit tree: nodes probs[1 .. (1<<nbits)-1], root at 1
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
// gap context: 0 = continuation (gap 0), 1..4 = gap value, 5 = other;
// +6 when the previous row was an LZP hit (post-run gaps look different)
static uint32_t fvc3_ac_gapCtx(uint64_t g, bool inRun) {
    return (g == 0 ? 0u : g <= 4 ? (uint32_t)g : 5u) + (inRun ? 6u : 0u);
}
// count context: 0..2 = count 1..3, 3 = >=4
static uint32_t fvc3_ac_cntCtx(uint64_t c) { return c <= 3 ? (uint32_t)(c - 1) : 3u; }
static int fvc3_ac_kindBits(uint64_t kindCount) {
    int bits = 1;
    while ((1ULL << bits) < kindCount) ++bits;
    return bits;
}
struct Fvc3AcModels {
    static const int GCTX = 12; // 6 gap classes x 2 run states
    uint16_t gapSame[GCTX], gapIs0[GCTX], gapIs1[GCTX], gapIs2[GCTX],
        gapIs3[GCTX], gapIs4[GCTX];
    uint16_t gapVar[FVC3_AC_VARINT_GROUPS * 8];
    uint16_t cntSame[4], cntIs1[4], cntIs2[4], cntIs3[4];
    uint16_t cntVar[FVC3_AC_VARINT_GROUPS * 8];
    std::vector<uint16_t> kind; // [ctx*(1<<kindBits) + node]
    bool kindCtx = false;       // order-1 (prev kind) active
    int kindBits = 1;
    uint64_t kindCount = 1;
    uint16_t flag[8];           // ctx = notes since last sustain, capped 7
    uint16_t durZero;           // duration delta == 0
    uint16_t durVar[FVC3_AC_VARINT_GROUPS * 8];
    uint16_t tableVar[FVC3_AC_VARINT_GROUPS * 8]; // kind table deltas
    uint16_t matchBit[8];       // LZP hit/miss, ctx = predicted row length
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
// FNV-1a-64 over the raw note bytes (decode-order) — integrity check
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
    // sorted unique kind keys; ids index into THIS table (decoder rebuilds
    // the same table from ascending deltas, so id space matches).
    // Hash-collect the uniques, sort k << n keys, reindex, hash the ids —
    // replaces sort(all n) + lower_bound-per-note (O(n log n) -> O(n + k log k)).
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
    // kind table first: ascending deltas through the coder
    {
        uint32_t prev = 0;
        for (uint32_t k : kinds) { fvc3_ac_putU(rc, M.tableVar, k - prev); prev = k; }
    }
    // LZP match layer: `stream` records EVERY row in order (coded or
    // replayed) with srcIdx = own index if coded / source index if
    // replayed. Prediction: after a hit, stream[srcIdx(prev)+1] (match
    // extension); otherwise the hash table seed.
    static const size_t FVC3_AC_MATCH_ROWS = 4096;
    // Flat row stream: row r spans [rowOff[r], rowOff[r+1]) of
    // rowKinds/rowDurs. The old per-row vectors cost two heap blocks per
    // row — millions of allocations and hundreds of MB on a megachart —
    // and a reference held across a push_back could dangle; the flat
    // arrays make both impossible.
    std::vector<uint64_t> rowGap;   // per-row gap (grid units)
    std::vector<uint64_t> rowCnt;   // per-row note count
    std::vector<uint64_t> rowOff;   // rows+1 offsets into rowKinds/rowDurs
    std::vector<uint32_t> rowKinds; // concatenated kind ids
    std::vector<uint32_t> rowDurs;  // concatenated durations (coded units)
    rowOff.push_back(0); // begin of row 0
    rowGap.reserve(n / 2 + 1);
    rowCnt.reserve(n / 2 + 1);
    rowOff.reserve(n / 2 + 2);
    rowKinds.reserve(n);
    rowDurs.reserve(n);
    std::vector<int32_t> matchTable(FVC3_AC_MATCH_ROWS, -1);
    uint64_t prevGap = 0, prevCount = 1, prevPos = 0;
    uint32_t prevKind = 0, prevKind2 = 0;
    int sinceSustain = 7; // saturated start
    int64_t prevDur = 0;  // absolute, coded units
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
            predRow = prevSrc + 1;      // match extension
        if (predRow < 0) predRow = matchTable[h]; // hash seed
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
                for (size_t m = i; m < j; ++m) { // state as if coded
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
        // ---- miss: code the row field-by-field ----
        const uint32_t gctx = fvc3_ac_gapCtx(prevGap, prevWasHit);
        if (gap == prevGap) {
            rc.bit(M.gapSame[gctx], 0);
        } else {
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
        } else {
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
            } else {
                rc.bit(M.flag[sinceSustain < 7 ? sinceSustain : 7], 0);
                ++sinceSustain;
            }
        }
        // record the coded row
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
    { // ascending deltas through the coder
        uint32_t prev = 0;
        for (uint64_t i = 0; i < kindCount; ++i) {
            const uint64_t d = fvc3_ac_getU(rc, M.tableVar);
            if (d > 0xFFFFFFu) return false;
            const uint64_t k = (uint64_t)prev + d;
            if (k > 0xFFFFFFu) return false; // idx|type|lane fits 24 bits
            kinds[(size_t)i] = (uint32_t)k;
            prev = (uint32_t)k;
        }
    }
    static const size_t FVC3_AC_MATCH_ROWS_D = 4096;
    // Flat row stream, mirroring the encoder. Values are read by index
    // immediately before any push_back, so a reallocating append can never
    // invalidate them — the per-row-vector design here had exactly that
    // bug (a reference into the stream read after the push: silent
    // use-after-free that only detonated past the small-block heap).
    std::vector<uint64_t> rowGap;
    std::vector<uint64_t> rowCnt;
    std::vector<uint64_t> rowOff; // rows+1 offsets into rowKinds/rowDurs
    std::vector<uint32_t> rowKinds;
    std::vector<uint32_t> rowDurs;
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
            predRow = prevSrc + 1;      // match extension
        if (predRow < 0) predRow = matchTable[h]; // hash seed
        if (predRow >= 0) {
            const uint64_t prCount = rowCnt[(size_t)predRow];
            const uint64_t prGap = rowGap[(size_t)predRow];
            if (!rc.bit(M.matchBit[prCount < 8 ? (uint32_t)prCount : 7])) {
                // HIT: replay the recorded row verbatim (and append the
                // replayed row to the stream so match extension can chain
                // off it). Source values are read by index before each
                // append — safe across reallocation.
                if (prCount < 1 || prCount > FVC3_ROWS_MAX_ROW) return false;
                if (out.size() + prCount > (uint64_t)noteCount) return false;
                if (pos > 0xFFFFFFFFFFFFULL - prGap) return false;
                pos += prGap;
                if (pos > 0xFFFFFFFFFFFFULL / grid) return false;
                const uint64_t absPos = pos * grid;
                const size_t prBeg = (size_t)rowOff[(size_t)predRow];
                for (size_t m = 0; m < prCount; ++m) {
                    const uint32_t id = rowKinds[prBeg + m]; // read first...
                    const uint32_t du = rowDurs[prBeg + m];
                    if (id >= kindCount) return false;
                    const uint32_t k = kinds[id];
                    uint32_t dur = 0;
                    if (du != 0) {
                        if (du > 0xFFFFFF) return false;
                        if (durUnit > 1) {
                            if (du > 0xFFFFFF / durUnit) return false;
                            dur = du * (uint32_t)durUnit;
                        } else {
                            dur = du;
                        }
                    }
                    out.push_back(packNote(absPos, dur, (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F));
                    if (M.kindCount > 1) { prevKind2 = prevKind; prevKind = id; }
                    if (du != 0) { sinceSustain = 0; prevDur = (int64_t)du; }
                    else ++sinceSustain;
                    rowKinds.push_back(id); // ...then append the copy
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
        // ---- miss: decode field-by-field ----
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
                if (gap < 5) return false; // escape only for unprobeable gaps
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
                if (count < 4) return false; // escape only for count >= 4
            }
        }
        if (count < 1 || count > FVC3_ROWS_MAX_ROW) return false;
        if (out.size() + count > (uint64_t)noteCount) return false;
        if (pos > 0xFFFFFFFFFFFFULL / grid) return false;
        const uint64_t absPos = pos * grid;
        // decode notes interleaved as encoded: kind, flag, dur
        uint32_t decIds[256];
        uint32_t decDurs[256];   // coded units (history record)
        uint32_t decDurFin[256]; // final durations (emission)
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
                } else {
                    dur = (uint32_t)raw;
                }
                prevDur = raw;
                decDurs[m] = raw > 0 ? (uint32_t)raw : 0;
                decDurFin[m] = dur;
            } else {
                ++sinceSustain;
                decDurs[m] = 0;
                decDurFin[m] = 0;
            }
        }
        for (uint64_t m = 0; m < count; ++m) {
            const uint32_t k = kinds[decIds[m]];
            out.push_back(packNote(absPos, decDurFin[m], (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F));
        }
        { // record the coded row
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
    // rc.bad here only means the final normalization touched flush slack;
    // a truly truncated or corrupted file fails the hash instead.
    return fvc3_ac_notesHash(out.data(), out.size()) == wantHash;
}

// Encode a SORTED note array as the FVC3 payload (header + payload).
// Encodes ROWS, GRID_KIND, AC and RAW; keeps the smallest (ties: ROWS
// wins — it is the preferred codec; AC only ships when strictly smaller).
// twoThread runs the heavy AC candidate on the worker while the caller
// builds GRID_KIND + ROWS (lone-segment save / transpile). The multi-
// segment save parallelizes ACROSS segments and leaves this false, so
// in-flight threads never exceed 2. Output bytes are identical either way.
static std::vector<uint8_t> fvc3_encode(const ChartNote* notes, size_t n, bool twoThread) {
    const size_t rawSize = n * sizeof(ChartNote);
    // ---- grid: GCD of every position (1 is the floor — stop early) ----
    uint64_t grid = 0;
    for (size_t i = 0; i < n; ++i) {
        const uint64_t p = notePos(notes[i]);
        grid = grid ? fvc3_gcd(grid, p) : p;
        if (grid == 1) break;
    }
    if (grid == 0) grid = 1; // all-zero positions (empty/single note at 0)
    // ---- kinds: first-appearance dictionary, SHARED by GRID_KIND + ROWS ----
    // (hashed lookup — the linear scan was O(n*kinds), which a megachart
    // with hundreds of distinct kinds turns into billions of comparisons;
    // first-appearance order is kept, so the bytes this emits are identical
    // to the old scan)
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
        } else {
            id = it->second;
        }
        ids[i] = id;
    }
    const bool gkOk = kinds.size() <= FVC3_MAX_KINDS;
    std::vector<uint8_t> gk, rows, ac;
    bool gkTooBig = false;
    auto buildCheap = [&]() {
        if (!gkOk) return;
        // ---- candidate 1: grid + kind dictionary + varint planes ----
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
            if (gk.size() >= rawSize) { gkTooBig = true; break; } // can only lose from here
        }
        // ---- candidate 2: ROWS bitstream (shared kind table) ----
        fvc3_rows_encode(notes, n, grid, rows, &kinds, &ids);
    };
    // ---- candidate 3: AC (adaptive range coder + LZP row matches) ----
    auto buildAc = [&]() { if (gkOk) fvc3_ac_encode(notes, n, grid, ac); };
    if (twoThread && gkOk && n >= 2048) chart_dual_run(buildCheap, buildAc);
    else { buildCheap(); buildAc(); }
    // ---- pick the smallest (ROWS > AC > GRID_KIND > RAW on ties) ----
    const size_t gkCost = gkTooBig ? SIZE_MAX : gk.size();
    std::vector<uint8_t> payload;
    uint8_t codec;
    if (gkOk && !rows.empty() && rows.size() <= gkCost && rows.size() <= rawSize
        && rows.size() <= ac.size()) {
        codec = FVC3_CODEC_ROWS; payload = std::move(rows);
    } else if (gkOk && !ac.empty() && ac.size() <= gkCost && ac.size() <= rawSize) {
        codec = FVC3_CODEC_AC; payload = std::move(ac);
    } else if (gkOk && !gkTooBig && gk.size() < rawSize) {
        codec = FVC3_CODEC_GRID_KIND; payload = std::move(gk);
    } else {
        // ---- candidate 4: raw 12-byte stream ----
        codec = FVC3_CODEC_RAW;
        payload.resize(rawSize);
        if (n) std::memcpy(payload.data(), notes, rawSize);
    }
    std::vector<uint8_t> out;
    out.reserve(16 + payload.size());
    Fvc3Header hdr{}; // zero-init: pad[3] must be deterministic on disk
    std::memcpy(hdr.magic, "FVC3", 4);
    hdr.noteCount = (uint32_t)n;
    hdr.codec = codec;
    hdr.payloadBytes = (uint32_t)payload.size();
    out.insert(out.end(), reinterpret_cast<const uint8_t*>(&hdr),
        reinterpret_cast<const uint8_t*>(&hdr) + sizeof(hdr));
    out.insert(out.end(), payload.begin(), payload.end());
    return out;
}
// Original entry point kept — serial candidates (multi-segment workers).
static std::vector<uint8_t> fvc3_encode(const ChartNote* notes, size_t n) {
    return fvc3_encode(notes, n, false);
}

// Decode a complete FVC3 file image (header + payload) into `out` (sorted,
// position-ascending). Returns false on any inconsistency; the caller
// rejects the file rather than loading partial data.
static bool fvc3_decode(const uint8_t* data, size_t size, std::vector<ChartNote>& out) {
    if (size < sizeof(Fvc3Header)) return false;
    Fvc3Header hdr;
    std::memcpy(&hdr, data, sizeof(hdr));
    if (std::memcmp(hdr.magic, "FVC3", 4) != 0) return false;
    const uint8_t* p = data + sizeof(Fvc3Header);
    const uint8_t* end = data + size;
    if ((size_t)(end - p) < hdr.payloadBytes) return false;
    end = p + hdr.payloadBytes; // trailing junk = corrupt
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
        if (!p || (k >> 24) != 0) return false; // idx(10b)|type(8b)|lane(6b) fits 24 bits
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
        // positions are sorted and non-negative: deltas can only grow
        if (dP > 0xFFFFFFFFFFFFULL) return false;
        prevP += dP;
        prevD += dD;
        if (prevP > 0xFFFFFFFFFFFFULL / (grid ? grid : 1) + 1) return false; // pos must fit 48 bits
        const uint64_t pos = prevP * grid;
        if (pos > 0xFFFFFFFFFFFFULL) return false;
        if (prevD < 0 || prevD > 0xFFFFFF) return false; // duration is 24 bits
        const uint32_t k = kinds[(size_t)id];
        out[i] = packNote(pos, (uint32_t)prevD, (k >> 16) & 0x3FF, (k >> 8) & 0xFF, k & 0x3F);
    }
    return p == end;
}

// ---------------------------------------------------------------------------
// Adaptive FVC4 segment planner — shared by the store's save path and the
// transpiler so both produce IDENTICAL boundaries for the same chart (the
// first save after a transpile/load then re-encodes nothing).
// A segment spans minShards..maxShards consecutive shards; it closes early
// once it holds >= minShards shards AND noteBudget notes (dense regions
// re-encode cheaply, sparse regions keep long AC/LZP history), or across a
// silence gap wider than maxShards shards. A lone trailing shard of a
// contiguous run is absorbed into the previous segment when capacity
// allows, so the min-shard floor holds everywhere except a chart that is a
// single shard (or an isolated shard after a gap).
// ---------------------------------------------------------------------------
struct ChartSegShard { uint64_t startTick; uint32_t noteCount; bool modified; };
struct ChartSegRange {
    size_t firstShard = 0, lastShard = 0; // [first, last] inclusive
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
            // Honor the min-shard floor: absorb a lone trailing shard
            // when the break isn't a silence gap and capacity allows.
            if (startNew && !gapped && si + 1 == sh.size() && cnt < maxShards)
                startNew = false;
        }
        if (startNew) {
            ChartSegRange r;
            r.firstShard = si;
            r.lastShard = si;
            r.startTick = sh[si].startTick; // first shard's tick
            plan.push_back(r);
        } else {
            plan.back().lastShard = si;
        }
        plan.back().noteCount += sh[si].noteCount;
        if (sh[si].modified) plan.back().dirty = true;
    }
    return plan;
}

// Encode a batch of flat note arrays into FVC3 images on two threads.
// >= 2 flats: split by NOTE VOLUME across caller + one worker (each encode
// is serial inside). Exactly 1 flat: parallelize INSIDE fvc3_encode (AC on
// the worker) instead. Flats are freed as they are consumed. Never more
// than 2 threads in flight.
static void chart_encode_segments_mt(std::vector<std::vector<ChartNote>>& flats,
    std::vector<std::vector<uint8_t>>& images) {
    images.clear();
    images.resize(flats.size());
    if (flats.empty()) return;
    auto encodeRange = [&](size_t beg, size_t end) {
        for (size_t k = beg; k < end; ++k) {
            images[k] = fvc3_encode(flats[k].data(), flats[k].size());
            std::vector<ChartNote>().swap(flats[k]); // free as we go
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
        chart_dual_run([&]{ encodeRange(0, half); },
                       [&]{ encodeRange(half, flats.size()); });
    } else {
        images[0] = fvc3_encode(flats[0].data(), flats[0].size(), true);
        std::vector<ChartNote>().swap(flats[0]);
    }
}

// ============================================================================
// Sharded Note Store — LAZY SEGMENT-BACKED store
// ----------------------------------------------------------------------------
// The FVC4 segment is the unit of laziness. At load the store holds ONLY the
// compressed segment images + a directory (startTick / noteCount / baseId).
// Nothing is decoded or encoded until a segment is touched. Opening a
// segment decodes its FVC3 image into ONE flat block of raw 12-byte
// ChartNote records (editable in place); closing it re-encodes only if it
// was edited, then deletes the raw block. Clean segments keep their exact
// image bytes, so an untouched chart costs no decode and no encode.
//
// The 1/4-second SHARD remains the time quantum used by the adaptive
// planner; the shard-named test hooks below alias to segments (the lazy
// unit) so the public API is unchanged.
// ============================================================================
class ShardedNoteStore {
public:
    static constexpr uint64_t POS_MASK = 0x0000FFFFFFFFFFFFULL;
    static constexpr uint64_t SHARD_TICKS = 25000000ULL;
    // Legacy constant kept for API compatibility. Open segments are a flat
    // raw block now (no runs), so this no longer bounds inserts.
    static constexpr size_t RUN_MAX = 128;
    // Open-SEGMENT budget for the LRU (name kept for API compatibility).
    static constexpr size_t OPEN_SHARD_BUDGET = 256;
    static constexpr uint64_t SEGMENT_TICKS = SHARD_TICKS * 4096;
    static constexpr size_t   SEGMENT_MIN_SHARDS  = 2;
    static constexpr size_t   SEGMENT_MAX_SHARDS  = 32;
    static constexpr uint32_t SEGMENT_NOTE_BUDGET = 4096;
    // Legacy CVS1 blob magic kept for API compatibility (the blob codec is
    // gone — segments are FVC3 images end to end).
    static constexpr uint32_t BLOB_MAGIC = 0x31535643;

    // One saved FVC4 segment: its tick and the exact FVC3 image. Public
    // because ChartFileReader's load path builds these straight from disk.
    struct Segment {
        uint64_t startTick = 0;
        uint32_t noteCount = 0;
        std::vector<uint8_t> image;
    };

private:
    // A lazy segment. `image` is authoritative while closed/clean; `notes`
    // is the live editable block while open. Exactly one is meaningful at
    // a time (an open CLEAN segment keeps its pre-edit image too).
    struct Unit {
        uint64_t startTick = 0;
        int64_t  baseId = 0;        // global index of notes[0]
        uint32_t noteCount = 0;     // authoritative count while closed
        bool open = false;
        bool dirty = false;         // edited since the image was made
        std::vector<uint8_t> image; // FVC3 image (valid when !dirty)
        std::vector<ChartNote> notes; // RAW editable 12-byte block (open only)
        BitArray judge;
        BitArray hit;
        size_t size() const { return open ? notes.size() : (size_t)noteCount; }
    };

    std::vector<Unit> units;   // ordered by startTick; no empty units kept
    int64_t totalNotes = 0;
    mutable size_t lastUnit = 0;
    size_t openCount = 0;
    std::vector<size_t> lru;   // front = most recently used open unit
    BitArray modifiedBits;     // index-aligned with `units`

    // ---- LRU --------------------------------------------------------------
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

    // ---- open / close ------------------------------------------------------
    void ensureOpen(size_t ui) {
        Unit& u = units[ui];
        if (!u.open) {
            u.notes.clear();
            const bool ok = !u.image.empty()
                && fvc3_decode(u.image.data(), u.image.size(), u.notes)
                && u.notes.size() == (size_t)u.noteCount;
            if (!ok) {
                std::cerr << "  [ Chart File ] CORRUPT SEGMENT — refusing to decode" << std::endl;
                // Leave a CONSISTENT empty editable unit; totals rebuilt.
                u.notes.clear();
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
            u.open = true;
            u.dirty = false;
            u.judge.init(u.notes.size());
            u.hit.init(u.notes.size());
            ++openCount;
        }
        touch(ui);
    }

    // Close: re-encode ONLY if edited, then delete the raw block.
    void closeUnit(Unit& u) {
        if (!u.open) return;
        if (u.dirty) {
            u.image = fvc3_encode(u.notes.data(), u.notes.size());
            u.noteCount = (uint32_t)u.notes.size();
        }
        std::vector<ChartNote>().swap(u.notes); // delete the decompressed data
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

    // ---- lookup ------------------------------------------------------------
    // Last unit with startTick <= pos, or units.size() if pos precedes all.
    // By construction pos < units[idx+1].startTick, so the window is exact.
    size_t findUnitByPos(uint64_t pos) const {
        size_t lo = 0, hi = units.size();
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
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
            size_t mid = lo + (hi - lo) / 2;
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
    size_t shardCount() const { return units.size(); }   // lazy units (segments)
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

    // ---- READ (O(1) inside an open segment) -------------------------------
    uint64_t getFirst8(int64_t id) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        return units[ui].notes[(size_t)(id - units[ui].baseId)].first8;
    }
    uint32_t getLast4(int64_t id) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        return units[ui].notes[(size_t)(id - units[ui].baseId)].last4;
    }
    bool getJudge(int64_t id) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        return units[ui].judge.get((size_t)(id - units[ui].baseId));
    }
    void setJudge(int64_t id, bool value) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        units[ui].judge.set((size_t)(id - units[ui].baseId), value);
        // Gameplay state, not a structural edit: no dirty/modified bit.
    }
    void setHit(int64_t id, bool value) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        units[ui].hit.set((size_t)(id - units[ui].baseId), value);
    }
    bool getHit(int64_t id) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        return units[ui].hit.get((size_t)(id - units[ui].baseId));
    }

    // ---- ADD ---------------------------------------------------------------
    int64_t add(const ChartNote& cn) {
        const uint64_t pos = notePos(cn);
        size_t ui = findUnitByPos(pos);
        if (ui == units.size()) {
            // pos precedes every unit (or the store is empty): new unit at front.
            Unit u;
            u.startTick = pos - (pos % SHARD_TICKS);
            u.open = true;
            u.dirty = true;
            u.noteCount = 0;
            u.judge.init(0);
            u.hit.init(0);
            units.insert(units.begin(), std::move(u));
            for (size_t& idx : lru) ++idx; // directory shifted under the ring
            modifiedBits.insert(0, true);
            ++openCount;
            rebuildTotals();
            lastUnit = 0;
            ui = 0;
            touch(0);
        } else {
            ensureOpen(ui);
            // Safe split-off: appending far past the LAST unit's actual end
            // starts a new unit (order preserved because pos > its max note).
            if (ui + 1 == units.size() && !units[ui].notes.empty()) {
                const uint64_t maxPos = notePos(units[ui].notes.back());
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
        const size_t slot = (size_t)(std::lower_bound(
            u.notes.begin(), u.notes.end(), pos,
            [](const ChartNote& n, uint64_t p) { return notePos(n) < p; }
        ) - u.notes.begin());
        u.notes.insert(u.notes.begin() + (long)slot, cn);
        u.judge.insert(slot, false);
        u.hit.insert(slot, false);
        u.dirty = true;
        modifiedBits.set(ui, true);
        ++totalNotes;
        for (size_t k = ui + 1; k < units.size(); ++k) ++units[k].baseId;
        lastUnit = ui;
        return u.baseId + (int64_t)slot;
    }

    // ---- REMOVE ------------------------------------------------------------
    void remove(int64_t id) {
        size_t ui = unitById(id);
        ensureOpen(ui);
        Unit& u = units[ui];
        const size_t slot = (size_t)(id - u.baseId);
        u.notes.erase(u.notes.begin() + (long)slot);
        u.judge.erase(slot);
        u.hit.erase(slot);
        u.dirty = true;
        modifiedBits.set(ui, true);
        --totalNotes;
        const bool gone = u.notes.empty();
        if (gone) {
            for (size_t k = 0; k < lru.size(); ) {
                if (lru[k] == ui) { lru.erase(lru.begin() + (long)k); continue; }
                if (lru[k] > ui) --lru[k];
                ++k;
            }
            std::vector<ChartNote>().swap(u.notes);
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

    // ---- LAZY LOAD (FVC4) --------------------------------------------------
    // Adopt the exact on-disk images as the closed/clean units. NO decode,
    // NO encode — just the directory + prefix sums. This is the whole load.
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
            u.open = false;
            u.dirty = false;
            units.push_back(std::move(u));
        }
        totalNotes = base;
        modifiedBits.init(units.size()); // all clean
    }

    // ---- EAGER LOAD (legacy FVC3/FVC2/v1, or a flat source) ----------------
    // Plans adaptive segments and encodes them once (two threads). Used only
    // for non-FVC4 sources; FVC4 takes the lazy path above.
    void loadFromSortedFlat(const ChartNote* data, size_t n) {
        clear();
        if (n == 0) { modifiedBits.init(0); return; }
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
        std::vector<std::vector<ChartNote>> flats(ranges.size());
        for (size_t r = 0; r < ranges.size(); ++r) {
            const size_t beg = offs[ranges[r].firstShard];
            const size_t end = offs[ranges[r].lastShard] + infos[ranges[r].lastShard].noteCount;
            flats[r].assign(data + beg, data + end);
        }
        std::vector<std::vector<uint8_t>> images;
        chart_encode_segments_mt(flats, images);
        units.reserve(ranges.size());
        int64_t base = 0;
        for (size_t r = 0; r < ranges.size(); ++r) {
            Unit u;
            u.startTick = ranges[r].startTick;
            u.noteCount = ranges[r].noteCount;
            u.baseId = base;
            base += (int64_t)ranges[r].noteCount;
            u.image = std::move(images[r]);
            units.push_back(std::move(u));
        }
        totalNotes = (int64_t)n;
        modifiedBits.init(units.size());
    }

    // ---- SAVE (FVC4, incremental) -----------------------------------------
    // Clean units emit their cached image VERBATIM (never opened). Dirty
    // units re-plan their raw notes into adaptive sub-segments and encode
    // those on two threads. Clean boundaries never move, so an edit never
    // invalidates a neighbouring segment's cache.
    bool writeTo(const char* path) {
        struct Piece {
            uint64_t startTick = 0;
            uint32_t noteCount = 0;
            const std::vector<uint8_t>* cached = nullptr; // clean reuse
            std::vector<uint8_t> image;                   // re-encoded
            size_t srcUnit = 0;
        };
        std::vector<Piece> pieces;
        std::vector<std::vector<ChartNote>> flats; // parallel to re-encoded pieces

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
            if (u.notes.empty()) continue; // empty new unit: drop it
            // Dirty: derive the shard directory from the raw block, plan,
            // and slice into flats for the threaded encoder.
            std::vector<ChartSegShard> infos;
            std::vector<size_t> offs;
            size_t i = 0;
            while (i < u.notes.size()) {
                const uint64_t st = notePos(u.notes[i]) - (notePos(u.notes[i]) % SHARD_TICKS);
                size_t j = i;
                while (j < u.notes.size() && notePos(u.notes[j]) - st < SHARD_TICKS) ++j;
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
                flats.emplace_back(u.notes.begin() + (long)beg, u.notes.begin() + (long)end);
            }
        }

        std::vector<std::vector<uint8_t>> images;
        chart_encode_segments_mt(flats, images);
        {
            size_t k = 0;
            for (Piece& p : pieces)
                if (!p.cached) p.image = std::move(images[k++]);
        }

        // Write header + directory + images in one sequential pass.
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

        // Commit: clean units move as-is (open state + flags preserved);
        // dirty units are replaced by their new closed/clean sub-segments
        // and their raw blocks are deleted.
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
            } else {
                while (pi < pieces.size() && pieces[pi].srcUnit == ui) {
                    Unit nu;
                    nu.startTick = pieces[pi].startTick;
                    nu.noteCount = pieces[pi].noteCount;
                    nu.baseId = base;
                    base += (int64_t)nu.noteCount;
                    nu.image = std::move(pieces[pi].image);
                    nu.open = false;
                    nu.dirty = false;
                    next.push_back(std::move(nu));
                    ++pi;
                }
                std::vector<ChartNote>().swap(u.notes);
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
        modifiedBits.init(units.size()); // saved == on-disk
        return true;
    }

    // ---- DEBUG / TESTS -----------------------------------------------------
    bool isSorted() const {
        uint64_t prev = 0;
        for (const Unit& u : units) {
            if (!u.open) continue; // closed units are sorted by construction
            for (const ChartNote& n : u.notes) {
                const uint64_t p = notePos(n);
                if (p < prev) return false;
                prev = p;
            }
        }
        return true;
    }
    // Shard-named hooks alias to the lazy unit (segment).
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

// ============================================================================
// Chart File — .fvc snapshot + live sharded store
// ============================================================================
static bool ends_with_fvc(const std::string& str) {
    static const std::string suffix = ".fvc";
    if (suffix.size() > str.size()) return false;
    return str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
}

class ChartFileReader {
private:
    std::string filename;
    ShardedNoteStore store;
    bool loadedFromDisk = false; // a .fvc path is bound to this reader
    bool dirty = false;          // structural edits not yet saved
    bool editorMode = false;
    bool applyingNotes = false;
    mutable std::mutex dataMutex;
    // Load a .fvc snapshot into the sharded store. Four on-disk formats:
    //   v4 ("FVC4" header): SEGMENTED — adaptive 2..32-shard segments,
    //   each a standalone FVC3 image; the current save format. Decoded
    //   on two threads.
    //   v3 ("FVC3" header): COMPRESSED — grid+kind varint planes, ROWS,
    //   AC, or a raw fallback payload; the previous monolithic format.
    //   v2 ("FVC2" header): 16-byte header + 12-byte notes — the previous
    //   format, with the lane (strumline) field stored per note.
    //   v1 (no magic): a bare run of 10-byte notes (pos48 | dur16 | idx8 |
    //   type8 — no lane). Loaded, then converted in RAM: the lane is
    //   derived from the type through the default routing (type 0 →
    //   strumline 0 opponent, everything else → 1 player). The conversion
    //   only lives in RAM + the next save; a save always writes FVC4.
    bool loadFromFvc(const char* path) {
        std::ifstream in(path, std::ios::binary | std::ios::ate);
        if (!in) {
            std::cerr << "  [ Chart File ] Failed to open " << path << std::endl;
            return false;
        }
        const std::streamsize fileSize = in.tellg();
        if (fileSize < 0) return false;
        in.seekg(0, std::ios::beg);

        std::vector<ChartNote> flat;             // legacy sources only
        bool legacy = true;
        bool lazyFvc4 = false;
        std::vector<ShardedNoteStore::Segment> loadedSegments;

        // ---- v4: LAZY. Read bytes + directory, adopt images, decode nothing.
        if (fileSize >= (std::streamsize)sizeof(Fvc4Header)) {
            Fvc4Header h4;
            in.read(reinterpret_cast<char*>(&h4), sizeof(h4));
            if (in.gcount() == (std::streamsize)sizeof(h4)
                && std::memcmp(h4.magic, "FVC4", 4) == 0) {
                legacy = false;
                lazyFvc4 = true;
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
                // Structural validation only (order, shard alignment, bounds,
                // totals). Content integrity is checked on OPEN, per segment.
                const uint8_t* ip = images.data();
                const uint8_t* const iend = images.data() + images.size();
                uint64_t sumNotes = 0;
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
                    << " bytes on disk) — nothing decoded yet" << std::endl;
            } else {
                in.seekg(0, std::ios::beg); // not v4 — try v3
            }
        }

        // ---- v3 (legacy monolithic): eager, unchanged ----
        if (legacy && fileSize >= (std::streamsize)sizeof(Fvc3Header)) {
            Fvc3Header h3;
            in.read(reinterpret_cast<char*>(&h3), sizeof(h3));
            if (in.gcount() == (std::streamsize)sizeof(h3)
                && std::memcmp(h3.magic, "FVC3", 4) == 0) {
                std::vector<uint8_t> image((size_t)fileSize);
                in.seekg(0, std::ios::beg);
                in.read(reinterpret_cast<char*>(image.data()), fileSize);
                if (in.gcount() != fileSize
                    || !fvc3_decode(image.data(), image.size(), flat)) {
                    std::cerr << "  [ Chart File ] Corrupt FVC3 file " << path << std::endl;
                    return false;
                }
                legacy = false;
                std::cout << "  [ Chart File ] FVC3 compressed snapshot (" << flat.size()
                    << " notes, " << fileSize << " bytes on disk)" << std::endl;
            } else {
                in.seekg(0, std::ios::beg);
            }
        }

        // ---- v2 (legacy) ----
        if (legacy && fileSize >= (std::streamsize)sizeof(FvcFileHeader)) {
            FvcFileHeader hdr;
            in.read(reinterpret_cast<char*>(&hdr), sizeof(hdr));
            if (in.gcount() == (std::streamsize)sizeof(hdr)
                && std::memcmp(hdr.magic, "FVC2", 4) == 0) {
                if (hdr.noteSize != sizeof(ChartNote)) {
                    std::cerr << "  [ Chart File ] " << path
                        << " has FVC2 magic but noteSize " << hdr.noteSize
                        << " (expected " << sizeof(ChartNote) << ")" << std::endl;
                    return false;
                }
                legacy = false;
                const std::streamsize payload = fileSize - (std::streamsize)sizeof(FvcFileHeader);
                if (payload % (std::streamsize)sizeof(ChartNote) != 0) {
                    std::cerr << "  [ Chart File ] Trailing bytes in " << path << std::endl;
                    return false;
                }
                const size_t n = (size_t)(payload / (std::streamsize)sizeof(ChartNote));
                if ((uint64_t)n != hdr.noteCount) {
                    std::cerr << "  [ Chart File ] Header/count mismatch in " << path << std::endl;
                    return false;
                }
                flat.resize(n);
                if (n > 0) {
                    in.read(reinterpret_cast<char*>(flat.data()),
                        (std::streamsize)n * (std::streamsize)sizeof(ChartNote));
                    if (in.gcount() != (std::streamsize)(n * sizeof(ChartNote))) {
                        std::cerr << "  [ Chart File ] Truncated read on " << path << std::endl;
                        return false;
                    }
                }
            } else {
                in.seekg(0, std::ios::beg);
            }
        }

        // ---- v1 (legacy 10-byte) ----
        if (legacy) {
            const size_t n = (size_t)fileSize / 10;
            if (n == 0 && fileSize != 0) {
                std::cerr << "  [ Chart File ] Empty non-legacy file " << path << std::endl;
                return false;
            }
            flat.resize(n);
            if (n > 0) {
                std::vector<uint8_t> raw((size_t)fileSize);
                in.read(reinterpret_cast<char*>(raw.data()), fileSize);
                if (in.gcount() != fileSize) {
                    std::cerr << "  [ Chart File ] Truncated read on " << path << std::endl;
                    return false;
                }
                for (size_t i = 0; i < n; ++i) {
                    const uint8_t* r = raw.data() + i * 10;
                    const uint64_t pos = (uint64_t)r[0] | ((uint64_t)r[1] << 8)
                        | ((uint64_t)r[2] << 16) | ((uint64_t)r[3] << 24)
                        | ((uint64_t)r[4] << 32) | ((uint64_t)r[5] << 40);
                    const uint16_t dur16 = (uint16_t)(r[6] | (r[7] << 8));
                    const uint8_t idx = r[8];
                    const uint8_t type = r[9];
                    const uint8_t lane = (type == 0) ? 0 : 1;
                    flat[i] = packNote(pos, dur16, idx, type, lane);
                }
                std::cout << "  [ Chart File ] Legacy 10-byte .fvc (" << n
                    << " notes) — converted to 12-byte in RAM; next save writes FVC4." << std::endl;
            }
        }
        in.close();

        std::lock_guard<std::mutex> lk(dataMutex);
        if (lazyFvc4) {
            // THE WHOLE LOAD: compressed images + directory. Nothing else.
            store.adoptSegments(std::move(loadedSegments));
        } else {
            bool sorted = true;
            uint64_t prev = 0;
            for (size_t i = 0; i < flat.size(); ++i) {
                const uint64_t p = notePos(flat[i]);
                if (p < prev) { sorted = false; break; }
                prev = p;
            }
            if (!sorted) {
                std::cout << "  [ Chart File ] Unsorted .fvc detected — radix sorting." << std::endl;
                radix_sort_notes_inplace(flat.data(), flat.size());
            }
            store.loadFromSortedFlat(flat.data(), flat.size());
        }
        return true;
    }
#ifndef CHART_FILE_NO_TRANSPILER
    // ========================================================================
    // Integrated JSON Transpiler
    // ========================================================================
    // ========================================================================
    // Header File Generator (Backup Plan)
    // ========================================================================
    void writeHeaderFile(const std::string& songDir, const rapidjson::Document& doc, int totalColumns) {
        std::string headerPath = songDir + "/header.txt";
        //std::cout << headerPath << std::endl;
        // Backup plan: If the header already exists, do nothing
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
        std::string player1 = "dad"; // Opponent
        std::string player2 = "bf";  // Player
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
        // Multiply scroll speed by 0.45 for Funkin' Vieew
        speed *= 0.45;
        std::ofstream out(headerPath);
        if (!out) return;
        // Write exactly what the Haxe parser expects, line by line
        out << "Title: " << title << "\n";
        out << "Artist: " << artist << "\n";
        out << "Genre: " << genre << "\n";
        out << "Speed: " << speed << "\n";
        out << "BPM: " << bpm << "\n";
        out << "Time Signature: 4/4\n";
        out << "Stage: " << stage << "\n";
        size_t lastSlash = songDir.find_last_of("/\\");
        std::string songName = (lastSlash == std::string::npos) ? songDir : songDir.substr(lastSlash + 1);
        out << "Instrumental: " << songDir << "/Inst.ogg\n";
        std::ifstream voicesPlayer(songDir + "/Voices-Player.ogg");
        std::ifstream voicesOpponent(songDir + "/Voices-Opponent.ogg");
        bool useTwoVoiceFiles = false;
        if (voicesPlayer.good()) {
            voicesPlayer.close();
            useTwoVoiceFiles = true;
        }
        if (voicesOpponent.good()) {
            voicesOpponent.close();
            useTwoVoiceFiles = true;
        }
        if (useTwoVoiceFiles) {
            std::cout << "  [ Transpiler ] Detected Voices-Player.ogg/Voices-Opponent.ogg for " << title << std::endl;
            out << "Voices: " << songDir << "/Voices-Player.ogg, " << songDir << "/Voices-Opponent.ogg\n";
        } else {
            std::cout << "  [ Transpiler ] Detected Voices.ogg for " << title << std::endl;
            out << "Voices: " << songDir << "/Voices.ogg\n";
        }
        // Use the dynamically detected mania instead of a hardcoded 4!
        out << "Mania: " << totalColumns << "\n";
        out << "Difficulty: #8\n";
        // Game Over block (Haxe reads and ignores the first line, then reads Theme and BPM)
        out << "Game Over:\n";
        out << "Theme: vanilla\n";
        out << "BPM: " << bpm << "\n";
        // Characters block (Haxe reads and ignores the first line, then reads actors)
        out << "Characters:\n";
        // Actor 1 (Opponent) - Exactly 3 lines
        out << player1 << ", enemy\n";
        out << "pos -700 300\n";
        out << "cam 0 45\n";
        // Actor 2 (GF) - Exactly 3 lines
        out << gf << ", other\n";
        out << "pos -100 300\n";
        out << "cam 0 45\n";
        // Actor 3 (Player) - Exactly 3 lines
        out << player2 << ", player\n";
        out << "pos 200 300\n";
        out << "cam 0 45";
        out.close();
        std::cout << "  [ Transpiler ] Generated header.txt for " << title << std::endl;
    }
    // ========================================================================
    // Event JSON Generator (100% Assertion-Free)
    // ========================================================================
    void generateEventJson(const std::string& songDir, const rapidjson::Document& doc) {
        std::string eventsPath = songDir + "/eventList.json";
        // Backup plan: If the eventList.json already exists, do nothing
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
        // Safely check if the document has a "song" object
        if (doc.IsObject() && doc.HasMember("song") && doc["song"].IsObject()) {
            const auto& song = doc["song"];
            // 1. Parse Standard Psych Engine Events (song.events)
            if (song.HasMember("events") && song["events"].IsArray()) {
                const auto& psychEvents = song["events"];
                // SAFETY: We know psychEvents is an array, so GetArray() is safe
                for (auto& eventGroup : psychEvents.GetArray()) {
                    // SAFETY: Check if eventGroup is an array before accessing []
                    if (!eventGroup.IsArray() || eventGroup.Size() < 2) continue;
                    double time_ms = 0.0;
                    if (eventGroup[0].IsNumber()) time_ms = eventGroup[0].GetDouble();
                    // SAFETY: Check if eventGroup[1] is an array before calling GetArray()
                    if (!eventGroup[1].IsArray()) continue;
                    for (auto& subEvent : eventGroup[1].GetArray()) {
                        // SAFETY: Check if subEvent is an array before accessing []
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
            // 2. Parse Legacy Psych/Kade Events embedded in sectionNotes
            if (song.HasMember("notes") && song["notes"].IsArray()) {
                // SAFETY: We know song["notes"] is an array
                for (auto& section : song["notes"].GetArray()) {
                    // SAFETY: Check if section is an object and has sectionNotes as an array
                    if (!section.IsObject() || !section.HasMember("sectionNotes") || !section["sectionNotes"].IsArray()) continue;
                    // SAFETY: We know section["sectionNotes"] is an array
                    for (auto& note : section["sectionNotes"].GetArray()) {
                        // SAFETY: Check if note is an array before accessing []
                        if (!note.IsArray() || note.Size() < 3) continue;
                        // SAFETY: Check if note[1] is a number before calling GetDouble()
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
        // do this before it gets invalidated by closure
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
    // ========================================================================
    // Zero-Overhead Note Writer (Format & Mania Accurate)
    // ------------------------------------------------------------------------
    // `lane` here is the ABSOLUTE column of the SOURCE chart (both sides
    // in one numbering). The v2 note stores the strumline it belongs to
    // in its own LANE field, derived directly from that side — the
    // notetype is a pure pass-through skin id and never decides where a
    // note draws.
    // ========================================================================
    inline bool writeNote(ChartNote& outNote, double time_ms, int lane, double sustain_ms, bool mustHitSection, bool isPsychV1, bool isVSlice, int totalColumns) {
        if (lane < 0) return false;
        // Which strumline (side) owns this note — straight from the
        // source chart's own side encoding, not from any type routing.
        int strumline;
        if (isVSlice) {
            strumline = (lane >= totalColumns) ? 1 : 0;
        } else if (isPsychV1) {
            strumline = (lane < totalColumns) ? 1 : 0;
        } else {
            // Base game: mustHitSection flips which half is the player's.
            bool gottaHitNote = (lane < totalColumns) ? mustHitSection : !mustHitSection;
            strumline = gottaHitNote ? 1 : 0;
        }
        const int index = lane % totalColumns;
        // The notetype is a skin id only. The source formats carry no
        // per-note type (Psych/VSlice type extensions can pass one
        // through here later without touching the lane math), so the
        // default skins keep differing per side the way they always
        // looked: opponent side 0, player side 1.
        const int type = strumline;
        const uint64_t pos = (uint64_t)(time_ms * 100000.0); // 100ns ticks
        const uint32_t dur = (uint32_t)(sustain_ms);         // 1ms ticks
        outNote = packNote(pos, dur, (uint32_t)index, (uint32_t)type, (uint32_t)strumline);
        return true;
    }
    // ========================================================================
    // Main Transpiler
    // ========================================================================
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
        // Determine song directory for the header file
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
                if (fmt.find("psych_v1") != std::string::npos) {
                    isPsychV1 = true;
                }
            }
        }
        // ====================================================================
        // MANIA DETECTION & LEGACY KADE/SHAGGY MOD LOGIC
        // ====================================================================
        int ammo[] = {4, 6, 7, 9};
        int totalColumns = 4;
        if (isPsych) {
            const auto& song = doc["song"];
            if (song.HasMember("mania") && song["mania"].IsInt()) {
                totalColumns = song["mania"].GetInt();
            }
        } else if (isVSlice) {
            if (doc.HasMember("mania") && doc["mania"].IsInt()) {
                totalColumns = doc["mania"].GetInt();
            }
        }
        if (totalColumns < 4) {
            totalColumns = ammo[totalColumns];
        }
        std::cout << "  [ Transpiler ] Detected Mania/Key Count: " << totalColumns << "K" << std::endl;
        // ====================================================================
        // --- CREATE THE .fvc FILE ---
        std::string fvcPath = std::string(jsonPath);
        size_t dot = fvcPath.find_last_of('.');
        if (dot != std::string::npos) fvcPath = fvcPath.substr(0, dot);
        fvcPath += ".fvc";
        std::ofstream out(fvcPath, std::ios::binary | std::ios::trunc);
        if (!out) {
            std::cerr << "  [ Transpiler ] Failed to create .fvc file." << std::endl;
            return;
        }
        // FVC4 snapshot: the notes are collected in RAM through the single
        // pass below, then written once through the shared adaptive
        // segment planner + FVC3 codec (two threads).
        std::vector<ChartNote> collected;
        size_t writeIndex = 0;
        ChartNote currentNote;
        // ====================================================================
        // SINGLE PASS: COUNT AND WRITE NOTES DIRECTLY TO DISK
        // ====================================================================
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
                                // Write directly to disk if valid
                                if (writeNote(currentNote, t, d, l, true, false, true, totalColumns)) {
                                    collected.push_back(currentNote);
                                }
                            }
                        }
                    }
                }
            }
        } else if (isPsych) {
            const auto& song = doc["song"];
            if (song.HasMember("notes") && song["notes"].IsArray()) {
                for (const auto& section : song["notes"].GetArray()) {
                    if (section.IsObject() && section.HasMember("sectionNotes") && section["sectionNotes"].IsArray()) {
                        bool mustHit = true;
                        // SAFETY: Check IsBool() before calling GetBool()
                        if (section.HasMember("mustHitSection") && section["mustHitSection"].IsBool()) {
                            mustHit = section["mustHitSection"].GetBool();
                        }
                        for (const auto& note : section["sectionNotes"].GetArray()) {
                            if (note.IsArray() && note.Size() >= 3) {
                                // ====================================================================
                                // CRITICAL FIX: Skip legacy events (lane == -1)
                                // If we don't skip them, note[2].GetDouble() will assert on "Hey!"
                                // ====================================================================
                                if (note[1].IsNumber() && note[1].GetInt() == -1) continue;
                                // SAFETY: Check IsNumber() before calling GetDouble()/GetInt()
                                double t = note[0].IsNumber() ? note[0].GetDouble() : 0.0;
                                int lane = note[1].IsNumber() ? note[1].GetInt() : 0;
                                double sustain = note[2].IsNumber() ? note[2].GetDouble() : 0.0;
                                // Write directly to disk if valid
                                if (writeNote(currentNote, t, lane, sustain, mustHit, isPsychV1, false, totalColumns)) {
                                    collected.push_back(currentNote);
                                }
                            }
                        }
                    }
                }
            }
        }
        // Sort (the source formats are per-section, not globally ordered).
        radix_sort_notes_inplace(collected.data(), collected.size());
        writeIndex = collected.size();
        if (writeIndex == 0) {
            out.close();
            std::cerr << "  [ Transpiler ] No valid notes found." << std::endl;
            std::remove(fvcPath.c_str()); // Clean up the empty file
            return;
        }
        // FVC4: derive the shard directory exactly as the store's
        // loadFromSortedFlat will, run the SAME adaptive segment planner,
        // and encode the segments on two threads. The boundaries match
        // the first save's plan, so the loaded cache re-encodes nothing.
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
                ChartSegShard inf;
                inf.startTick = st;
                inf.noteCount = (uint32_t)(j - i);
                inf.modified = false;
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
        // ====================================================================
        // Generate header.txt if it doesn't already exist
        writeHeaderFile(songDir, doc, totalColumns);
        // ====================================================================
        // EVENT PARSING ROUTING
        // ====================================================================
        // Check if a standard events.json exists in the song directory
        std::string evtPath = songDir + "/events.json";
        std::ifstream ifs_(evtPath);
        if (!ifs_) {
            // events.json doesn't exist. Extract legacy events from the main chart doc.
            generateEventJson(songDir, doc);
        } else {
            // events.json exists! Parse it and convert it to eventList.json.
            rapidjson::IStreamWrapper jsw(ifs_);
            rapidjson::Document evtDoc;
            evtDoc.ParseStream(jsw);
            ifs_.close();
            if (evtDoc.HasParseError()) {
                std::cerr << "  [ Transpiler ] JSON Parse Error in events.json at offset " << evtDoc.GetErrorOffset() << std::endl;
                return;
            }
            // Pass the parsed events.json document to the generator
            generateEventJson(songDir, evtDoc);
        }
        filename = fvcPath;
    }
    // ========================================================================
    // Header-Only JSON Parser (Used when .fvc exists but header.txt is missing)
    // ========================================================================
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
        // Detect Mania
        int ammo[] = {4, 6, 7, 9};
        int totalColumns = 4;
        if (isPsych) {
            const auto& song = doc["song"];
            if (song.HasMember("mania") && song["mania"].IsInt()) {
                totalColumns = song["mania"].GetInt();
            }
        } else if (isVSlice) {
            if (doc.HasMember("mania") && doc["mania"].IsInt()) {
                totalColumns = doc["mania"].GetInt();
            }
        }
        if (totalColumns < 4) {
            totalColumns = ammo[0];
        }
        // Generate the header using your existing EOF-proof logic
        writeHeaderFile(songDir, doc, totalColumns);
        // Generate eventList.json if it doesn't already exist
        generateEventJson(songDir, doc);
        std::cout << "  [ Transpiler ] Generated missing header.txt from " << jsonPath << std::endl;
    }
    bool ends_with(const std::string& str, const std::string& suffix) {
        if (suffix.size() > str.size()) return false;
        // Compare str's substring (starting at the end minus suffix length) with suffix
        return str.compare(str.size() - suffix.size(), suffix.size(), suffix) == 0;
    }
#endif // CHART_FILE_NO_TRANSPILER
public:
    bool open(const char* path) {
        std::string pathStr(path);
        size_t lastSlash = pathStr.find_last_of("/\\");
        std::string songDir = (lastSlash == std::string::npos) ? "." : pathStr.substr(0, lastSlash);
#ifdef CHART_FILE_NO_TRANSPILER
        // Runtime-only build: accept .fvc snapshots only. Transpiling a
        // .json is the tooling build's job.
        if (!ends_with_fvc(pathStr)) {
            std::cerr << "  [ Chart File ] Non-.fvc input '" << pathStr
                << "' needs the transpiler (built with CHART_FILE_NO_TRANSPILER)." << std::endl;
            return false;
        }
        filename = pathStr;
#else
        // Check for header.txt once at the top level
        std::string headerPath = songDir + "/header.txt";
        std::ifstream headerTest(headerPath);
        bool headerExists = headerTest.good();
        headerTest.close();
        if (ends_with(pathStr, ".fvc")) {
            filename = pathStr;
            if (!headerExists) {
                // Derive the JSON path by replacing .fvc with .json
                std::string jsonPath = pathStr.substr(0, pathStr.length() - 4) + ".json";
                std::ifstream jsonTest(jsonPath);
                bool jsonExists = jsonTest.good();
                jsonTest.close();
                if (jsonExists) {
                    // Pass the DERIVED json path, not the .fvc path!
                    generateHeaderOnly(jsonPath.c_str(), songDir);
                } else {
                    std::cerr << "[Transpiler] Cannot generate header.txt: " << jsonPath << " not found." << std::endl;
                }
            }
        } else {
            // Input is a .json file
            std::string fvcPath = pathStr.substr(0, pathStr.length() - 5) + ".fvc";
            std::ifstream fvcTest(fvcPath);
            bool fvcExists = fvcTest.good();
            fvcTest.close();
            if (fvcExists) {
                // An existing .fvc is only trusted when it is a CURRENT
                // format (FVC4 segmented, or legacy monolithic FVC3). A
                // legacy 10-byte snapshot (or a stale file from an older
                // run) is re-transpiled from the .json — the .json is the
                // source of truth for the notes.
                bool fvcIsCurrent = false;
                {
                    std::ifstream fvcHead(fvcPath, std::ios::binary);
                    char magic[4] = {0, 0, 0, 0};
                    if (fvcHead.read(magic, 4) && fvcHead.gcount() == 4)
                        fvcIsCurrent = (std::memcmp(magic, "FVC4", 4) == 0
                                     || std::memcmp(magic, "FVC3", 4) == 0);
                    fvcHead.close();
                }
                if (fvcIsCurrent) {
                    filename = fvcPath;
                } else {
                    std::cout << "  [ Transpiler ] Existing .fvc is not FVC4/FVC3 — re-transpiling "
                        << pathStr << std::endl;
                    transpileJsonToFvc(pathStr.c_str());
                }
                if (!headerExists) {
                    // We already have the JSON path (pathStr), so pass it directly!
                    generateHeaderOnly(pathStr.c_str(), songDir);
                }
            } else {
                // .fvc does not exist. Full transpilation needed.
                transpileJsonToFvc(pathStr.c_str());
            }
        }
#endif
        // Load the .fvc snapshot into the sharded store.
        if (!loadFromFvc(filename.c_str())) {
            return false;
        }
        loadedFromDisk = true;
        std::cout << "  [ Chart File ] Loaded " << store.size() << " notes ("
            << store.shardCount() << " shards) from " << filename << std::endl;
        return true;
    }
public:
    ChartFileReader() = default;
    ~ChartFileReader() {
        // Preserve the old mmap semantics: structural edits made through
        // the API are persisted back to the bound .fvc on destruction.
        if (dirty && loadedFromDisk && !filename.empty()) {
            save();
        }
    }
    void setEditorMode(bool enabled) { editorMode = enabled; }
    void setApplyingNotes(bool enabled) { applyingNotes = enabled; }
    // TEST-ONLY: direct store access for chart_shard_test.cpp.
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
    // ========================================================================
    // ADD — flexible 5-argument form: addNote(position, duration, index,
    //                                        type, lane).
    //   position: 100ns ticks (the unit MetaNote.position uses)
    //   duration: 1ms ticks (24-bit field, max 16,777,215 ms ≈ 4.66 h)
    //   index:    column index within the strumline (0..1023, 10-bit field)
    //   type:     notetype (0..255 — a pure skin/behavior id; it does NOT
    //             decide where the note draws)
    //   lane:     strumline id the note belongs to (0..63, 6-bit field) —
    //             STORED on the note; every read site uses it directly
    //             instead of re-deriving the strumline from the type
    // The position locates the note's 1/4-second shard and its sorted slot
    // inside it; later shards' baseIds shift by one. Returns the new note's
    // global chart index — feed that same value to removeNote() to take it
    // back out.
    // ========================================================================
    int64_t addNote(uint64_t position, uint32_t duration, uint32_t index, uint32_t type, uint32_t lane) {
        const ChartNote cn = packNote(position, duration, index, type, lane);
        std::lock_guard<std::mutex> lk(dataMutex);
        const int64_t id = store.add(cn);
        dirty = true;
        return id;
    }
    // Legacy alias kept so the existing chart_test build compiles; the
    // lane is derived from the type through the default routing (type 0 →
    // strumline 0, else 1).
    void insertNote(uint64_t pos, uint16_t dur, uint8_t idx, uint8_t type) {
        addNote(pos, dur, idx, type, type == 0 ? 0 : 1);
    }
    // ========================================================================
    // REMOVE — takes a global chart index (the `id` addNote returned, the
    // same id the gameplay code already tracks as globalIndex/_id).
    // ========================================================================
    void removeNote(int64_t id) {
        if (id < 0 || id >= store.size()) return;
        std::lock_guard<std::mutex> lk(dataMutex);
        store.remove(id);
        dirty = true;
    }
    // ========================================================================
    // GLOBAL FLAG SYSTEM API
    // ========================================================================
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
    // ========================================================================
    // SAVE — write the (always sorted) store back out as a .fvc snapshot.
    // ========================================================================
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
        (void)initialCapacity; // capacity is a RAM concern now; shards grow on demand
        std::lock_guard<std::mutex> lk(dataMutex);
        store.clear();
        filename = path;
        dirty = false;
        loadedFromDisk = true;
        // Keep an (empty) file on disk so the path exists for later saves.
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        std::cout << "  [ Chart File ] Created new chart: " << path << std::endl;
    }
};

// ============================================================================
// Global API
// ============================================================================
static ChartFileReader* gReader = nullptr;
void core_loadChart(const char* path) {
    if (gReader) { delete gReader; gReader = nullptr; }
    gReader = new ChartFileReader();
    gReader->open(path); // Automatically handles .json -> .fvc transpilation!
}
void core_createChart(const char* path) {
    if (gReader) { delete gReader; gReader = nullptr; }
    gReader = new ChartFileReader();
    gReader->createNew(path);
}
void core_destroyChart() {
    if (gReader) { delete gReader; gReader = nullptr; }
}
// Explicit snapshot save; the destructor also saves if edits are pending.
bool core_saveChart() { if (!gReader) return false; return gReader->save(); }
void core_setEditorMode(bool enabled) { if (gReader) gReader->setEditorMode(enabled); }
void core_setApplyingNotes(bool enabled) { if (gReader) gReader->setApplyingNotes(enabled); }
int64_t core_getNote_first8(int64_t index) { if (!gReader) return 0; return (int64_t)gReader->getNote_first8(index); }
int core_getNote_last4(int64_t index) { if (!gReader) return 0; return (int)gReader->getNote_last4(index); }
// Primary API: addNote(position, duration, index, type, lane). Position is
// in 100ns ticks, duration in 1ms ticks, lane is the strumline id stored on
// the note. Returns the new note's global chart index, which removeNote()
// accepts.
int64_t core_addNote(int64_t position, int duration, int index, int type, int lane) {
    if (!gReader) return -1;
    return gReader->addNote(static_cast<uint64_t>(position), static_cast<uint32_t>(duration),
        static_cast<uint32_t>(index), static_cast<uint32_t>(type),
        static_cast<uint32_t>(lane));
}
// Legacy alias kept for the existing callers (Main.hx chart_test); the lane
// is derived from the type through the default routing.
void core_insertNote(int64_t globalPosition, int duration, int index, int type) {
    if (!gReader) return;
    gReader->insertNote(static_cast<uint64_t>(globalPosition), static_cast<uint16_t>(duration),
        static_cast<uint8_t>(index), static_cast<uint8_t>(type));
}
void core_removeNote(int64_t globalIndex) { if (!gReader) return; gReader->removeNote(globalIndex); }
int64_t core_getLength() { if (!gReader) return 0; return gReader->getLength(); }
// ============================================================================
// GLOBAL FLAG SYSTEM API
// ============================================================================
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
// ============================================================================
// TEST-ONLY accessors into the live store (chart_shard_test.cpp). The game
// never calls these; they expose the compressed-shard state so the test can
// assert on blobs, counts and the open-shard budget.
// ============================================================================
ShardedNoteStore* core_testStore() { return gReader ? gReader->testStore() : nullptr; }
void core_setHitFlag(int64_t globalIndex, bool value) {
    if (!gReader) return;
    gReader->setHitFlag(globalIndex, value);
}