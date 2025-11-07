package structures.gameplay;

@:publicFields
class NoteCache {
    public var startIndex:Int64 = 0; // chart index of first note in the cache
    public var notes:Array<MetaNote>;
    public var capacity:Int;
    private static inline var INITIAL_CAPACITY = 512;

    public function new() {
        capacity = INITIAL_CAPACITY;
        notes = new Array<MetaNote>();
    }

    /**
     * Ensure the cache can hold the note at `index`.
     * Grows the internal array if necessary.
     */
    public function ensureCapacity(index:Int64):Void {
        var endIndex = startIndex + notes.length;
        if (index < startIndex) {
            // Seeking backwards: shift the ring backwards
            var shift = startIndex - index;
            for (i in 0...shift) notes.unshift(null);
            startIndex = index;
        } else if (index >= endIndex) {
            // Seeking forward: grow the ring
            while (index >= startIndex + notes.length) notes.push(null);
        }
    }

    /**
     * Get the cached MetaNote at chart index `index`.
     * Will read from disk if not already cached.
     */
    public function get(index:Int64):MetaNote {
        ensureCapacity(index);
        var offset = Int64.toInt(index - startIndex);
        var note = notes[offset];
        if (note == null) {
            note = File.getNote(index);
            notes[offset] = note;
        }
        return note;
    }

    /**
     * Reset cache window (e.g., on song seek) to contain notes around a new start index.
     */
    public function reset(start:Int64, window:Int64):Void {
        startIndex = start;
        notes = [];
        for (i in 0...window) {
            var idx = start + i;
            if (idx >= File.getLength()) break;
            notes.push(File.getNote(idx));
        }
    }

    /**
     * Optional: discard notes below `newStart` to free memory.
     */
    public function advanceRing(newStart:Int64):Void {
        var shift = Int64.toInt(newStart - startIndex);
        if (shift <= 0) return;
        notes.splice(0, shift);
        startIndex = newStart;
    }
}
