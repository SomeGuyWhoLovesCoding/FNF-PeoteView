package underlying.rhythm;

import tooling.Stack;
import underlying.rhythm.NoteVB.VirtualNote;
import underlying.rhythm.NoteVB.VirtualSustain;

/**
	The pool of the note system.
	I'm proud of this class, it is the most efficient way to handle notes and sustains when working with peote-view.
	It uses sparse arrays indexed by global note index for O(1) lookup of active notes and sustains.
	Inactive objects are stored in free lists for efficient object reuse.
	When a note or sustain is needed, it checks if it is already allocated at that index. If not, it pops from the inactive list or creates a new one.
	When a note or sustain is no longer needed, it is reset and pushed to its respective inactive list.
	This approach eliminates constant object allocation/destruction, providing a significant performance boost.
	It also allows for direct access to notes and sustains by their global note index.
	This is a very important class for the note system, and it is used in the NoteSystem class to manage all active and pooled notes/sustains.

	v3.9.0: the peote ELEMENT half of this pool is now a PARKED, GROW-ONLY
	stack — elements are created once, enter the GPU buffer once, and are
	never removed in steady state; despawned elements are parked (scale 0,
	alpha 0) instead of removeElement'd. The VirtualNote/VirtualSustain
	binding half (slots + free stacks) is unchanged.
	@since Development
**/
@:publicFields
class NotePool {
	var inactiveVirtualNotes(default, null):Stack<VirtualNote>;
	var inactiveVirtualSusses(default, null):Stack<VirtualSustain>;

	// Sparse slots indexed by global note index — the VirtualNote /
	// VirtualSustain currently bound to each chart note (null = inactive).
	// While a note stays visible, drawNote() rebinds the SAME object every
	// frame (zero steady-state allocation); on despawn putNote/putSustain
	// push the object back onto the free stacks for other notes to reuse.
	var virtualNoteSlots:Array<VirtualNote>;
	var virtualSustainSlots:Array<VirtualSustain>;

	// Peote element pools — these persist in the GPU buffer and are
	// updated in-place each frame instead of being destroyed/recreated.
	// v3.9.0: the stack is now PARKED, not recycled. Elements are created
	// ONCE (the first time the stack grows past them) and their buffer
	// membership NEVER changes afterwards: acquire just walks up the stack,
	// endFrame PARKS the surplus (scale 0 / alpha 0 — one properties write,
	// flushed by the same notesBuf.update() the frame already does).
	// No removeElement ever runs in steady state, so the buffer's internal
	// element array is never re-packed — the churn (add/remove/re-add per
	// spawn/despawn) was the residual memory creep's home turf. The stack
	// only ever grows; a frame is just "how deep the renderer walked".
	var pooledNotes(default, null):Stack<Note>;
	var pooledSustains(default, null):Stack<Sustain>;

	// The element stack: entry i is the i-th note element ever created.
	// Only grows; entries are never removed or reordered.
	var parkedNotes(default, null):Array<Note>;
	var parkedSustains(default, null):Array<Sustain>;

	// =================================================================
	//  WINDOW NOTE CACHE  (v3.9.1 — the 2.35M-note-chart memory fix;
	//  v3.9.2 — pooled, allocation-free, null-safe on every target)
	// =================================================================
	// File.getNote() CONSTRUCTS a fresh MetaNote object per call (the
	// FFI cannot return store references) and re-fetches the whole
	// window per frame: ~4,189 fresh objects/frame on a 2.36M-note
	// chart — 226M+ allocations per playthrough. The cache below cuts
	// that to O(window churn) and — v3.9.2 — to ZERO steady-state
	// allocations: pooled MetaNotes are re-SET in place (File.fetchNote
	// + MetaNoteImpl.set) instead of being constructed, and the pool
	// recycles them exactly like the VirtualNote slot objects.
	//
	// Axis is WINDOW-RELATIVE (globalIndex - windowBase), re-based as
	// `bottom` advances, so the array stays window-sized for the whole
	// playthrough (~5,700 entries on the worst chart measured — never
	// the 2.36M-entry global-axis array v3.9.0 grew).
	//
	// Invalidation rides the v3.8.7 discipline: every chart mutation
	// funnels through onChartMutated → recycleWindowRange → the same
	// strip stripped here (stripWindowNotes); reset()/dispose() drop
	// the cache with the window.
	//
	// v3.9.2 hardening: the array is initialized in the constructor and
	// fetchNote/prime test it for null FIRST — on hxcpp, a field without
	// an initializer is null until assigned, so the ctor init is what
	// fixes the frame-one "Null Object Reference" (StateMachine.safe
	// traps gameplay update, but the throw originated here).
	var windowNotes:Array<MetaNote>;
	var windowBase:Int64 = -1; // global index of windowNotes[0]
	var windowCount:Int = 0;   // live entries in windowNotes

