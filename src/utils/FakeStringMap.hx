package utils;

/**
 * A highly efficient, cache-friendly map implementation using parallel arrays.
 * Optimized for small datasets (e.g., < 50 elements) where linear search 
 * outperforms the hashing and pointer-chasing overhead of a real Hash Map.
 * thank you qwen!
 */
@:publicFields
@:generic
class FakeStringMap<V> {
    var keys(default, null):Array<String>;
    var values(default, null):Array<V>;

    public function new() {
        keys = [];
        values = [];
    }

    function set(key:String, value:V):V {
        // Cache references to avoid 'this' pointer indirection in the loop
        var k = keys;
        var v = values;
        var len = k.length;
        
        for (i in 0...len) {
            if (k[i] == key) {
                v[i] = value;
                return value;
            }
        }
        
        k.push(key);
        v.push(value);
        return value;
    }

    function get(key:String):Null<V> {
        var k = keys;
        var v = values;
        var len = k.length;
        
        for (i in 0...len) {
            if (k[i] == key) return v[i];
        }
        return null;
    }

    function exists(key:String):Bool {
        var k = keys;
        var len = k.length;
        
        for (i in 0...len) {
            if (k[i] == key) return true;
        }
        return false;
    }

    function remove(key:String):Bool {
        var k = keys;
        var v = values;
        var len = k.length;
        
        for (i in 0...len) {
            if (k[i] == key) {
                // Swap-and-pop: O(1) removal that avoids GC allocation
                var lastIndex = len - 1;
                if (i != lastIndex) {
                    k[i] = k[lastIndex];
                    v[i] = v[lastIndex];
                }
                k.pop();
                v.pop();
                return true;
            }
        }
        return false;
    }

    public inline function clear():Void {
        // GC-free clear for targets like C++/HashLink
        while (keys.length > 0) keys.pop();
        while (values.length > 0) values.pop();
    }

    public inline function iterator():Iterator<V> {
        return values.iterator();
    }

    public inline function keysIterator():Iterator<String> {
        return keys.iterator();
    }
    
    public var length(get, never):Int;
    inline function get_length():Int return keys.length;
}