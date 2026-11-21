#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <algorithm>

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

        // Shift bits right to make room
        for (int64_t j = (int64_t)count - 1; j >= (int64_t)i; --j) {
            set(j + 1, get(j));
        }
        set(i, val);
        count = newCount;
    }
    void erase(size_t i) {
        if (i >= count) return;
        // Shift bits left to fill the gap
        for (size_t j = i; j < count - 1; ++j) {
            set(j, get(j + 1));
        }
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
    std::vector<ChartNote> buffer(n);
    ChartNote* src = notes;
    ChartNote* dst = buffer.data();

    // Find max position
    uint64_t maxVal = 0;
    for (size_t i = 0; i < n; ++i) {
        uint64_t pos = notePos(src[i]);
        if (pos > maxVal) maxVal = pos;
    }
    if (maxVal == 0) return;

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
// describe. Each shard owns a small sorted run of notes plus its own
// judge/hit flag bits, and a directory of shards is kept ordered by time
// with a running `baseId` prefix so global note indices stay stable:
//
//   READ   id -> shard (binary search, or the last-shard cache during
//          sequential sweeps) -> O(1) slot. The spawner's bottom..top walk
//          and NoteSystem's lower_bound binary searches work unchanged.
//   ADD    position is extracted from the packed note -> shard found by
//          arithmetic + binary search -> one small sorted insert inside
//          that shard's run (memmove of a few dozen bytes, not the chart).
//   REMOVE id -> shard -> one small erase inside the run, then O(shardCount)
//          integer fixups of the prefix table. Cost is independent of the
//          chart's total size.
//
// The .fvc file on disk becomes a pure snapshot: load is one sequential
// pass, save is one sequential pass, and structural edits never touch the
// disk until saveChart()/destroy (which mirrors the old mmap semantics).
// ============================================================================
class ShardedNoteStore {
public:
    static constexpr uint64_t POS_MASK = 0x0000FFFFFFFFFFFFULL;
    // 250 ms * 100,000 ticks/ms = 25,000,000 ticks per shard (1/4 second)
    static constexpr uint64_t SHARD_TICKS = 25000000ULL;

private:
    struct Shard {
        uint64_t startTick;            // shard id * SHARD_TICKS
        int64_t baseId;                // global index of notes[0] (prefix sum)
        std::vector<ChartNote> notes;  // sorted by position
        BitArray judge;
        BitArray hit;
    };

    std::vector<Shard> shards;  // ordered by startTick; no empty shards kept
    int64_t totalNotes = 0;
    mutable size_t lastShard = 0;  // sequential-read cache

    // Index of the shard covering `pos`, or shards.size() if none does.
    size_t findShardByPos(uint64_t pos) const {
        size_t lo = 0, hi = shards.size();
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (shards[mid].startTick <= pos) lo = mid + 1;
            else hi = mid;
        }
        if (lo == 0) return shards.size();
        size_t idx = lo - 1;
        return (pos - shards[idx].startTick) < SHARD_TICKS ? idx : shards.size();
    }

    // Insertion index (in the shard directory) for a brand-new shard.
    size_t shardInsertAt(uint64_t startTick) const {
        size_t lo = 0, hi = shards.size();
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (shards[mid].startTick < startTick) lo = mid + 1;
            else hi = mid;
        }
        return lo;
    }

    // Index of the shard owning global id `id`.
    // Caller guarantees 0 <= id < totalNotes.
    size_t shardById(int64_t id) const {
        if (lastShard < shards.size()) {
            const Shard& c = shards[lastShard];
            if (id >= c.baseId && id < c.baseId + (int64_t)c.notes.size())
                return lastShard;
        }
        size_t lo = 0, hi = shards.size();
        while (lo < hi) {
            size_t mid = lo + (hi - lo) / 2;
            if (shards[mid].baseId <= id) lo = mid + 1;
            else hi = mid;
        }
        lastShard = lo - 1;
        return lastShard;
    }

