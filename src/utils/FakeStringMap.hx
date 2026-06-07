package utils;

/**
 * A highly efficient, cache-friendly map implementation using parallel arrays.
 * Optimized for small datasets (e.g., < 50 elements) where linear search 
 * outperforms the hashing and pointer-chasing overhead of a real Hash Map.
 * 
 * Note: Changed generic parameters to <V> since the keys are strictly Strings.
 * thank you qwen!
 */
@:publicFields
@:generic
@:final
class FakeStringMap<V> {
    // Kept private to prevent external modification of the internal arrays
    var keys(default, null):Array<String>;
    var values(default, null):Array<V>;

    function new() {
        keys = [];
        values = [];
    }

    inline function set(key:String, value:V):V {
        var idx = keys.indexOf(key);
        if (idx == -1) {
            keys.push(key);
            values.push(value);
        } else {
            values[idx] = value;
        }
        return value;
    }

    inline function get(key:String):Null<V> {
        var idx = keys.indexOf(key);
        return idx != -1 ? values[idx] : null;
    }

    inline function exists(key:String):Bool {
        return keys.indexOf(key) != -1;
    }

    inline function remove(key:String):Bool {
        var idx = keys.indexOf(key);
        if (idx != -1) {
            // Swap-and-pop: O(1) removal that avoids the GC allocation of Array.splice()
            var lastIndex = keys.length - 1;
            if (idx != lastIndex) {
                keys[idx] = keys[lastIndex];
                values[idx] = values[lastIndex];
            }
            keys.pop();
            values.pop();
            return true;
        }
        return false;
    }

    inline function clear():Void {
        // GC-free clear for targets like C++/HashLink
        while (keys.length > 0) keys.pop();
        while (values.length > 0) values.pop();
    }

    inline function iterator():Iterator<V> {
        return values.iterator();
    }

    inline function keysIterator():Iterator<String> {
        return keys.iterator();
    }

    /*function initFromStringMap(map:Map<String, V>):Void {
        for (key in map.keys()) {
            set(key, map.get(key));
        }
    }*/
    
    var length(get, never):Int;
    inline function get_length():Int return keys.length;
}