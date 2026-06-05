#include <stdexcept>

// Include the core implementation
#include "AsyncKBCore.cpp"

// ============================================================================
// Global API (C++ interface with C linkage for Haxe) 
// ============================================================================

extern "C" {

void start() {
    core_start();
}

void stop() {
    core_stop();
}

bool hasEvent() {
    return core_hasEvent();
}

double getScanCode() {
    return core_getScanCode();
}

double getState() {
    return core_getState();
}

double getTimestamp() {
    return core_getTimestamp();
}

}