	// The MetaNote free pool: pooled objects carry the cached window
	// notes. A pooled object handed out at window entry is RE-SET to the
	// entering note's fields; the pool takes it back when the cache
	// advances/passes it (advanceWindowTo), strips it (edits), or drops
	// wholesale (reset). Steady-state gameplay cycles the same window-
	// sized set of objects forever.
	var windowNotePool:Stack<MetaNote>;

	// Frame-sync cursor: this frame's walk depth into the stacks above.
	var noteSlot:Int = 0;
	var sustainSlot:Int = 0;

	var parent(default, null):NoteSystem;

	/**
	 * Initializes the NotePool with parent reference and empty arrays.
	 * @param parent The NoteSystem instance that owns this pool.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;
		inactiveVirtualNotes = new Stack<VirtualNote>();
		inactiveVirtualSusses = new Stack<VirtualSustain>();
		virtualNoteSlots = [];
		virtualSustainSlots = [];
		pooledNotes = new Stack<Note>();
		pooledSustains = new Stack<Sustain>();
		parkedNotes = [];
		parkedSustains = [];
		// v3.9.2: BOTH halves of the window cache are constructor-
		// initialized — hxcpp leaves a field without an initializer null
		// until assigned, and the first fetchNote guard reads
		// windowNotes.length (the frame-one Null Object Reference).
		windowNotes = [];
		windowNotePool = new Stack<MetaNote>();
	}

	/**
	 * Gets or creates a VirtualNote for the given index.
	 * Reuses inactive notes from the pool if available, otherwise creates a new one.
	 * @param id The note sprite ID (unused in current implementation).
	 * @param n The underlying meta note to reference.
	 * @param index The global note index for array access.
	 * @return The allocated VirtualNote at the given index.
	 */
	function getNote(id:Int, n:MetaNote, index:Int64):VirtualNote {
		var slot = Int64.toInt(index);

		// Fast path: this global index was drawn last frame and is still
		// visible — reuse the same object in place. Zero allocation.
		var obj:VirtualNote = null;
		if (slot < virtualNoteSlots.length)
			obj = virtualNoteSlots[slot];

		if (obj == null) {
			obj = inactiveVirtualNotes.pop();
			if (obj == null)
				obj = new VirtualNote(0, 0, 0);
			if (slot >= virtualNoteSlots.length)
				virtualNoteSlots.resize(slot + 1);
			virtualNoteSlots[slot] = obj;
		}

		obj.initialAlpha = Note.defaultAlpha;
		obj.addedAlpha = 0;
		obj.notesInOne = 1;
		obj.ref = n;
		return obj;
	}

	/**
	 * Gets or creates a VirtualSustain for the given index.
	 * Reuses inactive sustains from the pool if available, otherwise creates a new one.
	 * @param id The sustain sprite ID (unused in current implementation).
	 * @param n The underlying meta note to reference.
	 * @param index The global note index for array access.
	 * @return The allocated VirtualSustain at the given index.
	 */
	function getSustain(id:Int, n:MetaNote, index:Int64):VirtualSustain {
		var slot = Int64.toInt(index);

		var obj:VirtualSustain = null;
		if (slot < virtualSustainSlots.length)
			obj = virtualSustainSlots[slot];

		if (obj == null) {
			obj = inactiveVirtualSusses.pop();
			if (obj == null)
				obj = new VirtualSustain(-9999, -9999, 0, 0);
			if (slot >= virtualSustainSlots.length)
				virtualSustainSlots.resize(slot + 1);
			virtualSustainSlots[slot] = obj;
		}

		obj.alpha = Sustain.defaultAlpha;
		return obj;
	}

