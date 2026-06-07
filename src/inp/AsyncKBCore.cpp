// Platform detection
#ifdef _WIN32
    #include <windows.h>
    #pragma comment(lib, "user32.lib")
#elif defined(__linux__)
    #include <linux/input.h>
    #include <fcntl.h>
    #include <unistd.h>
    #include <cstring>
    #include <poll.h>
    #include <errno.h>
    #include <sys/eventfd.h>
    #include <X11/Xlib.h>
    #include <X11/Xatom.h>
#endif

#include <atomic>
#include <mutex>
#include <condition_variable>
#include <array>
#include <thread>
#include <chrono>
#include <iostream>

struct InputEvent {
    double scanCode;
    double state;
    double timestamp;
};

class AsyncInputThread {
private:
    static constexpr size_t MAX_EVENTS = 512;
    
    std::atomic<bool> running;
    std::atomic<bool> hasFocus{true}; // Used for Linux state tracking
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
            // AUTO-DETECT FOCUS (Windows)
            HWND foreground = GetForegroundWindow();
            DWORD pid = 0;
            if (foreground) GetWindowThreadProcessId(foreground, &pid);
            bool isFocused = (pid == instance->my_pid);

            if (isFocused) {
                KBDLLHOOKSTRUCT* kb = (KBDLLHOOKSTRUCT*)lParam;
                
                if (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN || 
                    wParam == WM_KEYUP || wParam == WM_SYSKEYUP) {
                    InputEvent event;
                    event.scanCode = static_cast<double>(instance->windowsToLimeKeyCode(kb->vkCode));
                    event.state = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN) ? 1.0 : 0.0;
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
    int keyboard_fd = -1;
    int event_fd = -1;
    std::array<bool, KEY_MAX> currentKeyStates;
    
    Display* dpy = nullptr;
    int x11_fd = -1;
    Atom net_active_window = None;
    Atom net_wm_pid = None;
    Window root = None;
    pid_t my_pid;

    bool checkX11Focus(Display* dpy, Window root, Atom net_active_window, Atom net_wm_pid, pid_t my_pid) {
        Atom actual_type;
        int actual_format;
        unsigned long nitems, bytes_after;
        unsigned char* prop = NULL;
        
        if (XGetWindowProperty(dpy, root, net_active_window, 0, 1, False, XA_WINDOW,
                               &actual_type, &actual_format, &nitems, &bytes_after, &prop) == Success && prop) {
            // FIX 1: Check format and size before dereferencing to prevent heap overread segfaults
            if (actual_format == 32 && nitems > 0) {
                Window active = *(Window*)prop;
                XFree(prop);
                prop = NULL;
                
                if (active != None) {
                    if (XGetWindowProperty(dpy, active, net_wm_pid, 0, 1, False, XA_CARDINAL,
                                           &actual_type, &actual_format, &nitems, &bytes_after, &prop) == Success && prop) {
                        if (actual_format == 32 && nitems > 0) {
                            // X11 32-bit properties are stored in arrays of `long`. Cast safely.
                            pid_t wm_pid = static_cast<pid_t>(*(long*)prop);
                            XFree(prop);
                            return wm_pid == my_pid;
                        }
                        XFree(prop);
                    }
                }
            } else {
                XFree(prop);
            }
        }
        return true; // Fallback to true if WM doesn't support EWMH properly
    }
    
    int linuxToLimeKeyCode(int evdevCode) {
        if (evdevCode >= KEY_A && evdevCode <= KEY_Z) return 0x61 + (evdevCode - KEY_A);
        if (evdevCode >= KEY_1 && evdevCode <= KEY_9) return 0x31 + (evdevCode - KEY_1);
        if (evdevCode == KEY_0) return 0x30;
        
        switch (evdevCode) {
            case KEY_BACKSPACE: return 0x08; case KEY_TAB: return 0x09; case KEY_ENTER: return 0x0D;
            case KEY_ESC: return 0x1B; case KEY_SPACE: return 0x20; case KEY_DELETE: return 0x7F;
            case KEY_INSERT: return 0x40000049; case KEY_HOME: return 0x4000004A; case KEY_END: return 0x4000004D;
            case KEY_PAGEUP: return 0x4000004B; case KEY_PAGEDOWN: return 0x4000004E; case KEY_UP: return 0x40000052;
            case KEY_DOWN: return 0x40000051; case KEY_LEFT: return 0x40000050; case KEY_RIGHT: return 0x4000004F;
            case KEY_LEFTCTRL: return 0x400000E0; case KEY_RIGHTCTRL: return 0x400000E4; case KEY_LEFTSHIFT: return 0x400000E1;
            case KEY_RIGHTSHIFT: return 0x400000E5; case KEY_LEFTALT: return 0x400000E2; case KEY_RIGHTALT: return 0x400000E6;
            case KEY_LEFTMETA: return 0x400000E3; case KEY_RIGHTMETA: return 0x400000E7; case KEY_CAPSLOCK: return 0x40000039;
            case KEY_NUMLOCK: return 0x40000053; case KEY_SCROLLLOCK: return 0x40000047; case KEY_F1: return 0x4000003A;
            case KEY_F2: return 0x4000003B; case KEY_F3: return 0x4000003C; case KEY_F4: return 0x4000003D;
            case KEY_F5: return 0x4000003E; case KEY_F6: return 0x4000003F; case KEY_F7: return 0x40000040;
            case KEY_F8: return 0x40000041; case KEY_F9: return 0x40000042; case KEY_F10: return 0x40000043;
            case KEY_F11: return 0x40000044; case KEY_F12: return 0x40000045; case KEY_MINUS: return 0x2D;
            case KEY_EQUAL: return 0x3D; case KEY_LEFTBRACE: return 0x5B; case KEY_RIGHTBRACE: return 0x5D;
            case KEY_BACKSLASH: return 0x5C; case KEY_SEMICOLON: return 0x3B; case KEY_APOSTROPHE: return 0x27;
            case KEY_GRAVE: return 0x60; case KEY_COMMA: return 0x2C; case KEY_DOT: return 0x2E;
            case KEY_SLASH: return 0x2F; default: return 0x00;
        }
    }
    
    void workerFunction() {
        event_fd = eventfd(0, EFD_NONBLOCK);
        if (event_fd < 0) { std::cerr << "Failed to create eventfd" << std::endl; return; }
        
        for (int i = 0; i < 32; i++) {
            char path[64]; snprintf(path, sizeof(path), "/dev/input/event%d", i);
            int fd = open(path, O_RDONLY | O_NONBLOCK);
            if (fd >= 0) {
                char name[256] = {0};
                if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0) {
                    if (strstr(name, "keyboard") || strstr(name, "Keyboard") || 
                        strstr(name, "AT Translated") || strstr(name, "kbd")) {
                        keyboard_fd = fd; break;
                    }
                }
                close(fd);
            }
        }
        
        if (keyboard_fd < 0) {
            for (int i = 0; i < 32; i++) {
                char path[64]; snprintf(path, sizeof(path), "/dev/input/event%d", i);
                int fd = open(path, O_RDONLY | O_NONBLOCK);
                if (fd >= 0) { keyboard_fd = fd; break; }
            }
        }
        
        if (keyboard_fd < 0) {
            std::cerr << "Failed to open keyboard device on Linux" << std::endl;
            // FIX 3: Do not close event_fd here. Let the destructor handle it to prevent double-close.
            return; 
        }
        
        startTime = std::chrono::steady_clock::now();
        startTimeInitialized = true;
        currentKeyStates.fill(false);
        
        // AUTO-DETECT FOCUS (Linux via X11)
        dpy = XOpenDisplay(NULL);
        if (dpy) {
            x11_fd = XConnectionNumber(dpy);
            net_active_window = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", True);
            net_wm_pid = XInternAtom(dpy, "_NET_WM_PID", True);
            root = DefaultRootWindow(dpy);
            my_pid = getpid();
            
            if (net_active_window != None && net_wm_pid != None && root != None) {
                XSelectInput(dpy, root, PropertyChangeMask);
                bool initialFocus = checkX11Focus(dpy, root, net_active_window, net_wm_pid, my_pid);
                hasFocus.store(initialFocus, std::memory_order_relaxed);
            } else {
                XCloseDisplay(dpy);
                dpy = nullptr;
                x11_fd = -1;
            }
        }
        
        struct input_event ev;
        struct pollfd pfds[3];
        pfds[0].fd = keyboard_fd; pfds[0].events = POLLIN;
        pfds[1].fd = event_fd; pfds[1].events = POLLIN;
        int num_fds = 2;
        
        if (x11_fd >= 0) {
            pfds[2].fd = x11_fd; pfds[2].events = POLLIN;
            num_fds = 3;
        }
        
        struct sched_param param;
        param.sched_priority = sched_get_priority_max(SCHED_FIFO);
        pthread_setschedparam(pthread_self(), SCHED_FIFO, &param);
        
        while (running) {
            int ret = poll(pfds, num_fds, -1);
            if (ret < 0) {
                if (errno != EINTR) { std::cerr << "poll() error" << std::endl; break; }
                continue;
            }
            
            if (pfds[1].revents & POLLIN) break;

            // Process X11 events FIRST to ensure focus state is updated before reading keys
            if (x11_fd >= 0 && (pfds[2].revents & POLLIN)) {
                // FIX 2: Use XEventsQueued with QueuedAfterFlush to actually read from the socket
                while (XEventsQueued(dpy, QueuedAfterFlush) > 0) {
                    XEvent xev;
                    XNextEvent(dpy, &xev);
                    if (xev.type == PropertyNotify && xev.xproperty.atom == net_active_window) {
                        bool focused = checkX11Focus(dpy, root, net_active_window, net_wm_pid, my_pid);
                        hasFocus.store(focused, std::memory_order_relaxed);
                    }
                }
            }
            
            if (pfds[0].revents & POLLIN) {
                while (read(keyboard_fd, &ev, sizeof(ev)) == sizeof(ev)) {
                    if (ev.type == EV_KEY && ev.code >= 0 && ev.code < KEY_MAX) {
                        bool oldState = currentKeyStates[ev.code];
                        bool newState = ev.value;
                        
                        currentKeyStates[ev.code] = newState;

                        bool isFocused = true;
                        if (x11_fd >= 0) {
                            isFocused = hasFocus.load(std::memory_order_relaxed);
                        }

                        if (isFocused) {
                            int limeCode = linuxToLimeKeyCode(ev.code);
                            if (limeCode) {
                                if (newState != oldState) {
                                    InputEvent event;
                                    event.scanCode = static_cast<double>(limeCode);
                                    event.state = static_cast<double>(newState);
                                    event.timestamp = getCurrentTimestamp();
                                    addEvent(event);
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // FIX 3: Removed close(keyboard_fd) and close(event_fd) from here. 
        // The destructor will safely close them after worker.join() completes.
        if (dpy) XCloseDisplay(dpy);
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
    #elif defined(__linux__)
            if (event_fd >= 0) {
                // Write to the eventfd to safely wake up the poll() loop
                uint64_t val = 1;
                write(event_fd, &val, sizeof(val));
            }
    #endif
            if (worker.joinable()) worker.join();
            
            // NOW it is safe to close the FD after the thread has joined
    #ifdef __linux__
            if (event_fd >= 0) close(event_fd);
            if (keyboard_fd >= 0) close(keyboard_fd);
    #endif
        }

    bool hasEvent() const { return eventCount.load(std::memory_order_acquire) > 0 || hasCurrentEvent; }
    double getScanCode() { loadNextEvent(); return hasCurrentEvent ? currentEvent.scanCode : 0.0; }
    double getState() { loadNextEvent(); return hasCurrentEvent ? currentEvent.state : 0.0; }
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
double core_getScanCode() { return g_inputThread ? g_inputThread->getScanCode() : 0.0; }
double core_getState() { return g_inputThread ? g_inputThread->getState() : 0.0; }
double core_getTimestamp() { return g_inputThread ? g_inputThread->getTimestamp() : 0.0; }
size_t core_getEventCount() { return g_inputThread ? g_inputThread->getEventCount() : 0; }
double core_getGlobalTimestampComparison() { return g_inputThread ? g_inputThread->getCurrentTimestamp() : 0.0; }