public:
    ShardedNoteStore() = default;
    ~ShardedNoteStore() = default;
    ShardedNoteStore(const ShardedNoteStore&) = delete;
    ShardedNoteStore& operator=(const ShardedNoteStore&) = delete;

    int64_t size() const { return totalNotes; }
    bool empty() const { return totalNotes == 0; }
    size_t shardCount() const { return shards.size(); }

    void clear() {
        shards.clear();
        shards.shrink_to_fit();
        totalNotes = 0;
        lastShard = 0;
    }

    // ---- READ ----
    uint64_t getFirst8(int64_t id) const {
        const Shard& sh = shards[shardById(id)];
        return sh.notes[(size_t)(id - sh.baseId)].first8;
    }

    uint32_t getLast4(int64_t id) const {
        const Shard& sh = shards[shardById(id)];
        return sh.notes[(size_t)(id - sh.baseId)].last4;
    }

    bool getJudge(int64_t id) const {
        const Shard& sh = shards[shardById(id)];
        return sh.judge.get((size_t)(id - sh.baseId));
    }

    void setJudge(int64_t id, bool value) {
        Shard& sh = shards[shardById(id)];
        sh.judge.set((size_t)(id - sh.baseId), value);
    }

    bool getHit(int64_t id) const {
        const Shard& sh = shards[shardById(id)];
        return sh.hit.get((size_t)(id - sh.baseId));
    }

    void setHit(int64_t id, bool value) {
        Shard& sh = shards[shardById(id)];
        sh.hit.set((size_t)(id - sh.baseId), value);
    }

    // ---- ADD ----
    // `cn` is a fully packed note; the position is extracted from it HERE —
    // callers never pass a separate position — to locate the 1/4-second
    // shard and the sorted slot inside its run. Returns the new note's
    // global chart index.
    int64_t add(const ChartNote& cn) {
        const uint64_t pos = notePos(cn);

        size_t si = findShardByPos(pos);
        if (si == shards.size()) {
            // Materialize the shard, keeping the directory time-ordered.
            Shard sh;
            sh.startTick = pos - (pos % SHARD_TICKS);
            size_t at = shardInsertAt(sh.startTick);
            sh.baseId = (at == 0)
                ? 0
                : shards[at - 1].baseId + (int64_t)shards[at - 1].notes.size();
            si = at;
            shards.insert(shards.begin() + at, std::move(sh));
        }

        Shard& sh = shards[si];
        size_t local = (size_t)(std::lower_bound(
            sh.notes.begin(), sh.notes.end(), pos,
            [](const ChartNote& n, uint64_t p) { return notePos(n) < p; }
        ) - sh.notes.begin());

        sh.notes.insert(sh.notes.begin() + local, cn);
        sh.judge.insert(local, false);
        sh.hit.insert(local, false);

        ++totalNotes;
        for (size_t k = si + 1; k < shards.size(); ++k) ++shards[k].baseId;

        lastShard = si;
        return sh.baseId + (int64_t)local;
    }

    // ---- REMOVE ----
    // Removes the note with global chart index `id`. Only the owning
    // shard's run and flag bits shift; later shards get a prefix fixup.
    void remove(int64_t id) {
        size_t si = shardById(id);
        Shard& sh = shards[si];
        size_t local = (size_t)(id - sh.baseId);

        sh.notes.erase(sh.notes.begin() + local);
        sh.judge.erase(local);
        sh.hit.erase(local);
        --totalNotes;

        const bool gone = sh.notes.empty();
        if (gone) {
            shards.erase(shards.begin() + si);
        }
        // Every note after the removed one slides down by one id.
        for (size_t k = (gone ? si : si + 1); k < shards.size(); ++k) {
            --shards[k].baseId;
        }
        lastShard = 0; // cheap; the next lookup re-runs the tiny binary search
    }

    // ---- BULK LOAD ----
    // Distribute a position-sorted flat array into shards (single pass).
    void loadFromSortedFlat(const ChartNote* data, size_t n) {
        clear();
        for (size_t i = 0; i < n; ++i) {
            const uint64_t pos = notePos(data[i]);
            if (shards.empty() || pos >= shards.back().startTick + SHARD_TICKS) {
                Shard sh;
                sh.startTick = pos - (pos % SHARD_TICKS);
                sh.baseId = (int64_t)i;
                shards.push_back(std::move(sh));
            }
            shards.back().notes.push_back(data[i]);
        }
        for (Shard& sh : shards) {
            sh.judge.init(sh.notes.size());
            sh.hit.init(sh.notes.size());
        }
        totalNotes = (int64_t)n;
    }

    // ---- SAVE ----
    // Sequential write of the FVC2 header + every shard's run; the note
    // stream is globally sorted.
    bool writeTo(const char* path) const {
        std::ofstream out(path, std::ios::binary | std::ios::trunc);
        if (!out) return false;
        FvcFileHeader hdr;
        std::memcpy(hdr.magic, "FVC2", 4);
        hdr.noteCount = (uint32_t)totalNotes;
        hdr.noteSize = (uint32_t)sizeof(ChartNote);
        hdr.flags = 0;
        out.write(reinterpret_cast<const char*>(&hdr), sizeof(hdr));
        for (const Shard& sh : shards) {
            if (!sh.notes.empty()) {
                out.write(
                    reinterpret_cast<const char*>(sh.notes.data()),
                    (std::streamsize)sh.notes.size() * (std::streamsize)sizeof(ChartNote)
                );
            }
        }
        return out.good();
    }

    // ---- DEBUG / TESTS ----
    bool isSorted() const {
        uint64_t prev = 0;
        for (const Shard& sh : shards) {
            for (const ChartNote& n : sh.notes) {
                const uint64_t p = notePos(n);
                if (p < prev) return false;
                prev = p;
            }
        }
        return true;
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

    // Load a .fvc snapshot into the sharded store. Two on-disk formats:
    //   v2 ("FVC2" header): 16-byte header + 12-byte notes — the current
    //   format, with the lane (strumline) field stored per note.
    //   v1 (no magic): a bare run of 10-byte notes (pos48 | dur16 | idx8 |
    //   type8 — no lane). Loaded, then converted in RAM: the lane is
    //   derived from the type through the default routing (type 0 →
    //   strumline 0 opponent, everything else → 1 player). The conversion
    //   only lives in RAM + the next save; a save always writes v2.
    bool loadFromFvc(const char* path) {
        std::ifstream in(path, std::ios::binary | std::ios::ate);
        if (!in) {
            std::cerr << "  [ Chart File ] Failed to open " << path << std::endl;
            return false;
        }
        const std::streamsize fileSize = in.tellg();
        if (fileSize < 0) return false;
        in.seekg(0, std::ios::beg);

        std::vector<ChartNote> flat;
        bool legacy = true;

        if (fileSize >= (std::streamsize)sizeof(FvcFileHeader)) {
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
                const std::streamsize payload =
                    fileSize - (std::streamsize)sizeof(FvcFileHeader);
                if (payload % (std::streamsize)sizeof(ChartNote) != 0) {
                    std::cerr << "  [ Chart File ] Trailing bytes in " << path
                              << " (file size not a multiple of the 12-byte note)" << std::endl;
                    return false;
                }
                const size_t n = (size_t)(payload / (std::streamsize)sizeof(ChartNote));
                if ((uint64_t)n != hdr.noteCount) {
                    std::cerr << "  [ Chart File ] Header/count mismatch in " << path
                              << " (" << hdr.noteCount << " declared, " << n << " present)"
                              << std::endl;
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
                in.seekg(0, std::ios::beg); // not v2 — rewind for the legacy read
            }
        }

        if (legacy) {
            // v1: 10-byte records, no file header.
            const size_t n = (size_t)fileSize / 10;
            const size_t rem = (size_t)fileSize % 10;
            if (n == 0 && fileSize != 0) {
                std::cerr << "  [ Chart File ] Empty non-legacy file " << path << std::endl;
                return false;
            }
            (void)rem; // a hand-edited trailing fragment is ignored, as before
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
                    const uint64_t pos = (uint64_t)r[0]
                        | ((uint64_t)r[1] << 8) | ((uint64_t)r[2] << 16)
                        | ((uint64_t)r[3] << 24) | ((uint64_t)r[4] << 32)
                        | ((uint64_t)r[5] << 40);
                    const uint16_t dur16 = (uint16_t)(r[6] | (r[7] << 8));
                    const uint8_t idx = r[8];
                    const uint8_t type = r[9];
                    // Derive the lane from the DEFAULT routing the v1
                    // format implied (the gameplay code recomputed it from
                    // type at every read anyway).
                    const uint8_t lane = (type == 0) ? 0 : 1;
                    flat[i] = packNote(pos, dur16, idx, type, lane);
                }
                std::cout << "  [ Chart File ] Legacy 10-byte .fvc (" << n
                          << " notes) — converted to 12-byte in RAM; next save writes FVC2."
                          << std::endl;
            }
        }
        in.close();

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

        std::lock_guard<std::mutex> lk(dataMutex);
        store.loadFromSortedFlat(flat.data(), flat.size());
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

        // v2 snapshot: FVC2 header first; the count is patched in by a
        // seek-back after the single-pass note stream below (the writer
        // itself stays streaming — nothing is buffered).
        {
            FvcFileHeader hdr;
            std::memcpy(hdr.magic, "FVC2", 4);
            hdr.noteCount = 0; // patched after the stream
            hdr.noteSize = (uint32_t)sizeof(ChartNote);
            hdr.flags = 0;
            out.write(reinterpret_cast<const char*>(&hdr), sizeof(hdr));
        }

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
                                    out.write(reinterpret_cast<const char*>(&currentNote), sizeof(ChartNote));
                                    writeIndex++;
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
                                    out.write(reinterpret_cast<const char*>(&currentNote), sizeof(ChartNote));
                                    writeIndex++;
                                }
                            }
                        }
                    }
                }
            }
        }

        // Patch the header's note count (offset 4 in FvcFileHeader).
        out.seekp(4, std::ios::beg);
        const uint32_t noteCount = (uint32_t)writeIndex;
        out.write(reinterpret_cast<const char*>(&noteCount), sizeof(noteCount));
        out.close();

        if (writeIndex == 0) {
            std::cerr << "  [ Transpiler ] No valid notes found." << std::endl;
            std::remove(fvcPath.c_str()); // Clean up the empty file
            return;
        }

        std::cout << "  [ Transpiler ] Wrote " << writeIndex << " notes directly to disk in a single pass." << std::endl;
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
                // An existing .fvc is only trusted when it is the CURRENT
                // v2 format. A legacy 10-byte snapshot (or a stale file
                // from an older run) is re-transpiled from the .json —
                // the .json is the source of truth for the notes.
                bool fvcIsV2 = false;
                {
                    std::ifstream fvcHead(fvcPath, std::ios::binary);
                    char magic[4] = {0, 0, 0, 0};
                    if (fvcHead.read(magic, 4) && fvcHead.gcount() == 4)
                        fvcIsV2 = (std::memcmp(magic, "FVC2", 4) == 0);
                    fvcHead.close();
                }
                if (fvcIsV2) {
                    filename = fvcPath;
                } else {
                    std::cout << "  [ Transpiler ] Existing .fvc is not FVC2 — re-transpiling "
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

void core_setHitFlag(int64_t globalIndex, bool value) {
    if (!gReader) return;
    gReader->setHitFlag(globalIndex, value);
}