	/**
	 * Deactivates a note and returns it to the inactive pool.
	 * Resets all visual properties and clears note flags in the file system.
	 * @param n The underlying meta note to deactivate.
	 * @param index The global note index.
	 */
	function putNote(n:MetaNote, index:Int64) {
		recycleNoteAt(index);
	}

	/**
	 * Recycles the VirtualNote binding at a global index — the shared body
	 * of putNote and the light-reset edge recycler. Returns the binding to
	 * the free stack and clears its slot WITHOUT touching any GPU state;
	 * the next getNote at this index rebinds a slot in place (or pops from
	 * the stack this just fed).
	 */
	function recycleNoteAt(index:Int64) {
		var slot = Int64.toInt(index);
		if (slot < virtualNoteSlots.length) {
			var obj = virtualNoteSlots[slot];
			if (obj != null) {
				obj.ref = null; // drop the MetaNote ref early
				inactiveVirtualNotes.push(obj);
				virtualNoteSlots[slot] = null;
			}
		}
	}

	/**
	 * Deactivates a sustain and returns it to the inactive pool.
	 * Resets all visual properties and alpha.
	 * @param n The underlying meta note to deactivate.
	 * @param index The global note index.
	 */
	function putSustain(n:MetaNote, index:Int64) {
		recycleSustainAt(index);
	}

	/**
	 * Recycles the VirtualSustain binding at a global index — the shared
	 * body of putSustain and the light-reset edge recycler.
	 */
	function recycleSustainAt(index:Int64) {
		var slot = Int64.toInt(index);
		if (slot < virtualSustainSlots.length) {
			var obj = virtualSustainSlots[slot];
			if (obj != null) {
				obj.ref = null; // drop the VirtualNote ref early
				inactiveVirtualSusses.push(obj);
				virtualSustainSlots[slot] = null;
			}
		}
	}

	/**
	 * LIGHT-RESET WINDOW RECYCLE (v3.8.7 — the memory leak fix).
	 *
	 * The light chart-mutation path (NoteSystem.onChartMutated →
	 * resetNotes(lightReset)) re-derives the window by binary search —
	 * O(log n) — instead of walking the cull loops. The cull loops'
	 * putNote/putSustain recycle a slot binding the moment it leaves the
	 * window; a BINARY SEARCH never walks those indexes — and a
	 * structural edit INSIDE the window (insert/remove between bottom
	 * and top) doesn't even move the edges: every in-window global index
	 * above the edit point shifts by ±1 while its binding stays parked
	 * in the old slot. Parked bindings are the leak:
	 *
	 *   1. their free-stack entries never return — the pool compensates
	 *      by allocating a fresh VirtualNote/VirtualSustain on the next
	 *      rebind, so the object count grows toward "one per slot key
	 *      ever touched" over an editing session instead of staying
	 *      window-sized (the regression v3.8.6's lightReset introduced);
	 *   2. worse, a parked binding's ref keeps rooting a MetaNote the
	 *      edit may have ERASED (remove/undo) — a stale pointer that
	 *      survives until its slot key is re-bound by pure luck.
	 *
	 * This recycles the ENTIRE old window strip [lo, hi) — both edges
	 * and every in-between slot a structural edit may have shifted.
	 * Cost: O(window size), a few dozen pushes — never O(chart length),
	 * and no GPU buffer is touched. The next frame's processNotes
	 * rebinds the current window entirely from the free stack: zero
	 * allocations, every ref freshly bound to the note now living at
	 * that global index. This is exactly what the old notePool.reset()
	 * guaranteed (free stacks rebuilt from ALL slots), minus the
	 * notesBuf clear / receptor re-add / full re-upload.
	 *
	 * @param lo old window bottom
	 * @param hi old window top
	 */
	function recycleWindowRange(lo:Int64, hi:Int64) {
		var i = Int64.toInt(lo);
		var end = Int64.toInt(hi);
		while (i < end) {
			recycleNoteAt(i);
			recycleSustainAt(i);
			i++;
		}
		// The window-note cache rides the same strip: the edit may have
		// erased or shifted exactly these indexes. (The light reset runs
		// this BEFORE the window edges move, so lo/hi are the OLD window
		// — the strip the bindings were recycled for, which is exactly
		// the strip the cache holds stale entries for.)
		stripWindowNotes(lo, hi);
	}


