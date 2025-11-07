package structures.gameplay;

@:publicFields
class NotePool {
    public var startIndex:Int64 = 0; // chart index of the first element in the ring
    private var capacity:Int;
    
    private var virtualNotes:Array<VirtualNote>;
    private var virtualSustains:Array<VirtualSustain>;
    
    private var inactiveVirtualNotes:Array<VirtualNote>;
    private var inactiveVirtualSustains:Array<VirtualSustain>;
    
    public var parent(default, null):NoteSystem;
    
    private static inline var INITIAL_CAPACITY = 256;
    
    public function new(parent:NoteSystem) {
        this.parent = parent;
        capacity = INITIAL_CAPACITY;
        
        virtualNotes = [];
        virtualSustains = [];
        inactiveVirtualNotes = [];
        inactiveVirtualSustains = [];
        
        for (i in 0...capacity) {
            virtualNotes.push(null);
            virtualSustains.push(null);
        }
    }
    
    private function ensureCapacity(requiredSize:Int) {
        if (requiredSize <= capacity) return;
        var newCap = capacity;
        while (newCap < requiredSize) newCap *= 2;
        
        for (i in capacity...newCap) {
            virtualNotes.push(null);
            virtualSustains.push(null);
        }
        capacity = newCap;
    }
    
    /**
     * Slide the ring buffer to a new window start index.
     * Automatically reclaims old notes and sustains outside the window.
     */
    public function advanceRing(newStart:Int64) {
        var shift = Int64.toInt(newStart - startIndex);
        if (shift <= 0) return; // seeking backwards handled by lazy overwrite
        
        var used = shift;
		if (used >= virtualNotes.length) used = virtualNotes.length;
        for (i in 0...used) {
            var idx = (i) % capacity;
            var n = virtualNotes[idx];
            if (n != null) inactiveVirtualNotes.push(n);
            virtualNotes[idx] = null;
            
            var s = virtualSustains[idx];
            if (s != null) inactiveVirtualSustains.push(s);
            virtualSustains[idx] = null;
        }
        startIndex = newStart;
    }
    
    /**
     * Returns the VirtualNote corresponding to a chart index.
     * Automatically slides the ring if index is outside the current window.
     */
    public function getNote(index:Int64, note:MetaNote):VirtualNote {
        if (index < startIndex) {
            // backward seek: overwrite from startIndex
            startIndex = index;
        } else {
            // forward seek: slide ring automatically
            advanceRing(index - capacity + 1);
        }
        
        ensureCapacity(Int64.toInt(index - startIndex + 1));
        var offset = Int64.toInt(index - startIndex) % capacity;
        
        var allocated = virtualNotes[offset];
        if (allocated == null) {
            allocated = inactiveVirtualNotes.pop();
            if (allocated == null) allocated = new VirtualNote(-9999, -9999, 0, 0);
            
            allocated.addedAlpha = 0;
            allocated.notesInOne = 1;
            allocated.greedyMergeAlphaMultiplier = 0;
            allocated.greedyMergeType = 0;
            
            virtualNotes[offset] = allocated;
        }
        
        allocated.ref = note;
        allocated.initialAlpha = Note.defaultAlpha;
        return allocated;
    }
    
    /**
     * Returns the VirtualSustain corresponding to a chart index.
     */
    public function getSustain(index:Int64, note:MetaNote):VirtualSustain {
        if (index < startIndex) startIndex = index;
        else advanceRing(index - capacity + 1);
        
        ensureCapacity(Int64.toInt(index - startIndex + 1));
        var offset = Int64.toInt(index - startIndex) % capacity;
        
        var allocated = virtualSustains[offset];
        if (allocated == null) {
            var tex = TextureSystem.getTexture("sustainTex");
            allocated = inactiveVirtualSustains.pop();
            if (allocated == null) {
                allocated = new VirtualSustain(-9999, -9999,
                    Math.floor(tex.width / tex.tilesX),
                    Math.floor(tex.height / tex.tilesY)
                );
                allocated.alpha = Sustain.defaultAlpha;
            }
            virtualSustains[offset] = allocated;
        }
        
        return allocated;
    }
    
    /**
     * Return a note to the inactive pool.
     */
    public function putNote(index:Int64) {
        var offset = Int64.toInt(index - startIndex) % capacity;
        var n = virtualNotes[offset];
        if (n != null) {
            n.x = n.y = -9999;
            inactiveVirtualNotes.push(n);
            virtualNotes[offset] = null;
        }
    }
    
    /**
     * Return a sustain to the inactive pool.
     */
    public function putSustain(index:Int64) {
        var offset = Int64.toInt(index - startIndex) % capacity;
        var s = virtualSustains[offset];
        if (s != null) {
            s.x = s.y = -9999;
            s.alpha = Sustain.defaultAlpha;
            inactiveVirtualSustains.push(s);
            virtualSustains[offset] = null;
        }
    }
    
    public function dispose() {
        virtualNotes = null;
        virtualSustains = null;
        inactiveVirtualNotes = null;
        inactiveVirtualSustains = null;
    }
}
