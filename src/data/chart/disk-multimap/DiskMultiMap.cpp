#include "DiskMultiMap.h"
#include <list>
#include <vector>
#include <iostream>
#include <algorithm>

////////////////////////////////////////////
// DiskMultiMap Class Implementation
////////////////////////////////////////////

DiskMultiMap::DiskMultiMap() {}
DiskMultiMap::~DiskMultiMap() { close(); }

bool DiskMultiMap::createNew(const std::string& filename, unsigned int numBuckets) {
    bf.close();
    if (!bf.createNew(filename))
        return false;

    header.hashTableStart = sizeof(DiskMultiMapHeader);
    header.nodeDataStart = header.hashTableStart + numBuckets * sizeof(DiskMultiMapBucket);
    header.numBuckets = numBuckets;
    syncHeader();

    DiskMultiMapBucket b;
    for (unsigned int i = 0; i < numBuckets; i++) {
        b.location = bf.fileLength();
        if (!bf.write(b, b.location))
            return false;
    }

    return true;
}

bool DiskMultiMap::openExisting(const std::string& filename) {
    bf.close();
    return bf.openExisting(filename) && bf.read(header, 0);
}

void DiskMultiMap::close() {
    bf.close();
}

bool DiskMultiMap::insert(int64_t key, int64_t value, int64_t context) {
    BucketNode node;
    if (createNode(key, value, context, node)) {
        DiskMultiMapBucket bucket = bucketAt(hash(key));
        node.location = nextLocationToAddAt();
        node.nextNode = LIST_END;

        if (bucket.numNodes++ == 0) {
            bucket.firstNode = node.location;
            bucket.lastNode = node.location;
        } else {
            BucketNode lastNode = nodeAt(bucket.lastNode);
            lastNode.nextNode = node.location;
            bucket.lastNode = node.location;
            updateNode(lastNode);
        }

        updateNode(node);
        updateBucket(bucket);
        return true;
    }

    return false;
}

int DiskMultiMap::erase(int64_t key, int64_t value, int64_t context) {
    DiskMultiMapBucket bucket = bucketAt(hash(key));
    if (bucket.numNodes == 0) return 0;

    int itemsErased = 0;
    std::vector<BucketNode> nodes;
    nodes.push_back(nodeAt(bucket.firstNode));

    for (int i = 1; i < bucket.numNodes; i++)
        nodes.push_back(nodeAt(nodes.back().nextNode));

    for (auto it = nodes.begin(); it != nodes.end(); ++it) {
        if (nodeEquals(*it, key, value, context)) {
            addDeletedNode(*it);
            it = --nodes.erase(it);
            itemsErased++;
        }
    }

    if (!nodes.empty()) {
        nodes.back().nextNode = LIST_END;
        updateNode(nodes.back());
        for (size_t i = 0; i < nodes.size() - 1; i++) {
            nodes[i].nextNode = nodes[i + 1].location;
            updateNode(nodes[i]);
        }
    }

    bucket.firstNode = nodes.empty() ? LIST_END : nodes.front().location;
    bucket.lastNode = nodes.empty() ? LIST_END : nodes.back().location;
    bucket.numNodes = nodes.size();

    syncHeader();
    updateBucket(bucket);
    return itemsErased;
}

DiskMultiMap::Iterator DiskMultiMap::search(int64_t key) {
    DiskMultiMapBucket bucket = bucketAt(hash(key));
    if (bucket.numNodes == 0)
        return Iterator();

    std::list<BucketNode> bucketNodes;
    bucketNodes.push_back(nodeAt(bucket.firstNode));

    for (int i = 1; i < bucket.numNodes; i++)
        bucketNodes.push_back(nodeAt(bucketNodes.back().nextNode));

    std::list<MultiMapTuple> nodeList;
    for (const auto& node : bucketNodes)
        if (node.key == key)
            nodeList.push_back(convertToTuple(node));

    return Iterator(nodeList);
}

////////////////////////////////////////////
// DiskMultiMap Helper Functions
////////////////////////////////////////////

bool DiskMultiMap::createNode(int64_t key, int64_t value, int64_t context, BucketNode& node) const {
    node.key = key;
    node.value = value;
    node.context = context;
    return true;
}

MultiMapTuple DiskMultiMap::convertToTuple(const BucketNode& node) const {
    MultiMapTuple tuple;
    tuple.key = node.key;
    tuple.value = node.value;
    tuple.context = node.context;
    return tuple;
}

bool DiskMultiMap::nodeEquals(const BucketNode& node, int64_t key, int64_t value, int64_t context) const {
    return node.key == key && node.value == value && node.context == context;
}

Location DiskMultiMap::nextLocationToAddAt() {
    if (header.numDeletedNodes > 0) {
        BucketNode deletedNode = nodeAt(header.firstDeletedNode);
        header.firstDeletedNode = deletedNode.nextNode;
        if (--header.numDeletedNodes == 0)
            header.lastDeletedNode = LIST_END;
        syncHeader();
        return deletedNode.location;
    }

    return bf.fileLength();
}

void DiskMultiMap::addDeletedNode(BucketNode node) {
    if (header.numDeletedNodes++ > 0) {
        BucketNode lastNode = nodeAt(header.lastDeletedNode);
        lastNode.nextNode = node.location;
        updateNode(lastNode);
    } else header.firstDeletedNode = node.location;

    header.lastDeletedNode = node.location;
    node.nextNode = LIST_END;
    updateNode(node);
    syncHeader();
}

DiskMultiMap::DiskMultiMapBucket DiskMultiMap::bucketAt(unsigned long index) {
    DiskMultiMapBucket bucket;
    bf.read(bucket, header.hashTableStart + index * sizeof(DiskMultiMapBucket));
    return bucket;
}

DiskMultiMap::BucketNode DiskMultiMap::nodeAt(Location offset) {
    BucketNode node;
    bf.read(node, offset);
    return node;
}

bool DiskMultiMap::updateBucket(DiskMultiMap::DiskMultiMapBucket bucket) { return bf.write(bucket, bucket.location); }
bool DiskMultiMap::updateNode(DiskMultiMap::BucketNode node) { return bf.write(node, node.location); }
bool DiskMultiMap::syncHeader() { return bf.write(header, 0); }

unsigned long DiskMultiMap::hash(int64_t key) const {
    return static_cast<unsigned long>(key % header.numBuckets);
}

////////////////////////////////////////////
// Iterator Class Implementation
////////////////////////////////////////////

DiskMultiMap::Iterator::Iterator() {}
DiskMultiMap::Iterator::Iterator(const std::list<MultiMapTuple>& nodeList) : nodes(nodeList) {}
bool DiskMultiMap::Iterator::isValid() const { return !nodes.empty(); }
DiskMultiMap::Iterator& DiskMultiMap::Iterator::operator++() { 
    if (isValid()) nodes.pop_front(); 
    return *this; 
}
DiskMultiMap::MultiMapTuple DiskMultiMap::Iterator::operator*() { 
    return isValid() ? nodes.front() : MultiMapTuple(); 
}