	// =================================================================
	//  WINDOW NOTE CACHE  (v3.9.1 / v3.9.2)
	// =================================================================

	/**
	 * Serves the MetaNote for an in-window global index with ZERO
	 * allocation: windowNotes[i - windowBase] when primed; when the
	 * entry is missing (a note the window just touched), the miss is
	 * filled from the MetaNote free pool — a pooled object RE-SET to
	 * the note's packed fields in place (File.fetchNote) — and only
	 * a fully-drained pool constructs one fresh object. Steady state
	 * (a full window turn-over) recycles the same window-sized set of
	 * pooled MetaNotes forever; nothing in the note read path
	 * allocates.
	 *
	 * Null-safe first (hxcpp: the ctor initializes, dispose() nulls —
	 * and the trap exists for a reason).
	 */
	inline function fetchNote(index:Int64):MetaNote {
		if (windowNotes == null)
			return File.getNote(index);
		var i = Int64.toInt(index - windowBase);
		// Test the ENTRY, not a live-count bound: stripped strips leave
		// holes inside the cached span.
		if (i >= 0 && i < windowNotes.length && windowNotes[i] != null)
			return windowNotes[i];
		var n = primeWindowNote(index);
		return n;
	}

	/**
	 * Fetch a pooled MetaNote for `index` and place it in the cache.
	 * Pooled objects are re-SET in place (File.fetchNote) — the only
	 * allocation is the pool's cold-start growth, exactly like the
	 * VirtualNote free stack's.
	 */
	function primeWindowNote(index:Int64):MetaNote {
		if (windowBase < 0)
			windowBase = index;
		if (windowNotes == null)
			windowNotes = [];
		var i = Int64.toInt(index - windowBase);
		if (i < 0) {
			// Below the cached span (a backward walk that outran the
			// re-base, or a read before the first advance): served
			// UNPOOLED by a plain getNote — one object, never cached,
			// garbage the moment its caller lets it go. v3.9.2: the
			// NoteSpawner gates the backward probes on movingBackward
			// and cullBottom advances the base at the despawn edge, so
			// this arm only carries per-seek reads, not per-frame ones.
			return File.getNote(index);
		}
		var n = windowNotePool.pop();
		if (n == null)
			n = new MetaNote.MetaNoteImpl(0, 0); // cold start only
		File.fetchNote(index, n);
		while (windowNotes.length < i + 1)
			windowNotes.push(null);
		if (windowNotes[i] == null)
			windowCount++;
		windowNotes[i] = n;
		return n;
	}

	/**
	 * THE CACHE'S MEMORY DISCIPLINE — called from cullBottom's despawn
	 * pass, right where the window's leading edge advances. Drops the
	 * entries below the new bottom (they can never be fetched again:
	 * every hot walk is anchored inside [bottom, top)) and re-bases the
	 * array so its LENGTH stays window-sized: entries shift down in
	 * place (a fixed-distance move, no reallocation, GC-visible only
	 * as the array's length shrinking — never as growth).
	 *
	 * v3.9.2: every dropped POOLED MetaNote returns to the free pool —
	 * the object survives for the next entering note, re-set in place.
	 * Steady state cycles the same window-sized object set forever:
	 * zero allocation, zero garbage, on any target.
	 *
	 * On the measured chart the array holds ~5,700 entries for the
	 * whole 901 seconds instead of growing to 2,359,436.
	 */
	function advanceWindowTo(newBottom:Int64) {
		if (windowBase < 0) {
			windowBase = newBottom;
			return;
		}
		var drop = Int64.toInt(newBottom - windowBase);
		if (drop == 0)
			return;
		if (drop < 0) {
			// BACKWARD window (a seek that walked bottom DOWN): the cache
			// must EXTEND ITS FRONT to cover the indexes below the old
			// base, or every fetch below the base would miss (and its
			// priming would be silently discarded by primeWindowNote).
			// Prepend the new span: the holes fill on the next fetch.
			var grow = -drop;
			var oldLen = windowNotes.length;
			windowNotes.resize(oldLen + grow);
			for (k in 0...oldLen)
				windowNotes[oldLen + grow - 1 - k] = windowNotes[oldLen - 1 - k];
			for (k in 0...grow)
				windowNotes[k] = null;
			windowBase = newBottom;
			// windowCount unchanged: only nulls were prepended
			return;
		}
		if (drop >= windowNotes.length) {
			// The whole cached span fell out at once — return EVERY pooled
			// object to the free pool, then empty the array.
			for (k in 0...windowNotes.length)
				if (windowNotes[k] != null)
					windowNotePool.push(windowNotes[k]);
			windowNotes.resize(0);
			windowCount = 0;
			windowBase = newBottom;
			return;
		}
		// in-place shift: [drop...length) -> [0...length-drop). The
		// dropped head objects return to the free pool first.
		for (k in 0...drop)
			if (windowNotes[k] != null) {
				windowNotePool.push(windowNotes[k]);
				windowCount--;
			}
		var keep = windowNotes.length - drop;
		for (k in 0...keep)
			windowNotes[k] = windowNotes[k + drop];
		windowNotes.resize(keep);
		windowBase = newBottom;
	}

