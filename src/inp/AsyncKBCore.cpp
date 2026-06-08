// Platform detection
#ifdef _WIN32
    #include <windows.h>
    #pragma comment(lib, "user32.lib")
#elif defined(__linux__)
    #include <X11/Xlib.h>
    #include <X11/Xutil.h>
    #include <X11/keysym.h>
    #include <unistd.h>
    #include <linux/input.h>
    #include <fcntl.h>
    #include <sys/ioctl.h>
    #include <poll.h>
    #include <errno.h>
    #include <cstring>
#endif

#include <atomic>
#include <mutex>
#include <condition_variable>
#include <array>
#include <thread>
#include <chrono>
#include <iostream>
#include <iomanip>

struct InputEvent {
    int scanCode;
    int state;
    double timestamp;
};

class AsyncInputThread {
private:
    static constexpr size_t MAX_EVENTS = 512;
    
    std::atomic<bool> running;
    std::thread worker;
    std::array<InputEvent, MAX_EVENTS> eventBuffer;
    std::atomic<size_t> writeIndex{0};
    std::atomic<size_t> readIndex{0};
    std::atomic<size_t> eventCount{0};
    mutable std::mutex queueMutex;
    std::condition_variable queueCV;
    
    InputEvent currentEvent;
    bool hasCurrentEvent = false;
    
    std::chrono::steady_clock::time_point startTime;
    bool startTimeInitialized = false;
    
    void addEvent(const InputEvent& event) {
        std::lock_guard<std::mutex> lock(queueMutex);
        size_t currentWrite = writeIndex.load(std::memory_order_acquire);
        eventBuffer[currentWrite] = event;
        writeIndex.store((currentWrite + 1) % MAX_EVENTS, std::memory_order_release);
        
        size_t count = eventCount.load(std::memory_order_acquire);
        if (count < MAX_EVENTS) {
            eventCount.store(count + 1, std::memory_order_release);
        } else {
            size_t currentRead = readIndex.load(std::memory_order_acquire);
            readIndex.store((currentRead + 1) % MAX_EVENTS, std::memory_order_release);
        }
        queueCV.notify_one();
    }
    
    void loadNextEvent() {
        if (!hasCurrentEvent && eventCount.load(std::memory_order_acquire) > 0) {
            std::lock_guard<std::mutex> lock(queueMutex);
            if (eventCount.load(std::memory_order_acquire) > 0) {
                size_t currentRead = readIndex.load(std::memory_order_acquire);
                currentEvent = eventBuffer[currentRead];
                readIndex.store((currentRead + 1) % MAX_EVENTS, std::memory_order_release);
                eventCount.fetch_sub(1, std::memory_order_release);
                hasCurrentEvent = true;
            }
        }
    }
    
#ifdef _WIN32
    HHOOK keyboardHook;
    HANDLE quitEvent;
    DWORD my_pid;
    static AsyncInputThread* instance;
    
    int windowsToLimeKeyCode(int winKeyCode) {
        if (winKeyCode >= 'A' && winKeyCode <= 'Z') return 0x61 + (winKeyCode - 'A');
        if (winKeyCode >= '0' && winKeyCode <= '9') return winKeyCode;
        
        switch (winKeyCode) {
            case VK_BACK: return 0x08; case VK_TAB: return 0x09; case VK_RETURN: return 0x0D;
            case VK_ESCAPE: return 0x1B; case VK_SPACE: return 0x20; case VK_DELETE: return 0x7F;
            case VK_INSERT: return 0x40000049; case VK_HOME: return 0x4000004A; case VK_END: return 0x4000004D;
            case VK_PRIOR: return 0x4000004B; case VK_NEXT: return 0x4000004E; case VK_UP: return 0x40000052;
            case VK_DOWN: return 0x40000051; case VK_LEFT: return 0x40000050; case VK_RIGHT: return 0x4000004F;
            case VK_LCONTROL: return 0x400000E0; case VK_RCONTROL: return 0x400000E4; case VK_LSHIFT: return 0x400000E1;
            case VK_RSHIFT: return 0x400000E5; case VK_LMENU: return 0x400000E2; case VK_RMENU: return 0x400000E6;
            case VK_LWIN: return 0x400000E3; case VK_RWIN: return 0x400000E7; case VK_CAPITAL: return 0x40000039;
            case VK_NUMLOCK: return 0x40000053; case VK_SCROLL: return 0x40000047; case VK_F1: return 0x4000003A;
            case VK_F2: return 0x4000003B; case VK_F3: return 0x4000003C; case VK_F4: return 0x4000003D;
            case VK_F5: return 0x4000003E; case VK_F6: return 0x4000003F; case VK_F7: return 0x40000040;
            case VK_F8: return 0x40000041; case VK_F9: return 0x40000042; case VK_F10: return 0x40000043;
            case VK_F11: return 0x40000044; case VK_F12: return 0x40000045; case VK_OEM_MINUS: return 0x2D;
            case VK_OEM_PLUS: return 0x3D; case VK_OEM_4: return 0x5B; case VK_OEM_6: return 0x5D;
            case VK_OEM_5: return 0x5C; case VK_OEM_1: return 0x3B; case VK_OEM_7: return 0x27;
            case VK_OEM_3: return 0x60; case VK_OEM_COMMA: return 0x2C; case VK_OEM_PERIOD: return 0x2E;
            case VK_OEM_2: return 0x2F; default: return 0x00;
        }
    }
    
