#ifndef __HEADER_DISKMULTIMAP
#define __HEADER_DISKMULTIMAP

#include <list>
#include <cstdint>
#include "BinaryFile.h"

typedef BinaryFile::Offset Location;

class DiskMultiMap {
public:
    struct MultiMapTuple {
        int64_t key, value, context;
    };

    class Iterator {
    public:
        Iterator();
        Iterator(const std::list<MultiMapTuple>& nodeList);
        bool isValid() const;
        Iterator& operator++();
        MultiMapTuple operator*();
    private:
        std::list<MultiMapTuple> nodes;
    };

    DiskMultiMap();
    ~DiskMultiMap();
    bool createNew(const std::string& filename, unsigned int numBuckets);
    bool openExisting(const std::string& filename);
    void close();
    bool insert(int64_t key, int64_t value, int64_t context);
    Iterator search(int64_t key);
    int erase(int64_t key, int64_t value, int64_t context);

private:
    static const Location LIST_END = 2147483647;

    struct DiskMultiMapHeader {
        unsigned int numBuckets = 0;
        long numDeletedNodes = 0;
        Location hashTableStart = 0;
        Location nodeDataStart = 0;
        Location lastDeletedNode = LIST_END;
        Location firstDeletedNode = LIST_END;
    };

    struct DiskMultiMapBucket {
        long numNodes = 0;
        Location location = 0;
        Location lastNode = LIST_END;
        Location firstNode = LIST_END;
    };

    struct BucketNode {
        int64_t key;
        int64_t value;
        int64_t context;
        Location location;
        Location nextNode;
    };

    bool createNode(int64_t key, int64_t value, int64_t context, BucketNode& node) const;
    bool nodeEquals(const BucketNode& node, int64_t key, int64_t value, int64_t context) const;
    MultiMapTuple convertToTuple(const BucketNode& node) const;

    unsigned long hash(int64_t key) const;
    Location nextLocationToAddAt();
    void addDeletedNode(BucketNode node);

    DiskMultiMapBucket bucketAt(unsigned long index);
    BucketNode nodeAt(Location offset);
    bool updateBucket(DiskMultiMapBucket bucket);
    bool updateNode(BucketNode node);
    bool syncHeader();

    DiskMultiMapHeader header;
    BinaryFile bf;
};

#endif // __HEADER_DISKMULTIMAP