	/**
	 * Invalidate a strip of cached MetaNotes (the light-reset edge
	 * recycle path — mirror/shift rewrote fields in place, structural
	 * edits erased notes). v3.9.2: the pooled objects return to the
	 * free pool (an edit did not free the OBJECT, only this note's
	 // claim on it); the next fetchNote re-primes and re-sets one.
	 */
	function stripWindowNotes(lo:Int64, hi:Int64) {
		if (windowBase < 0 || windowNotes == null)
			return;
		var a = Int64.toInt(lo - windowBase);
		var b = Int64.toInt(hi - windowBase);
		if (a < 0)
			a = 0;
		if (b > windowNotes.length)
			b = windowNotes.length;
		for (k in a...b)
			if (windowNotes[k] != null) {
				windowNotePool.push(windowNotes[k]);
				windowNotes[k] = null;
				windowCount--;
			}
	}


	// =================================================================
	//  Peote Note / Sustain element pool  (v3.9.0: parked, grow-only)
	// =================================================================

	/**
	 * Called at the start of each render frame.
	 * Resets the acquire cursor so the walk restarts from the stack's
	 * bottom (slot 0). The stack itself is untouched — its entries and
	 * their buffer memberships are permanent.
	 */
	inline function beginFrame() {
		noteSlot = 0;
		sustainSlot = 0;
	}

	/**
	 * Acquire the pooled Note for this frame's walk position. The element
	 * was created ONCE (the first time the stack grew to it), is already
	 * inside `notesBuf`, and will stay there forever — set its properties
	 * and the frame's notesBuf.update() flushes them. Growing the stack
	 * (a busier frame than any before it) is the only allocating case, and
	 * it only ever grows.
	 */
	function acquireNote():Note {
		if (noteSlot < parkedNotes.length)
			return parkedNotes[noteSlot++];
		var note = pooledNotes.pop();
		if (note == null)
			note = new Note(0, 0, 0, 0, NoteSystem.typeToHandle[0]);
		NoteSystem.notesBuf.addElement(note);
		parkedNotes.push(note);
		noteSlot = parkedNotes.length;
		return note;
	}

	/**
	 * Acquire the pooled Sustain for this frame's walk position. Same
	 * contract as `acquireNote`, for `sustainsBuf`.
	 */
	function acquireSustain():Sustain {
		if (sustainSlot < parkedSustains.length)
			return parkedSustains[sustainSlot++];
		var sustain = pooledSustains.pop();
		if (sustain == null)
			sustain = new Sustain(-9999, -9999, 0, 0, NoteSystem.typeToHandle[0], 0, 1, 1, 0);
		NoteSystem.sustainsBuf.addElement(sustain);
		parkedSustains.push(sustain);
		sustainSlot = parkedSustains.length;
		return sustain;
	}

