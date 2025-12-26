// NamedPipe.h
#ifndef NAMEDPIPE_H
#define NAMEDPIPE_H

#include <string>
#include <vector>

class NamedPipe {
public:
    enum Mode { READ, WRITE };
    
    NamedPipe(const std::string& name, Mode mode);
    ~NamedPipe();
    
    bool open();
    void close();
    bool isOpen() const;
    
    size_t write(const void* data, size_t size);
    size_t read(void* buffer, size_t size);
    
    static std::string generateUniqueName(const std::string& prefix = "fnf_pipe");
    
private:
    std::string pipeName;
    Mode pipeMode;
    
    #ifdef _WIN32
    void* handle;
    #else
    int fd;
    #endif
    
    void cleanup();
};

#endif