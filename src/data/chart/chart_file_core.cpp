#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <cstdint>
#include <cstring>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <emmintrin.h> // SSE2 Intrinsics

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

// RapidJSON
#include "./include/rapidjson/document.h"
#include "./include/rapidjson/istreamwrapper.h"
#include "./include/rapidjson/ostreamwrapper.h"
#include "./include/rapidjson/prettywriter.h"
#include "./include/rapidjson/error/en.h"

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
// 10-Byte Packed Note Struct
// ============================================================================
#pragma pack(push, 1)
struct ChartNote {
    uint64_t first8; // [0..47] Position (50ns), [48..63] Duration (1ms)
    uint16_t last2;  // [0..7] Index, [8..15] Type
};
#pragma pack(pop)

static_assert(sizeof(ChartNote) == 10, "ChartNote must be exactly 10 bytes!");

// Helper function to sort an array of ChartNote in-place
static void radix_sort_notes_inplace(ChartNote* notes, size_t n) {
    if (n <= 1) return;
    std::vector<ChartNote> buffer(n);
    ChartNote* src = notes;
    ChartNote* dst = buffer.data();

    // Find max position
    uint64_t maxVal = 0;
    for (size_t i = 0; i < n; ++i) {
        uint64_t pos = src[i].first8 & 0x0000FFFFFFFFFFFFULL;
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
            uint64_t val = src[i].first8 & 0x0000FFFFFFFFFFFFULL;
            counts[(val >> shift) & 0xFF]++;
        }
        for (int j = 1; j < 256; ++j) counts[j] += counts[j-1];
        for (int64_t j = (int64_t)n - 1; j >= 0; --j) {
            uint64_t val = src[j].first8 & 0x0000FFFFFFFFFFFFULL;
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
// Single-File Chart Reader (.fvc format)
// ============================================================================
class ChartFileReader {
private:
    std::string filename;
    uint8_t* mappedData = nullptr;
    int64_t diskCapacity = 0; 
    int64_t diskCount = 0;    
    int64_t totalNotes = 0;   

    static constexpr size_t NOTE_SIZE = sizeof(ChartNote); // Exactly 10
    static constexpr size_t BUFFER_ELEMENTS = 104857; // 1mb
    mutable uint8_t buffer[BUFFER_ELEMENTS * NOTE_SIZE];
    mutable int64_t bufferBase = -1;
    mutable bool bufferDirty = false;

    std::vector<uint64_t> overflowFirst8;
    std::vector<uint16_t> overflowLast2;

    // ========================================================================
    // GLOBAL 1-BIT FLAG SYSTEMS (Stored in RAM only)
    // ========================================================================
    BitArray judgeFlags;
    BitArray hitFlags;

    std::mutex dataMutex;
    std::thread maintenanceThread;
    std::mutex maintenanceMutex;
    std::condition_variable maintenanceCV;
    bool stopMaintenance = false;

    bool editorMode = false;
    bool isApplyingNotes = false;
    bool pendingSortAfterApply = false;
    std::chrono::steady_clock::time_point lastInsertTime;
    std::chrono::steady_clock::time_point applyEndTime;

#ifdef _WIN32
    HANDLE hFile = INVALID_HANDLE_VALUE;
    HANDLE hMap = NULL;
#else
    int fd = -1;
    size_t mapLen = 0;
#endif

    void flushBufferToDisk() const {
        if (bufferDirty && bufferBase >= 0 && mappedData) {
            int64_t count = std::min<int64_t>(BUFFER_ELEMENTS, diskCapacity - bufferBase);
            std::memcpy(mappedData + (bufferBase * NOTE_SIZE), buffer, count * NOTE_SIZE);
            bufferDirty = false;
        }
    }

    void loadBufferFromDisk(int64_t baseIndex) const {
        flushBufferToDisk();
        bufferBase = baseIndex;
        int64_t count = std::min<int64_t>(BUFFER_ELEMENTS, diskCapacity - baseIndex);
        std::memcpy(buffer, mappedData + (baseIndex * NOTE_SIZE), count * NOTE_SIZE);
    }

    void closeMapInternal() {
        flushBufferToDisk();
#ifdef _WIN32
        if (mappedData) { UnmapViewOfFile(mappedData); }
        if (hMap != NULL) { CloseHandle(hMap); hMap = NULL; }
        if (hFile != INVALID_HANDLE_VALUE) { CloseHandle(hFile); hFile = INVALID_HANDLE_VALUE; }
#else
        if (mappedData) { munmap(mappedData, mapLen); }
        if (fd >= 0) { ::close(fd); fd = -1; }
        mapLen = 0;
#endif
        mappedData = nullptr;
        diskCapacity = 0;
        bufferBase = -1;
        bufferDirty = false;
    }

    void remapFile(int64_t newCapacity) {
        int64_t oldTotalNotes = totalNotes;
        int64_t oldDiskCount = diskCount;
        
        closeMapInternal();
        std::string path = filename;
        int64_t newFileSize = newCapacity * NOTE_SIZE;

#ifdef _WIN32
        hFile = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return;
        LARGE_INTEGER li; li.QuadPart = newFileSize;
        SetFilePointerEx(hFile, li, nullptr, FILE_BEGIN);
        if (!SetEndOfFile(hFile)) { CloseHandle(hFile); return; }
        CloseHandle(hFile);
#else
        if (truncate(path.c_str(), newFileSize) != 0) return;
#endif
        openInternal(path.c_str(), true);
        
        // Restore counts so we don't lose track of overflow notes!
        totalNotes = oldTotalNotes;
        diskCount = oldDiskCount;
    }

    bool openInternal(const char* path, bool isRemap = false) {
#ifdef _WIN32
        hFile = CreateFileA(path, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return false;
        LARGE_INTEGER sz;
        if (!GetFileSizeEx(hFile, &sz)) { closeMapInternal(); return false; }
        hMap = CreateFileMappingA(hFile, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        if (!hMap) { closeMapInternal(); return false; }
        void* ptr = MapViewOfFile(hMap, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
        if (!ptr) { closeMapInternal(); return false; }
        mappedData = (uint8_t*)ptr;
        diskCapacity = sz.QuadPart / NOTE_SIZE;
#else
        fd = ::open(path, O_RDWR);
        if (fd < 0) return false;
        struct stat st;
        if (fstat(fd, &st) != 0) { closeMapInternal(); return false; }
        mapLen = static_cast<size_t>(st.st_size);
        
        #ifdef __linux__
        void* ptr = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, 0);
        #else
        void* ptr = mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        #endif
        if (ptr == MAP_FAILED) { closeMapInternal(); return false; }
        mappedData = (uint8_t*)ptr;
        diskCapacity = st.st_size / NOTE_SIZE;
#endif
        
        if (!isRemap) {
            diskCount = diskCapacity; 
            totalNotes = diskCount;
            judgeFlags.init(totalNotes);
            hitFlags.init(totalNotes);
        }
        return true;
    }

    void setFirst8(int64_t index, uint64_t value) {
        if (index < 0 || index >= diskCapacity) return;
        int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base != bufferBase) loadBufferFromDisk(base);
        std::memcpy(buffer + (index - base) * NOTE_SIZE, &value, 8);
        bufferDirty = true;
    }

    void setLast2(int64_t index, uint16_t value) {
        if (index < 0 || index >= diskCapacity) return;
        int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
        if (base != bufferBase) loadBufferFromDisk(base);
        std::memcpy(buffer + (index - base) * NOTE_SIZE + 8, &value, 2);
        bufferDirty = true;
    }

    void flushOverflowToDisk() {
        if (overflowFirst8.empty()) return;
        int64_t neededCap = diskCount + overflowFirst8.size();
        if (neededCap > diskCapacity) {
            int64_t newCap = std::max<int64_t>(neededCap, diskCapacity * 2);
            remapFile(newCap);
        }
        for (size_t i = 0; i < overflowFirst8.size(); ++i) {
            setFirst8(diskCount + i, overflowFirst8[i]);
            setLast2(diskCount + i, overflowLast2[i]);
        }
        diskCount += overflowFirst8.size();
        overflowFirst8.clear();
        overflowLast2.clear();
    }

    void radixSortInPlace() {
        if (totalNotes <= 1) return;
        
        // ... this needs done soon just in case the chart editor is finally being developed
    }

    void startMaintenance() {
        maintenanceThread = std::thread([this] {
            while (true) {
                {
                    std::unique_lock<std::mutex> lk(maintenanceMutex);
                    if (maintenanceCV.wait_for(lk, std::chrono::milliseconds(10), [this] { return stopMaintenance; })) break;
                }
                
                //hmmmm.....
            }
        });
    }

    void stopMaintenanceThread() {
        {
            std::lock_guard<std::mutex> lk(maintenanceMutex);
            stopMaintenance = true;
        }
        maintenanceCV.notify_one();
        if (maintenanceThread.joinable()) maintenanceThread.join();
    }

    // ========================================================================
    // Integrated JSON Transpiler
    // ========================================================================
    static void addNote(std::vector<ChartNote>& notes, double time_ms, int lane, double sustain_ms, int type) {
        if (lane < 0) return; 
        
        uint64_t pos = (uint64_t)(time_ms * 100000.0); // 10ns ticks
        uint16_t dur = (uint16_t)(sustain_ms);         // 1ms ticks
        
        ChartNote n;
        n.first8 = (pos & 0xFFFFFFFFFFFFULL) | ((uint64_t)(dur & 0xFFFF) << 48);
        n.last2 = (uint16_t)(lane & 0xFF) | ((uint16_t)(type & 0xFF) << 8);
        notes.push_back(n);
    }

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
    // ========================================================================
    inline bool writeNote(ChartNote& outNote, double time_ms, int lane, double sustain_ms, bool mustHitSection, bool isPsychV1, bool isVSlice, int totalColumns) {
        if (lane < 0) return false;
        
        int type;
        if (isVSlice) {
            type = (lane >= totalColumns) ? 1 : 0;
        } else if (isPsychV1) {
            type = (lane < totalColumns) ? 1 : 0;
        } else {
            bool gottaHitNote = (lane < totalColumns) ? mustHitSection : !mustHitSection;
            type = gottaHitNote ? 1 : 0;
        }
        
        int index = lane % totalColumns; 
        
        uint64_t pos = (uint64_t)(time_ms * 100000.0);   // 10ns ticks
        uint16_t dur = (uint16_t)(sustain_ms);           // Solid 1ms duration
        
        outNote.first8 = (pos & 0xFFFFFFFFFFFFULL) | ((uint64_t)(dur & 0xFFFF) << 48);
        outNote.last2 = (uint16_t)(index & 0xFF) | ((uint16_t)(type & 0xFF) << 8);
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

        // --- CREATE AND INITIALIZE THE .fvc FILE ---
        std::string fvcPath = std::string(jsonPath);
        size_t dot = fvcPath.find_last_of('.');
        if (dot != std::string::npos) fvcPath = fvcPath.substr(0, dot);
        fvcPath += ".fvc";

        std::ofstream out(fvcPath, std::ios::binary | std::ios::trunc);
        if (!out) {
            std::cerr << "  [ Transpiler ] Failed to create .fvc file." << std::endl;
            return;
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

        size_t totalNoteCount = writeIndex;

        // --- MAP MEMORY FOR IN-PLACE SORTING ---
#ifdef _WIN32
        HANDLE hFile = CreateFileA(fvcPath.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (hFile == INVALID_HANDLE_VALUE) return;
        HANDLE hMap = CreateFileMappingA(hFile, nullptr, PAGE_READWRITE, 0, 0, nullptr);
        if (!hMap) { CloseHandle(hFile); return; }
        ChartNote* mappedNotes = (ChartNote*)MapViewOfFile(hMap, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
        if (!mappedNotes) { CloseHandle(hMap); CloseHandle(hFile); return; }
#else
        int fd = ::open(fvcPath.c_str(), O_RDWR);
        if (fd < 0) return;
        size_t mapLen = totalNoteCount * sizeof(ChartNote);
        ChartNote* mappedNotes = (ChartNote*)mmap(nullptr, mapLen, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (mappedNotes == MAP_FAILED) { ::close(fd); return; }
#endif

        // --- SORT THE NOTES IN-PLACE ---
        std::cout << "  [ Transpiler ] Sorting " << totalNoteCount << " notes via LSD Radix Sort..." << std::endl;
        radix_sort_notes_inplace(mappedNotes, totalNoteCount);

        // --- CLEANUP ---
#ifdef _WIN32
        UnmapViewOfFile(mappedNotes);
        CloseHandle(hMap);
        CloseHandle(hFile);
#else
        munmap(mappedNotes, mapLen);
        ::close(fd);
#endif

        std::cout << "  [ Transpiler ] Successfully transpiled, sorted, and generated header for " << fvcPath << std::endl;
        filename = fvcPath;
    }

public:
    ChartFileReader() = default;
    
    ~ChartFileReader() {
        stopMaintenanceThread();
        std::lock_guard<std::mutex> lk(dataMutex);
        closeMapInternal();
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

    bool open(const char* path) {
        std::string pathStr(path);

        size_t lastSlash = pathStr.find_last_of("/\\");
        std::string songDir = (lastSlash == std::string::npos) ? "." : pathStr.substr(0, lastSlash);
        
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
                filename = fvcPath;
                
                if (!headerExists) {
                    // We already have the JSON path (pathStr), so pass it directly!
                    generateHeaderOnly(pathStr.c_str(), songDir);
                }
            } else {
                // .fvc does not exist. Full transpilation needed.
                transpileJsonToFvc(pathStr.c_str());
                path = filename.c_str();
            }
        }

        if (!openInternal(path)) return false;
        startMaintenance();
        return true;
    }

    void createNew(const char* path, int64_t initialCapacity = 4096) {
        filename = path;
        std::ofstream file(path, std::ios::binary | std::ios::trunc);
        if (!file) return;
        std::vector<uint8_t> zeros(initialCapacity * NOTE_SIZE, 0);
        file.write(reinterpret_cast<const char*>(zeros.data()), zeros.size());
        file.close();
        openInternal(path);
        startMaintenance();
    }

    void setEditorMode(bool enabled) { editorMode = enabled; }
    void setApplyingNotes(bool enabled) {
        isApplyingNotes = enabled;
        if (!enabled) {
            pendingSortAfterApply = true;
            applyEndTime = std::chrono::steady_clock::now();
        }
    }

    uint64_t getNote_first8(int64_t index) {
        if (index < 0 || index >= totalNotes) return 0;
        std::lock_guard<std::mutex> lk(dataMutex);
        if (index < diskCount) {
            int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
            if (base != bufferBase) loadBufferFromDisk(base);
            uint64_t val;
            std::memcpy(&val, buffer + (index - base) * NOTE_SIZE, 8);
            return val;
        } else {
            return overflowFirst8[index - diskCount];
        }
    }

    uint16_t getNote_last2(int64_t index) {
        if (index < 0 || index >= totalNotes) return 0;
        std::lock_guard<std::mutex> lk(dataMutex);
        if (index < diskCount) {
            int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
            if (base != bufferBase) loadBufferFromDisk(base);
            uint16_t val;
            std::memcpy(&val, buffer + (index - base) * NOTE_SIZE + 8, 2);
            return val;
        } else {
            return overflowLast2[index - diskCount];
        }
    }

    // ========================================================================
    // GLOBAL FLAG SYSTEM API
    // ========================================================================
    bool getJudgement(int64_t index) {
        if (index < 0 || index >= totalNotes) return false;
        return judgeFlags.get((size_t)index);
    }

    void setJudgement(int64_t index, bool value) {
        if (index < 0 || index >= totalNotes) return;
        judgeFlags.set((size_t)index, value);
    }

    bool getHitFlag(int64_t index) {
        if (index < 0 || index >= totalNotes) return false;
        return hitFlags.get((size_t)index);
    }

    void setHitFlag(int64_t index, bool value) {
        if (index < 0 || index >= totalNotes) return;
        hitFlags.set((size_t)index, value);
    }

    void insertNote(uint64_t pos, uint16_t dur, uint8_t idx, uint8_t type) {
        uint64_t first8 = (pos & 0xFFFFFFFFFFFFULL) | ((uint64_t)(dur & 0xFFFF) << 48);
        uint16_t last2 = (uint16_t)(idx & 0xFF) | ((uint16_t)(type & 0xFF) << 8);
        
        std::lock_guard<std::mutex> lk(dataMutex);

        // Insert false into both global flag arrays at the new index
        judgeFlags.insert((size_t)totalNotes, false);
        hitFlags.insert((size_t)totalNotes, false);

        if (editorMode || isApplyingNotes) {
            overflowFirst8.push_back(first8);
            overflowLast2.push_back(last2);
        } else {
            if (totalNotes >= diskCapacity) {
                int64_t newCap = std::max<int64_t>(totalNotes * 2, diskCapacity + 4096);
                remapFile(newCap);
            }
            setFirst8(totalNotes, first8);
            setLast2(totalNotes, last2);
            diskCount++;
        }
        
        totalNotes++;
        lastInsertTime = std::chrono::steady_clock::now();
    }

    void removeNote(int64_t index) {
        if (index < 0 || index >= totalNotes) return;
        std::lock_guard<std::mutex> lk(dataMutex);

        if (!overflowFirst8.empty()) {
            flushOverflowToDisk();
        }

        int64_t remaining = diskCount - index - 1;
        if (remaining > 0) {
            int64_t base = (index / BUFFER_ELEMENTS) * BUFFER_ELEMENTS;
            if (base == bufferBase && (index + remaining) < (bufferBase + BUFFER_ELEMENTS)) {
                std::memmove(buffer + (index - base) * NOTE_SIZE, buffer + (index + 1 - base) * NOTE_SIZE, remaining * NOTE_SIZE);
                bufferDirty = true;
            } else {
                flushBufferToDisk();
                bufferBase = -1;
                std::memmove(mappedData + (index * NOTE_SIZE), mappedData + ((index + 1) * NOTE_SIZE), remaining * NOTE_SIZE);
            }
        }
        
        // Erase the flags from the global arrays (shifts subsequent bits automatically)
        judgeFlags.erase((size_t)index);
        hitFlags.erase((size_t)index);

        diskCount--;
        totalNotes--;
        lastInsertTime = std::chrono::steady_clock::now();
    }

    int64_t getLength() const { return totalNotes; }
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

void core_setEditorMode(bool enabled) { if (gReader) gReader->setEditorMode(enabled); }
void core_setApplyingNotes(bool enabled) { if (gReader) gReader->setApplyingNotes(enabled); }

int64_t core_getNote_first8(int64_t index) { if (!gReader) return 0; return gReader->getNote_first8(index); }
int core_getNote_last2(int64_t index) { if (!gReader) return 0; return gReader->getNote_last2(index); }

void core_insertNote(int64_t globalPosition, int duration, int index, int type) {
    if (!gReader) return;
    gReader->insertNote(static_cast<uint64_t>(globalPosition), static_cast<uint16_t>(duration), static_cast<uint8_t>(index), static_cast<uint8_t>(type));
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