    static LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
        if (nCode >= 0 && instance) {
            HWND foreground = GetForegroundWindow();
            DWORD pid = 0;
            if (foreground) GetWindowThreadProcessId(foreground, &pid);
            bool isFocused = (pid == instance->my_pid);

            if (isFocused) {
                KBDLLHOOKSTRUCT* kb = (KBDLLHOOKSTRUCT*)lParam;
                
                if (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN || 
                    wParam == WM_KEYUP || wParam == WM_SYSKEYUP) {
                    InputEvent event;
                    event.scanCode = instance->windowsToLimeKeyCode(kb->vkCode);
                    event.state = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) ? 1 : 0;
                    event.timestamp = instance->getCurrentTimestamp();
                    instance->addEvent(event);
                }
            }
        }
        return CallNextHookEx(NULL, nCode, wParam, lParam);
    }
    
    void workerFunction() {
        instance = this;
        quitEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        my_pid = GetCurrentProcessId();
        
        startTime = std::chrono::steady_clock::now();
        startTimeInitialized = true;
        
        keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, LowLevelKeyboardProc, GetModuleHandle(NULL), 0);
        if (!keyboardHook) {
            std::cerr << "Failed to set keyboard hook!" << std::endl;
            CloseHandle(quitEvent);
            return;
        }
        
        MSG msg;
        HANDLE handles[] = { quitEvent };
        while (running) {
            DWORD result = MsgWaitForMultipleObjects(1, handles, FALSE, INFINITE, QS_ALLINPUT);
            if (result == WAIT_OBJECT_0) break;
            else if (result == WAIT_OBJECT_0 + 1) {
                while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
                    TranslateMessage(&msg);
                    DispatchMessage(&msg);
                }
            }
        }
        UnhookWindowsHookEx(keyboardHook);
        CloseHandle(quitEvent);
        instance = nullptr;
    }
#endif

