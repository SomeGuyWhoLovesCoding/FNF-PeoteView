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
    // X11 members
    Display* dpy = nullptr;
    Window capture_window;
    int x11_fd = -1;
    bool hasFocus = true;
    
    // EVDEV members
    int evdev_fd = -1;
    bool use_evdev = false;
    std::array<bool, KEY_MAX> currentKeyStates;
    
    // Helper: test_bit for capability detection (SDL-style)
    bool test_bit(int bit, const unsigned char* array) {
        return (array[bit / 8] >> (bit % 8)) & 1;
    }
    
    // Helper: detect if device is a keyboard using capability bits (SDL-style)
    bool isKeyboardDevice(int fd) {
        unsigned char evtype_bits[EV_MAX/8 + 1] = {0};
        unsigned char key_bits[KEY_MAX/8 + 1] = {0};
        
        std::cout << "[EVDEV] Testing device capabilities..." << std::endl;
        
        // Get event type capabilities
        if (ioctl(fd, EVIOCGBIT(0, sizeof(evtype_bits)), evtype_bits) < 0) {
            std::cout << "[EVDEV] Failed to get event type bits: " << strerror(errno) << std::endl;
            return false;
        }
        
        // Check if it supports EV_KEY events
        if (!test_bit(EV_KEY, evtype_bits)) {
            std::cout << "[EVDEV] Device does not support EV_KEY events" << std::endl;
            return false;
        }
        
        // Get key capabilities
        if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(key_bits)), key_bits) < 0) {
            std::cout << "[EVDEV] Failed to get key bits: " << strerror(errno) << std::endl;
            return false;
        }
        
        // Check for keyboard-specific keys (SDL-style detection)
        bool hasKeyboardKeys = 
            test_bit(KEY_A, key_bits) && 
            test_bit(KEY_B, key_bits) &&
            test_bit(KEY_1, key_bits) &&
            test_bit(KEY_ENTER, key_bits);
        
        if (hasKeyboardKeys) {
            std::cout << "[EVDEV] ✓ Device has keyboard keys (A, B, 1, ENTER)" << std::endl;
            return true;
        }
        
        // Fallback: check if it has any keys at all
        for (int i = 0; i < KEY_MAX; i++) {
            if (test_bit(i, key_bits)) {
                std::cout << "[EVDEV] Device has keys but not typical keyboard set" << std::endl;
                return true;
            }
        }
        
        return false;
    }
    
    // Helper: find keyboard device using SDL-style scanning
    int findEvdevKeyboard() {
        std::cout << "[EVDEV] Scanning for keyboard devices..." << std::endl;
        
        for (int i = 0; i < 64; i++) {
            char path[64];
            snprintf(path, sizeof(path), "/dev/input/event%d", i);
            
            int fd = open(path, O_RDONLY | O_NONBLOCK);
            if (fd < 0) {
                if (errno != ENOENT && errno != EACCES) {
                    std::cout << "[EVDEV] Cannot open " << path << ": " << strerror(errno) << std::endl;
                }
                continue;
            }
            
            // Get device name
            char name[256] = {0};
            if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0) {
                std::cout << "[EVDEV] Testing device: " << path << " - \"" << name << "\"" << std::endl;
            } else {
                std::cout << "[EVDEV] Testing device: " << path << " - (unknown name)" << std::endl;
            }
            
            // Check if this is a keyboard using capability detection
            if (isKeyboardDevice(fd)) {
                std::cout << "[EVDEV] ✓ Found keyboard device: " << path;
                if (name[0]) std::cout << " (\"" << name << "\")";
                std::cout << std::endl;
                return fd;
            }
            
            close(fd);
        }
        
        return -1;
    }
    
    // Helper: convert evdev keycode to Lime scan code
    int evdevToLimeKeyCode(int evdevCode) {
        // Letters a-z
        if (evdevCode >= KEY_A && evdevCode <= KEY_Z) 
            return 0x61 + (evdevCode - KEY_A);
        // Numbers 0-9
        if (evdevCode >= KEY_1 && evdevCode <= KEY_9) 
            return 0x31 + (evdevCode - KEY_1);
        if (evdevCode == KEY_0) return 0x30;
        
        // Special keys
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
        std::cout << "[DEBUG] Linux worker thread started" << std::endl;
        
        // Try EVDEV first (SDL-style raw input, works without focus)
        std::cout << "[DEBUG] Attempting to initialize EVDEV keyboard (raw input)..." << std::endl;
        evdev_fd = findEvdevKeyboard();
        
        if (evdev_fd >= 0) {
            std::cout << "[DEBUG] ✓ EVDEV keyboard initialized successfully (fd=" << evdev_fd << ")" << std::endl;
            std::cout << "[DEBUG] EVDEV mode: Will capture all keyboard input globally (no focus needed)" << std::endl;
            use_evdev = true;
            currentKeyStates.fill(false);
        } else {
            std::cout << "[DEBUG] EVDEV initialization failed, falling back to X11..." << std::endl;
            std::cout << "[DEBUG] X11 mode requires window focus to receive keyboard events" << std::endl;
            use_evdev = false;
        }
        
        startTime = std::chrono::steady_clock::now();
        startTimeInitialized = true;
        
        if (use_evdev) {
            // ========== EVDEV MODE (Raw input, no focus needed) ==========
            std::cout << "[DEBUG] Entering EVDEV event loop..." << std::endl;
            
            struct pollfd pfd;
            pfd.fd = evdev_fd;
            pfd.events = POLLIN;
            
            struct input_event ev;
            int eventCounter = 0;
            int heartbeatCounter = 0;
            
            while (running) {
                int ret = poll(&pfd, 1, 100); // 100ms timeout
                
                if (ret < 0) {
                    if (errno != EINTR) {
                        std::cerr << "[EVDEV] poll() error: " << strerror(errno) << std::endl;
                    }
                    continue;
                }
                
                if (ret == 0) {
                    // Timeout - heartbeat every 50 polls (5 seconds)
                    heartbeatCounter++;
                    if (heartbeatCounter >= 50) {
                        std::cout << "[HEARTBEAT] EVDEV worker alive, waiting for keys..." << std::endl;
                        heartbeatCounter = 0;
                    }
                    continue;
                }
                
                // Read events
                while (read(evdev_fd, &ev, sizeof(ev)) == sizeof(ev)) {
                    if (ev.type == EV_KEY && ev.code >= 0 && ev.code < KEY_MAX) {
                        bool oldState = currentKeyStates[ev.code];
                        bool newState = ev.value;
                        
                        if (newState != oldState) {
                            currentKeyStates[ev.code] = newState;
                            
                            int limeCode = evdevToLimeKeyCode(ev.code);
                            
                            if (limeCode != 0) {
                                eventCounter++;
                                double timestamp = getCurrentTimestamp();
                                
                                std::cout << "[EVDEV] ⭐ KEY EVENT #" << eventCounter << " ⭐" << std::endl;
                                std::cout << "  Evdev Code: 0x" << std::hex << ev.code << std::dec << std::endl;
                                std::cout << "  Lime Code: 0x" << std::hex << limeCode << std::dec << std::endl;
                                std::cout << "  State: " << (newState ? "PRESSED" : "RELEASED") << std::endl;
                                std::cout << "  Timestamp: " << std::fixed << std::setprecision(6) << timestamp << "s" << std::endl;
                                
                                // Translate to readable key name
                                std::cout << "  Key: ";
                                if (limeCode >= 0x61 && limeCode <= 0x7A) {
                                    std::cout << char(limeCode);
                                } else if (limeCode >= 0x30 && limeCode <= 0x39) {
                                    std::cout << char(limeCode);
                                } else {
                                    switch (limeCode) {
                                        case 0x1B: std::cout << "ESC"; break;
                                        case 0x0D: std::cout << "ENTER"; break;
                                        case 0x20: std::cout << "SPACE"; break;
                                        case 0x08: std::cout << "BACKSPACE"; break;
                                        case 0x09: std::cout << "TAB"; break;
                                        case 0x7F: std::cout << "DELETE"; break;
                                        default: std::cout << "KEY(0x" << std::hex << limeCode << std::dec << ")";
                                    }
                                }
                                std::cout << std::endl;
                                std::cout << "----------------------------------------" << std::endl;
                                
                                InputEvent inputEvent;
                                inputEvent.scanCode = limeCode;
                                inputEvent.state = newState ? 1 : 0;
                                inputEvent.timestamp = timestamp;
                                addEvent(inputEvent);
                            }
                        }
                    }
                }
            }
            
            close(evdev_fd);
            std::cout << "[EVDEV] Worker thread exiting. Total events: " << eventCounter << std::endl;
            
        } else {
            // ========== X11 MODE (Requires window focus) ==========
            std::cout << "[DEBUG] Opening X display..." << std::endl;
            dpy = XOpenDisplay(nullptr);
            if (!dpy) {
                std::cerr << "[ERROR] Failed to open X display. Make sure you're running under X11." << std::endl;
                std::cerr << "[ERROR] Try: export DISPLAY=:0" << std::endl;
                return;
            }
            std::cout << "[DEBUG] X display opened successfully" << std::endl;
            
            // Get the root window
            Window root = DefaultRootWindow(dpy);
            std::cout << "[DEBUG] Root window: " << root << std::endl;
            
            // Create a simple input-only window (doesn't need to be visible)
            std::cout << "[DEBUG] Creating capture window..." << std::endl;
            capture_window = XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0);
            std::cout << "[DEBUG] Capture window created: " << capture_window << std::endl;
            
            // Select which events we want to receive
            XSelectInput(dpy, capture_window, 
                         KeyPressMask | KeyReleaseMask | FocusChangeMask);
            std::cout << "[DEBUG] Selected KeyPress, KeyRelease, and FocusChange events" << std::endl;
            
            // Map the window (make it ready to receive events)
            XMapWindow(dpy, capture_window);
            std::cout << "[DEBUG] Window mapped" << std::endl;
            
            // Get the file descriptor for the X11 connection
            x11_fd = XConnectionNumber(dpy);
            std::cout << "[DEBUG] X11 connection FD: " << x11_fd << std::endl;
            
            // Flush all pending requests
            XFlush(dpy);
            
            std::cout << "[DEBUG] X11 keyboard capture initialized successfully" << std::endl;
            std::cout << "[DEBUG] IMPORTANT: Click on the invisible window or your app window to give it focus!" << std::endl;
            
            // Use poll/select to check for events with timeout
            fd_set fds;
            struct timeval tv;
            int eventCounter = 0;
            
            while (running) {
                // Set up file descriptor set
                FD_ZERO(&fds);
                FD_SET(x11_fd, &fds);
                
                // Set timeout to 10ms
                tv.tv_sec = 0;
                tv.tv_usec = 10000;
                
                int ret = select(x11_fd + 1, &fds, nullptr, nullptr, &tv);
                
                if (ret < 0) {
                    if (errno != EINTR) {
                        std::cerr << "[ERROR] select() error: " << errno << std::endl;
                        break;
                    }
                    continue;
                }
                
                if (ret > 0 && FD_ISSET(x11_fd, &fds)) {
                    while (XPending(dpy) > 0) {
                        XEvent event;
                        XNextEvent(dpy, &event);
                        
                        switch (event.type) {
                            case KeyPress:
                            case KeyRelease: {
                                KeySym keysym = XLookupKeysym(&event.xkey, 0);
                                int limeCode = x11ToLimeKeyCode(keysym);
                                
                                if (limeCode != 0) {
                                    eventCounter++;
                                    InputEvent inputEvent;
                                    inputEvent.scanCode = limeCode;
                                    inputEvent.state = (event.type == KeyPress) ? 1 : 0;
                                    inputEvent.timestamp = getCurrentTimestamp();
                                    
                                    std::cout << "[X11] Key event #" << eventCounter 
                                              << " - Code: 0x" << std::hex << limeCode 
                                              << " State: " << std::dec << inputEvent.state << std::endl;
                                    
                                    addEvent(inputEvent);
                                }
                                break;
                            }
                            
                            case FocusIn:
                                std::cout << "[X11] FocusIn - Window gained focus!" << std::endl;
                                hasFocus = true;
                                break;
                                
                            case FocusOut:
                                std::cout << "[X11] FocusOut - Window lost focus" << std::endl;
                                hasFocus = false;
                                break;
                        }
                    }
                }
                
                // Heartbeat every 5 seconds
                static auto lastHeartbeat = std::chrono::steady_clock::now();
                auto now = std::chrono::steady_clock::now();
                if (std::chrono::duration_cast<std::chrono::seconds>(now - lastHeartbeat).count() >= 5) {
                    std::cout << "[HEARTBEAT] X11 worker alive, events: " << eventCounter 
                              << ", focused: " << (hasFocus ? "YES" : "NO") << std::endl;
                    lastHeartbeat = now;
                }
            }
            
            // Cleanup
            std::cout << "[DEBUG] Cleaning up X11 resources..." << std::endl;
            XDestroyWindow(dpy, capture_window);
            XCloseDisplay(dpy);
            std::cout << "[DEBUG] X11 keyboard capture stopped" << std::endl;
        }
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