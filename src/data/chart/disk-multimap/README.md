# Disk Multi Map

An elegant C++ implementation of a disk-based multi-map hash table, written as a part of an Intro to Computer Science class project. It makes efficient use of space by remembering the locations of deleted entries (also using no additional space). Due to the project requirements, each key, value, or context can be a maximum of 120 characters. The data is stored in a binary file and the iterator supports caching.

The map supports multiple items with the same key, value, and context (hence a multimap). The items are stored in no particular order. Insertion is constant time. Erasure is O(K) where K is the number of nodes matching the key, value, and context. Search is O(K) where K is the number of nodes matching the key, value, and context.

## Include the header
```c++
#include "DiskMultiMap.h"
```

## Create a new file
Create a new `DiskMultiMap`:
```c++
DiskMultiMap map;
map.createNew("filename.dat", 10000); // 10000 is the number of buckets
```

## Open an existing `DiskMultiMap`
Open an existing `DiskMultiMap`:
```c++
DiskMultiMap map;
map.openExisting("filename.dat");
```

## Insert an item
You can insert an item into the map:
```c++
DiskMultiMap map;
map.openExisting("filename.dat");
map.insert("key","value","context"); // key, value, context (additional info)
```

## Erase an item
You can erase entries from the map:
```c++
DiskMultiMap map;
map.openExisting("filename.dat");
map.insert("key","value","context");
map.erase("key","value","context"); // erase all entries matching the given key, value, and context
```

## Search for an item
You can use C++ STL-style iterators to search and iterate through the map efficiently
```c++

void print_all(const std::string& key, DiskMultiMap& map) {
	DiskMultiMap::Iterator it = map.search(key);  // search the map for the key
	if (!it.isValid())
		printf("There were no associations matching %s\n", key);
    
	while (it.isValid()) {  // while there are still matches
		DiskMultiMap::MultiMapTuple tuple = *it;  // get the next association
		printf("On %s, %s was %s\n", tuple.context, tuple.key, tuple.value);
		++it;
	}
}

int main() {
	DiskMultiMap map;
	map.openExisting("filename.dat");
	
	// Santa's list of naughty and nice
	map.insert("Jane","Nice","12/09/2015");
	map.insert("Jane","Nice","12/10/2015");
	map.insert("Jane","Nice","12/11/2015");
	map.insert("Jane","Naughty","12/12/2015");
	map.insert("Jane","Nice","12/13/2015");
	
	map.insert("Rick","Nice","12/09/2015");
	map.insert("Rick","Naughty","12/10/2015");
	map.insert("Rick","Naughty","12/11/2015");
	map.insert("Rick","Naughty","12/12/2015");
	map.insert("Rick","Naughty","12/13/2015");
	
	print_all("Jane", map);
	print_all("Rick", map);
}
```


https://github.com/nkansal96/disk-multi-map/tree/master