#ifdef __linux__
    // EVDEV - This is the Linux equivalent of Windows hook
    // It captures ALL keyboard input globally, no window needed
    // BUT requires: sudo usermod -a -G input $USER && logout
    
    int evdev_fd = -1;
    std::array<bool, KEY_MAX> currentKeyStates;
    
    // Helper: test_bit for capability detection
    bool test_bit(int bit, const unsigned char* array) {
        return (array[bit / 8] >> (bit % 8)) & 1;
    }
    
    // Helper: detect if device is a keyboard
    bool isKeyboardDevice(int fd) {
        unsigned char evtype_bits[EV_MAX/8 + 1] = {0};
        unsigned char key_bits[KEY_MAX/8 + 1] = {0};
        
        if (ioctl(fd, EVIOCGBIT(0, sizeof(evtype_bits)), evtype_bits) < 0) return false;
        if (!test_bit(EV_KEY, evtype_bits)) return false;
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits) < 0) return false;
        
        // Check for keyboard keys (A, B, 1, ENTER)
        return (test_bit(KEY_A, key_bits) && test_bit(KEY_B, key_bits) &&
                test_bit(KEY_1, key_bits) && test_bit(KEY_ENTER, key_bits));
    }
    
    // Helper: find first keyboard device
    int findKeyboardDevice() {
        for (int i = 0; i < 64; i++) {
            char path[64];
            snprintf(path, sizeof(path), "/dev/input/event%d", i);
            
            int fd = open(path, O_RDONLY | O_NONBLOCK);
            if (fd < 0) continue;
            
            if (isKeyboardDevice(fd)) {
                char name[256] = {0};
                ioctl(fd, EVIOCGNAME(sizeof(name)), name);
                std::cout << "[EVDEV] Found keyboard: " << name << " at " << path << std::endl;
                return fd;
            }
            close(fd);
        }
        return -1;
    }
    
    int evdevToLimeKeyCode(int evdevCode) {
        if (evdevCode >= KEY_A && evdevCode <= KEY_Z) return 0x61 + (evdevCode - KEY_A);
        if (evdevCode >= KEY_1 && evdevCode <= KEY_9) return 0x31 + (evdevCode - KEY_1);
        if (evdevCode == KEY_0) return 0x30;
        
        switch (evdevCode) {
            case KEY_BACKSPACE: return 0x08;
            case KEY_TAB: return 0x09;
            case KEY_ENTER: return 0x0D;
            case KEY_ESC: return 0x1B;
            case KEY_SPACE: return 0x20;
            case KEY_DELETE: return 0x7F;
            case KEY_INSERT: return 0x40000049;
            case KEY_HOME: return 0x4000004A;
            case KEY_END: return 0x4000004D;
            case KEY_PAGEUP: return 0x4000004B;
            case KEY_PAGEDOWN: return 0x4000004E;
            case KEY_UP: return 0x40000052;
            case KEY_DOWN: return 0x40000051;
            case KEY_LEFT: return 0x40000050;
            case KEY_RIGHT: return 0x4000004F;
            case KEY_LEFTCTRL: return 0x400000E0;
            case KEY_RIGHTCTRL: return 0x400000E4;
            case KEY_LEFTSHIFT: return 0x400000E1;
            case KEY_RIGHTSHIFT: return 0x400000E5;
            case KEY_LEFTALT: return 0x400000E2;
            case KEY_RIGHTALT: return 0x400000E6;
            case KEY_LEFTMETA: return 0x400000E3;
            case KEY_RIGHTMETA: return 0x400000E7;
            case KEY_CAPSLOCK: return 0x40000039;
            case KEY_NUMLOCK: return 0x40000053;
            case KEY_SCROLLLOCK: return 0x40000047;
            case KEY_F1: return 0x4000003A;
            case KEY_F2: return 0x4000003B;
            case KEY_F3: return 0x4000003C;
            case KEY_F4: return 0x4000003D;
            case KEY_F5: return 0x4000003E;
            case KEY_F6: return 0x4000003F;
            case KEY_F7: return 0x40000040;
            case KEY_F8: return 0x40000041;
            case KEY_F9: return 0x40000042;
            case KEY_F10: return 0x40000043;
            case KEY_F11: return 0x40000044;
            case KEY_F12: return 0x40000045;
            case KEY_MINUS: return 0x2D;
            case KEY_EQUAL: return 0x3D;
            case KEY_LEFTBRACE: return 0x5B;
            case KEY_RIGHTBRACE: return 0x5D;
            case KEY_BACKSLASH: return 0x5C;
            case KEY_SEMICOLON: return 0x3B;
            case KEY_APOSTROPHE: return 0x27;
            case KEY_GRAVE: return 0x60;
            case KEY_COMMA: return 0x2C;
            case KEY_DOT: return 0x2E;
            case KEY_SLASH: return 0x2F;
            default: return 0x00;
        }
    }
    
    void workerFunction() {
        std::cout << "[EVDEV] Linux worker thread started (global keyboard capture mode)" << std::endl;
        
        // Find keyboard device
        evdev_fd = findKeyboardDevice();
        
        if (evdev_fd < 0) {
            std::cerr << "[EVDEV] ERROR: No keyboard device found!" << std::endl;
            std::cerr << "[EVDEV] You need to be in the 'input' group for this to work." << std::endl;
            std::cerr << "[EVDEV] Run: sudo usermod -a -G input $USER, then logout and login again." << std::endl;
            return;
        }
        
        startTime = std::chrono::steady_clock::now();
        startTimeInitialized = true;
        currentKeyStates.fill(false);
        
        std::cout << "[EVDEV] ✓ Global keyboard capture active - Works like Windows hook!" << std::endl;
        std::cout << "[EVDEV] No window focus needed - captures ALL keyboard input" << std::endl;
        
        struct pollfd pfd;
        pfd.fd = evdev_fd;
        pfd.events = POLLIN;
        
        struct input_event ev;
        int eventCounter = 0;
        
        while (running) {
            int ret = poll(&pfd, 1, 100); // 100ms timeout
            
            if (ret < 0) {
                if (errno != EINTR) {
                    std::cerr << "[EVDEV] poll() error: " << strerror(errno) << std::endl;
                }
                continue;
            }
            
            if (ret > 0 && (pfd.revents & POLLIN)) {
                while (read(evdev_fd, &ev, sizeof(ev)) == sizeof(ev)) {
                    if (ev.type == EV_KEY && ev.code >= 0 && ev.code < KEY_MAX) {
                        bool oldState = currentKeyStates[ev.code];
                        bool newState = ev.value;
                        
                        if (newState != oldState) {
                            currentKeyStates[ev.code] = newState;
                            int limeCode = evdevToLimeKeyCode(ev.code);
                            
                            if (limeCode != 0) {
                                eventCounter++;
                                InputEvent inputEvent;
                                inputEvent.scanCode = limeCode;
                                inputEvent.state = newState ? 1 : 0;
                                inputEvent.timestamp = getCurrentTimestamp();
                                
                                // Debug print - remove this in production if you want
                                std::cout << "[EVDEV] Key: 0x" << std::hex << limeCode 
                                          << " State: " << std::dec << inputEvent.state << std::endl;
                                
                                addEvent(inputEvent);
                            }
                        }
                    }
                }
            }
        }
        
        close(evdev_fd);
        std::cout << "[EVDEV] Worker thread stopped. Total events: " << eventCounter << std::endl;
    }