	/**
	 * Called at the end of each render frame: every element ABOVE this
	 * frame's high-water mark is PARKED — scale 0, alpha 0 (initial and
	 * added) — one properties write each, flushed to the GPU by the same
	 * notesBuf.update() the frame already performs. Nothing is removed
	 * from the buffer, nothing is pushed to a free stack, and the
	 * buffer's element array is never re-packed: a parked element is a
	 * fully in-buffer, zero-sized sprite that costs one property slot.
	 *
	 * The `prevNoteCount` high-water bookkeeping of the old pool is
	 * dropped entirely — the stack's own length IS the capacity, and
	 * the next beginFrame() starts the walk from the bottom again.
	 */
	function endFrame() {
		var i = noteSlot;
		var n = parkedNotes.length;
		while (i < n) {
			var note = parkedNotes[i];
			note.scale = 0;
			note.initialAlpha = 0;
			note.addedAlpha = 0;
			i++;
		}

		i = sustainSlot;
		n = parkedSustains.length;
		while (i < n) {
			var sustain = parkedSustains[i];
			sustain.scale = 0;
			sustain.c.aF = 0;
			sustain.c.luminanceF = 0;
			i++;
		}
	}

	/**
	 * Cleans up all pool arrays and references for garbage collection.
	 * Does NOT individually removeElement — the caller is expected to
	 * `notesBuf.clear()` / `sustainsBuf.clear()` afterwards.
	 */
	function dispose() {
		parkedNotes = null;
		parkedSustains = null;
		pooledNotes = null;
		pooledSustains = null;
		inactiveVirtualNotes = null;
		inactiveVirtualSusses = null;
		virtualNoteSlots = null;
		virtualSustainSlots = null;
		windowNotes = null;
		windowNotePool = null;
		windowBase = -1;
		windowCount = 0;
	}

	/**
	 * Resets the element stack for a song-position jump: the buffers are
	 * cleared (the elements' memberships die with the buffer, not one by
	 * one), receptors are re-added as the only persistent elements, and
	 * the whole stack is rebuilt onto the free stacks so the next frame's
	 * walk grows it back element-by-element — exactly once each, fresh
	 * `addElement` per element, never a duplicate.
	 *
	 * The VirtualNote/VirtualSustain binding half resets exactly as
	 * before (free stacks rebuilt from the slot arrays so recycled
	 * virtual objects survive the jump instead of being orphaned).
	 */
	function reset() {
		// Clear buffers and re-add receptors (the only persistent elements)
		NoteSystem.notesBuf.clear();
		for (strumline in parent.strumlines) {
			for (receptor in strumline.receptors) {
				NoteSystem.notesBuf.addElement(receptor.note);
			}
		}
		NoteSystem.sustainsBuf.clear();

		// The parked stack dies with the buffer (its memberships were
		// per-buffer, and notesBuf.clear() just destroyed them all) —
		// hand every element back to the free stack so the next frame
		// re-creates the buffer memberships ONE at a time. No element is
		// ever addElement'd twice: the stack arrays are dropped.
		for (note in parkedNotes) {
			pooledNotes.push(note);
		}
		for (sustain in parkedSustains) {
			pooledSustains.push(sustain);
		}
		parkedNotes.resize(0);
		parkedSustains.resize(0);
		noteSlot = 0;
		sustainSlot = 0;

		// Rebuild the free stacks from the slot arrays so recycled
		// virtual objects survive the jump instead of being orphaned.
		inactiveVirtualNotes = new Stack<VirtualNote>();
		for (obj in virtualNoteSlots)
			if (obj != null)
				inactiveVirtualNotes.push(obj);
		virtualNoteSlots.resize(0);

		inactiveVirtualSusses = new Stack<VirtualSustain>();
		for (obj in virtualSustainSlots)
			if (obj != null)
				inactiveVirtualSusses.push(obj);
		virtualSustainSlots.resize(0);

		// The window-note cache dies with the window it described: a
		// jump re-derives [bottom, top) from scratch, and every cached
		// MetaNote ref was anchored to the OLD window's indexes. The
		// POOLED objects survive on the free pool (exactly like the
		// recycled VirtualNote objects above) — the new window forms
		// by re-SETTING them in place, zero allocations once the pool
		// has ever reached window size.
		if (windowNotes != null)
			for (k in 0...windowNotes.length)
				if (windowNotes[k] != null)
					windowNotePool.push(windowNotes[k]);
		windowNotes.resize(0);
		windowBase = -1;
		windowCount = 0;
	}
}
