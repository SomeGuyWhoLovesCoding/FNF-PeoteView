// NamedPipe.cpp
#include "include/named_pipe.h"
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdlib.h>
#endif

NamedPipe::NamedPipe(const std::string& name, Mode mode) 
    : pipeName(name), pipeMode(mode) 
#ifdef _WIN32
    , handle(INVALID_HANDLE_VALUE)
#else
    , fd(-1)
#endif
{
}

NamedPipe::~NamedPipe() {
    close();
}

bool NamedPipe::open() {
    close();
    
#ifdef _WIN32
    if (pipeMode == WRITE) {
        handle = CreateNamedPipeA(
            pipeName.c_str(),
            PIPE_ACCESS_OUTBOUND,
            PIPE_TYPE_BYTE | PIPE_NOWAIT,
            1,           // max instances
            65536,       // out buffer size
            65536,       // in buffer size
            0,           // default timeout
            NULL
        );
        return handle != INVALID_HANDLE_VALUE;
    } else {
        handle = CreateFileA(
            pipeName.c_str(),
            GENERIC_READ,
            0, NULL, OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            NULL
        );
        return handle != INVALID_HANDLE_VALUE;
    }
#else
    // Linux/Android - create FIFO if it doesn't exist
    if (pipeMode == WRITE && access(pipeName.c_str(), F_OK) == -1) {
        mkfifo(pipeName.c_str(), 0666);
    }
    
    int flags = (pipeMode == WRITE) ? O_WRONLY : O_RDONLY;
    fd = ::open(pipeName.c_str(), flags | O_NONBLOCK);
    
    return fd != -1;
#endif
}

void NamedPipe::close() {
#ifdef _WIN32
    if (handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        handle = INVALID_HANDLE_VALUE;
    }
#else
    if (fd != -1) {
        ::close(fd);
        fd = -1;
    }
#endif
}

bool NamedPipe::isOpen() const {
#ifdef _WIN32
    return handle != INVALID_HANDLE_VALUE;
#else
    return fd != -1;
#endif
}

size_t NamedPipe::write(const void* data, size_t size) {
#ifdef _WIN32
    DWORD written = 0;
    if (WriteFile(handle, data, (DWORD)size, &written, NULL)) {
        return written;
    }
    return 0;
#else
    ssize_t result = ::write(fd, data, size);
    return result > 0 ? result : 0;
#endif
}

size_t NamedPipe::read(void* buffer, size_t size) {
#ifdef _WIN32
    DWORD read = 0;
    if (ReadFile(handle, buffer, (DWORD)size, &read, NULL)) {
        return read;
    }
    return 0;
#else
    ssize_t result = ::read(fd, buffer, size);
    return result > 0 ? result : 0;
#endif
}

std::string NamedPipe::generateUniqueName(const std::string& prefix) {
#ifdef _WIN32
    return "\\\\.\\pipe\\" + prefix + "_" + std::to_string(GetCurrentProcessId());
#else
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "/tmp/%s_%d.fifo", 
             prefix.c_str(), getpid());
    return std::string(buffer);
#endif
}

// Static pipe instance
static NamedPipe* gPipe = nullptr;

// Create and open a named pipe
bool create_named_pipe(const char* name, int mode) {
    if (gPipe != nullptr) {
        delete gPipe;
    }
    
    gPipe = new NamedPipe(std::string(name), static_cast<NamedPipe::Mode>(mode));
    return gPipe->open();
}

// Close and destroy the named pipe
void destroy_named_pipe() {
    if (gPipe != nullptr) {
        gPipe->close();
        delete gPipe;
        gPipe = nullptr;
    }
}

// Check if pipe is open
bool is_named_pipe_open() {
    return gPipe != nullptr && gPipe->isOpen();
}

// Write data to pipe
int write_to_named_pipe(const void* data, int size) {
    if (gPipe == nullptr || !gPipe->isOpen()) {
        return -1;
    }
    return static_cast<int>(gPipe->write(data, size));
}

// Read data from pipe
int read_from_named_pipe(void* buffer, int size) {
    if (gPipe == nullptr || !gPipe->isOpen()) {
        return -1;
    }
    return static_cast<int>(gPipe->read(buffer, size));
}

// Generate unique pipe name
const char* generate_named_pipe_name(const char* prefix) {
    static std::string result;
    result = NamedPipe::generateUniqueName(prefix ? std::string(prefix) : "fnf_pipe");
    return result.c_str();
}

// Get current pipe name (if pipe exists)
const char* get_named_pipe_name() {
    static std::string empty;
    if (gPipe == nullptr) {
        return empty.c_str();
    }
    return "";
}

// Free string returned by generate_named_pipe_name
void free_named_pipe_string(const char* str) {
    // Static strings are managed automatically
}