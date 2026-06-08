// Platform detection
#ifdef _WIN32
    #include <windows.h>
    #pragma comment(lib, "user32.lib")
#elif defined(__linux__)
    #include <X11/Xlib.h>
    #include <X11/Xutil.h>
    #include <X11/keysym.h>
    #include <unistd.h>
#endif

#include <atomic>
#include <mutex>
#include <condition_variable>
#include <array>
#include <thread>
#include <chrono>
#include <iostream>

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
    Display* dpy = nullptr;
    Window capture_window;
    int x11_fd = -1;
    bool hasFocus = true;
    
    int x11ToLimeKeyCode(KeySym keysym) {
        // Letters (uppercase)
        if (keysym >= XK_A && keysym <= XK_Z) return 0x61 + (keysym - XK_A);
        // Letters (lowercase)
        if (keysym >= XK_a && keysym <= XK_z) return 0x61 + (keysym - XK_a);
        
        // Numbers
        if (keysym >= XK_0 && keysym <= XK_9) return keysym;
        
        // Special keys
        switch (keysym) {
            case XK_BackSpace: return 0x08;
            case XK_Tab: return 0x09;
            case XK_Return: return 0x0D;
            case XK_Escape: return 0x1B;
            case XK_space: return 0x20;
            case XK_Delete: return 0x7F;
            case XK_Insert: return 0x40000049;
            case XK_Home: return 0x4000004A;
            case XK_End: return 0x4000004D;
            case XK_Page_Up: return 0x4000004B;
            case XK_Page_Down: return 0x4000004E;
            case XK_Up: return 0x40000052;
            case XK_Down: return 0x40000051;
            case XK_Left: return 0x40000050;
            case XK_Right: return 0x4000004F;
            case XK_Shift_L: return 0x400000E1;
            case XK_Shift_R: return 0x400000E5;
            case XK_Control_L: return 0x400000E0;
            case XK_Control_R: return 0x400000E4;
            case XK_Alt_L: return 0x400000E2;
            case XK_Alt_R: return 0x400000E6;
            case XK_Super_L: return 0x400000E3;
            case XK_Super_R: return 0x400000E7;
            case XK_Caps_Lock: return 0x40000039;
            case XK_Num_Lock: return 0x40000053;
            case XK_Scroll_Lock: return 0x40000047;
            case XK_F1: return 0x4000003A;
            case XK_F2: return 0x4000003B;
            case XK_F3: return 0x4000003C;
            case XK_F4: return 0x4000003D;
            case XK_F5: return 0x4000003E;
            case XK_F6: return 0x4000003F;
            case XK_F7: return 0x40000040;
            case XK_F8: return 0x40000041;
            case XK_F9: return 0x40000042;
            case XK_F10: return 0x40000043;
            case XK_F11: return 0x40000044;
            case XK_F12: return 0x40000045;
            case XK_minus: return 0x2D;
            case XK_equal: return 0x3D;
            case XK_bracketleft: return 0x5B;
            case XK_bracketright: return 0x5D;
            case XK_backslash: return 0x5C;
            case XK_semicolon: return 0x3B;
            case XK_apostrophe: return 0x27;
            case XK_grave: return 0x60;
            case XK_comma: return 0x2C;
            case XK_period: return 0x2E;
            case XK_slash: return 0x2F;
            default: return 0x00;
        }
    }
    
    void workerFunction() {
        // Open connection to X server
        dpy = XOpenDisplay(nullptr);
        if (!dpy) {
            std::cerr << "Failed to open X display. Make sure you're running under X11." << std::endl;
            std::cerr << "Try: export DISPLAY=:0" << std::endl;
            return;
        }
        
        startTime = std::chrono::steady_clock::now();
        startTimeInitialized = true;
        
        // Get the root window
        Window root = DefaultRootWindow(dpy);
        
        // Create a simple input-only window (doesn't need to be visible)
        capture_window = XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0);
        
        // Select which events we want to receive
        XSelectInput(dpy, capture_window, 
                     KeyPressMask | KeyReleaseMask | FocusChangeMask);
        
        // Map the window (make it ready to receive events)
        XMapWindow(dpy, capture_window);
        
        // Get the file descriptor for the X11 connection
        x11_fd = XConnectionNumber(dpy);
        
        // Flush all pending requests
        XFlush(dpy);
        
        std::cout << "X11 keyboard capture initialized successfully" << std::endl;
        
        // Use poll/select to check for events with timeout
        fd_set fds;
        struct timeval tv;
        
        while (running) {
            // Set up file descriptor set
            FD_ZERO(&fds);
            FD_SET(x11_fd, &fds);
            
            // Set timeout to 10ms (allows checking running flag frequently)
            tv.tv_sec = 0;
            tv.tv_usec = 10000;  // 10ms timeout
            
            // Wait for X11 events with timeout
            int ret = select(x11_fd + 1, &fds, nullptr, nullptr, &tv);
            
            if (ret < 0) {
                // Error in select
                if (errno != EINTR) {
                    std::cerr << "select() error" << std::endl;
                    break;
                }
                continue;
            }
            
            if (ret > 0 && FD_ISSET(x11_fd, &fds)) {
                // Process pending X11 events
                while (XPending(dpy) > 0) {
                    XEvent event;
                    XNextEvent(dpy, &event);
                    
                    switch (event.type) {
                        case KeyPress:
                        case KeyRelease: {
                            // Get the key symbol
                            KeySym keysym = XLookupKeysym(&event.xkey, 0);
                            int limeCode = x11ToLimeKeyCode(keysym);
                            
                            if (limeCode != 0) {
                                InputEvent inputEvent;
                                inputEvent.scanCode = limeCode;
                                inputEvent.state = (event.type == KeyPress) ? 1 : 0;
                                inputEvent.timestamp = getCurrentTimestamp();
                                addEvent(inputEvent);
                            }
                            break;
                        }
                        
                        case FocusIn:
                            hasFocus = true;
                            break;
                            
                        case FocusOut:
                            hasFocus = false;
                            break;
                    }
                }
            }
        }
        
        // Cleanup
        XDestroyWindow(dpy, capture_window);
        XCloseDisplay(dpy);
        std::cout << "X11 keyboard capture stopped" << std::endl;
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