#endif

public:
    double getCurrentTimestamp() {
        if (!startTimeInitialized) {
            startTime = std::chrono::steady_clock::now();
            startTimeInitialized = true;
        }
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration<double>(now - startTime);
        return elapsed.count();
    }

    AsyncInputThread() : running(true) {
#ifdef _WIN32
        worker = std::thread(&AsyncInputThread::workerFunction, this);
#elif defined(__linux__)
        worker = std::thread(&AsyncInputThread::workerFunction, this);
#else
        #error "Unsupported platform"
#endif
    }
    
    ~AsyncInputThread() {
        running = false;
#ifdef _WIN32
        if (instance && instance->quitEvent) SetEvent(instance->quitEvent);
#endif
        if (worker.joinable()) worker.join();
    }

    bool hasEvent() const { return eventCount.load(std::memory_order_acquire) > 0 || hasCurrentEvent; }
    int getScanCode() { loadNextEvent(); return hasCurrentEvent ? currentEvent.scanCode : 0; }
    int getState() { loadNextEvent(); return hasCurrentEvent ? currentEvent.state : 0; }
    double getTimestamp() {
        loadNextEvent();
        if (hasCurrentEvent) { hasCurrentEvent = false; return currentEvent.timestamp; }
        return 0.0;
    }
    size_t getEventCount() const { return eventCount.load(std::memory_order_acquire); }
};

#ifdef _WIN32
AsyncInputThread* AsyncInputThread::instance = nullptr;
#endif

static AsyncInputThread* g_inputThread = nullptr;

void core_start() { if (!g_inputThread) g_inputThread = new AsyncInputThread(); }
void core_stop() { if (g_inputThread) { delete g_inputThread; g_inputThread = nullptr; } }
bool core_hasEvent() { return g_inputThread ? g_inputThread->hasEvent() : false; }
int core_getScanCode() { return g_inputThread ? g_inputThread->getScanCode() : 0; }
int core_getState() { return g_inputThread ? g_inputThread->getState() : 0; }
double core_getTimestamp() { return g_inputThread ? g_inputThread->getTimestamp() : 0.0; }
size_t core_getEventCount() { return g_inputThread ? g_inputThread->getEventCount() : 0; }
double core_getGlobalTimestampComparison() { return g_inputThread ? g_inputThread->getCurrentTimestamp() : 0.0; }