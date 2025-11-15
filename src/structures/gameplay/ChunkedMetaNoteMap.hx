package structures.gameplay;

@:publicFields
class ChunkedMetaNoteMap<T> {
    public var chunkSize:Int;
    private var chunks:Array<Array<T>>;

    public function new(chunkSize:Int = 1024) {
        this.chunkSize = chunkSize;
        this.chunks = [];
    }

    /** Returns the value at key, or null if not set */
    public function get(key:MetaNote):T {
        var idx = key.index;
        var chunkIndex = idx / chunkSize;
        var offset = idx % chunkSize;

        if (chunkIndex >= chunks.length) return null;
        var chunk = chunks[chunkIndex];
        if (chunk == null) return null;
        return chunk[offset];
    }

    /** Sets the value at key */
    public function set(key:MetaNote, value:T):Void {
        var idx = key.index;
        var chunkIndex = idx / chunkSize;
        var offset = idx % chunkSize;

        while (chunkIndex >= chunks.length) {
            chunks.push(null);
        }

        var chunk = chunks[chunkIndex];
        if (chunk == null) {
            chunk = [];
            for (i in 0...chunkSize) chunk.push(null);
            chunks[chunkIndex] = chunk;
        }

        chunk[offset] = value;
    }

    /** Removes the value at key */
    public function remove(key:MetaNote):Bool {
        var idx = key.index;
        var chunkIndex = idx / chunkSize;
        var offset = idx % chunkSize;

        if (chunkIndex >= chunks.length) return false;
        var chunk = chunks[chunkIndex];
        if (chunk == null || chunk[offset] == null) return false;

        chunk[offset] = null;
        return true;
    }

    /** Clears the entire map */
    public function clear():Void {
        for (chunk in chunks) if (chunk != null) for (i in 0...chunk.length) chunk[i] = null;
        chunks = [];
    }
}