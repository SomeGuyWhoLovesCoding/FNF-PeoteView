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

	// F7: global chart index of slot 0. The slot arrays used to be indexed
	// by raw global index and only ever GROW — scrolling a long chart end
	// to end left one (null) entry per chart note even though the live
	// window is a few hundred. compactSlots() (called by the spawner once
	// the dead prefix below the window passes a threshold) shifts the live
	// window down to base 0 and raises slotBase; rebaseUp() restores
	// headroom when a backward scroll walks below the base. Every slot
	// access converts global index -> local slot through slotBase.
	var slotBase:Int = 0;

	// Peote element pools — these persist in the GPU buffer and are
	// updated in-place each frame instead of being destroyed/recreated.
	var pooledNotes(default, null):Stack<Note>;
	var pooledSustains(default, null):Stack<Sustain>;

	// Active peote elements currently residing in the GPU buffers.
	// Index 0 is the oldest slot; new slots are appended at the end.
	var activeNotes(default, null):Array<Note>;
	var activeSustains(default, null):Array<Sustain>;

	// Frame-sync counters: how many slots were used last frame vs. this frame.
	var noteSlot:Int = 0;
	var sustainSlot:Int = 0;
	var prevNoteCount:Int = 0;
	var prevSustainCount:Int = 0;

	// F1: true between beginFrame() and endFrame(). endFrame() must run
	// exactly once per beginFrame() EVEN IF a render loop threw midway —
	// renderNotes() wraps the loops in try/catch and calls endFrame() in
	// its "finally" path; this flag is the safety net that makes a missed
	// bracket (or a future caller) self-heal instead of permanently
	// desyncing the counters (the "element leak forever after" bug).
	var frameOpen:Bool = false;

	// F8: set by acquireNote/acquireSustain and by the render loops'
	// element writes. Cleared in endFrame(). When false at flush time,
	// renderNotes() skips the blanket notesBuf.update() / sustainsBuf.update()
	// re-upload (peote's update() rewrites the byte range of ALL contained
	// elements from offset 0 — not a dirty upload — so skipping it when
	// nothing moved is a full-buffer SubData saved per frame).
	var notesDirty:Bool = false;
	var sustainsDirty:Bool = false;

	// F9: bumped every time an active element is released, so holders of
	// pooled sprites (Receptor.noteToHit_sprite) can detect that the sprite
	// they cached was recycled to the free stack and re-acquired by an
	// unrelated note. The sprite object may be the same — the generation
	// is what proves it still belongs to the same acquire.
	var noteGeneration:Int = 0;

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
		activeNotes = [];
		activeSustains = [];
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
		// F7: a backward scroll can walk the window below slotBase —
		// grow headroom so the local index is never negative.
		if (slot < slotBase)
			rebaseUp(slot);
		var local = slot - slotBase;

		// Fast path: this global index was drawn last frame and is still
		// visible — reuse the same object in place. Zero allocation.
		var obj:VirtualNote = null;
		if (local < virtualNoteSlots.length)
			obj = virtualNoteSlots[local];

		if (obj == null) {
			obj = inactiveVirtualNotes.pop();
			if (obj == null)
				obj = new VirtualNote(0, 0, 0);
			obj.onFreeStack = false; // F2: leaving the stack
			if (local >= virtualNoteSlots.length)
				virtualNoteSlots.resize(local + 1);
			virtualNoteSlots[local] = obj;
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
		if (slot < slotBase)
			rebaseUp(slot); // F7: same headroom rule as getNote
		var local = slot - slotBase;

		var obj:VirtualSustain = null;
		if (local < virtualSustainSlots.length)
			obj = virtualSustainSlots[local];

		if (obj == null) {
			obj = inactiveVirtualSusses.pop();
			if (obj == null)
				obj = new VirtualSustain(-9999, -9999, 0, 0);
			obj.onFreeStack = false; // F2: leaving the stack
			if (local >= virtualSustainSlots.length)
				virtualSustainSlots.resize(local + 1);
			virtualSustainSlots[local] = obj;
		}

		// F10: full field reset on EVERY path (mirroring getNote's
		// discipline), not just alpha. The slow path returns an object whose
		// ref was nulled at recycle time; leaving the other fields stale
		// made a slot binding half-initialised between here and drawNote's
		// sustain tail, and any early return in between surfaced garbage.
		obj.alpha = Sustain.defaultAlpha;
		obj.ref = null;
		obj.w = 0;
		obj.length = 0;
		obj.speed = parent.parent.scrollSpeed;
		obj.scale = 1;
		obj.r = 0;
		return obj;
	}

	/**
	 * Deactivates the note binding at `index` and returns it to the inactive
	 * pool (F14: what actually happens — the binding's slot is cleared and
	 * the object pushed to the free stack; no visual property is touched and
	 * no GPU state is affected. The next getNote at this index rebinds a
	 * slot in place or pops from the stack).
	 *
	 * F4: the caller passes the note it OBSERVED at `index` — if the binding
	 * in the slot was made for a different note, a structural edit (add /
	 * remove / paste / undo) has shifted global indexes since the binding
	 * was made, and recycling just this slot would park the OTHER shifted
	 * bindings in the strip. In that case the whole window strip is
	 * recycled instead (same logic as the light-reset edge recycler).
	 */
	function putNote(n:MetaNote, index:Int64) {
		var slot = Int64.toInt(index);
		var local = slot - slotBase; // F7: slots are slotBase-relative
		if (local >= 0 && local < virtualNoteSlots.length) {
			var obj = virtualNoteSlots[local];
			// Identity check — BY VALUE: File.getNote() builds a fresh
			// MetaNote wrapper on every call, so object identity is never
			// stable across calls. The packed (high, low) words are the
			// note's full immutable state; a mismatch means the chart
			// shifted under us since this binding was made. A null ref is
			// a half-recycled binding — treated as a mismatch (the strip
			// recycle is the conservative action either way).
			if (obj != null && (obj.ref == null || obj.ref != n)) {
				// Structural edit: recycle the whole affected strip. The
				// spawner knows the window; route through it.
				if (parent.noteSpawner != null)
					parent.noteSpawner.recycleWindowForEdit();
				else
					recycleNoteAt(index);
				return;
			}
		}
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
		var local = Int64.toInt(index) - slotBase; // F7: slotBase-relative
		if (local >= 0 && local < virtualNoteSlots.length) {
			var obj = virtualNoteSlots[local];
			if (obj != null) {
				obj.ref = null; // drop the MetaNote ref early
				// F2: refuse a duplicate push — an object already on the
				// free stack must never be pushed again (two slots aliasing
				// one object was the reset()-after-edit duplicate leak).
				if (!obj.onFreeStack) {
					obj.onFreeStack = true;
					inactiveVirtualNotes.push(obj);
				}
				virtualNoteSlots[local] = null;
			}
		}
	}

	/**
	 * Deactivates the sustain binding at `index` and returns it to the
	 * inactive pool (same recycle semantics as putNote — F14). Carries the
	 * same F4 structural-edit identity check as putNote: on a mismatch, the
	 * whole window strip is recycled instead of this one slot.
	 */
	function putSustain(n:MetaNote, index:Int64) {
		var slot = Int64.toInt(index);
		var local = slot - slotBase; // F7: slots are slotBase-relative
		if (local >= 0 && local < virtualSustainSlots.length) {
			var obj = virtualSustainSlots[local];
			// Sustain bindings store no MetaNote (their ref is the VirtualNote
			// of the head note), so the identity check compares via the
			// ... BY VALUE (high/low words), since File.getNote() returns a
			// fresh wrapper every call (see putNote). A null at any link
			// means the binding is already half-recycled — treat as a
			// mismatch and strip-recycle.
			if (obj != null && (obj.ref == null || obj.ref.ref == null
				|| obj.ref.ref != n)) {
				if (parent.noteSpawner != null)
					parent.noteSpawner.recycleWindowForEdit();
				else
					recycleSustainAt(index);
				return;
			}
		}
		recycleSustainAt(index);
	}

	/**
	 * Recycles the VirtualSustain binding at a global index — the shared
	 * body of putSustain and the light-reset edge recycler.
	 */
	function recycleSustainAt(index:Int64) {
		var local = Int64.toInt(index) - slotBase; // F7: slotBase-relative
		if (local >= 0 && local < virtualSustainSlots.length) {
			var obj = virtualSustainSlots[local];
			if (obj != null) {
				obj.ref = null; // drop the VirtualNote ref early
				// F2: refuse a duplicate push (see recycleNoteAt).
				if (!obj.onFreeStack) {
					obj.onFreeStack = true;
					inactiveVirtualSusses.push(obj);
				}
				virtualSustainSlots[local] = null;
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
	}


	// =================================================================
	//  Peote Note / Sustain element pool  (GPU-buffer-persistent)
	// =================================================================

	/**
	 * Called at the start of each render frame.
	 * Resets the acquire counters so slots are filled from 0.
	 * F1: marks the frame open — endFrame() must run exactly once after
	 * this, whatever happens in between (see frameOpen).
	 */
	inline function beginFrame() {
		noteSlot = 0;
		sustainSlot = 0;
		frameOpen = true;
		notesDirty = false;
		sustainsDirty = false;
	}

	/**
	 * Acquire a pooled Note for rendering.  The returned Note is already
	 * inside `notesBuf` — just set its properties and it will be picked up
	 * by the next `notesBuf.update()`.
	 *
	 * Reuses an active slot when possible (in-place update), otherwise
	 * pops from the free stack or allocates a fresh Note and calls
	 * `addElement` to place it in the buffer.
	 */
	function acquireNote():Note {
		notesDirty = true;
		if (noteSlot < prevNoteCount) {
			return activeNotes[noteSlot++];
		}
		var note = pooledNotes.pop();
		if (note == null) {
			note = new Note(0, 0, 0, 0, NoteSystem.typeToHandle[0]);
		}
		NoteSystem.notesBuf.addElement(note);
		activeNotes.push(note);
		noteSlot++;
		return note;
	}

	/**
	 * Acquire a pooled Sustain for rendering.  Same contract as
	 * `acquireNote` but for `sustainsBuf`.
	 */
	function acquireSustain():Sustain {
		sustainsDirty = true;
		if (sustainSlot < prevSustainCount) {
			return activeSustains[sustainSlot++];
		}
		var sustain = pooledSustains.pop();
		if (sustain == null) {
			sustain = new Sustain(-9999, -9999, 0, 0, NoteSystem.typeToHandle[0], 0, 1, 1, 0);
		}
		NoteSystem.sustainsBuf.addElement(sustain);
		activeSustains.push(sustain);
		sustainSlot++;
		return sustain;
	}

	/**
	 * Called at the end of each render frame.
	 * Any active slots that were NOT acquired this frame are released:
	 * removed from the GPU buffer and pushed back onto the free stack.
	 *
	 * Because notes are always acquired sequentially from slot 0 and
	 * released from the tail, removals never shift intermediate elements.
	 *
	 * F1: robust against a mid-render exception. The counters always
	 * describe reality after this call — `noteSlot`/`sustainSlot` are
	 * wherever the interrupted loop left them, the arrays are truncated
	 * to exactly the acquired prefix, and the frame is marked closed —
	 * so the NEXT frame starts from a consistent state instead of
	 * leaking the un-acquired tail forever. renderNotes() calls this in
	 * its catch-and-rethrow path; the frameOpen flag makes a second
	 * call (or a missed beginFrame) a no-op instead of a double drain.
	 */
	function endFrame() {
		if (!frameOpen)
			return;
		frameOpen = false;

		// Release unused notes (from the tail — no shifting). The loop
		// bound uses the LIVE array length, not prevNoteCount: after an
		// exception mid-acquire the array may be longer than prevNoteCount
		// (fresh pushes) — those are released too, then the counters are
		// re-based. peote's removeElement is swap-with-last, so batch
		// releases below only remove from the tail, which is exactly the
		// O(1) case (the last element swaps with itself).
		while (activeNotes.length > noteSlot) {
			var note = activeNotes.pop();
			NoteSystem.notesBuf.removeElement(note);
			pooledNotes.push(note);
			noteGeneration++; // F9: every cached sprite reference is now stale
		}
		prevNoteCount = noteSlot;
		if (activeNotes.length != noteSlot)
			activeNotes.resize(noteSlot); // belt-and-braces after exception paths

		while (activeSustains.length > sustainSlot) {
			var sustain = activeSustains.pop();
			NoteSystem.sustainsBuf.removeElement(sustain);
			pooledSustains.push(sustain);
		}
		prevSustainCount = sustainSlot;
		if (activeSustains.length != sustainSlot)
			activeSustains.resize(sustainSlot);
	}

	/**
	 * Cleans up all pool arrays and references for garbage collection.
	 * F5: the teardown ORDER matters. The caller clears the static GPU
	 * buffers afterwards (NoteSystem.dispose does notesBuf.clear() /
	 * sustainsBuf.clear()), which resets every contained element's bytePos
	 * to -1. To keep a stale pooled Note from being rooted by anything
	 * that outlives this teardown (a Receptor field, a cached sprite
	 * reference), every reference the pool itself holds is dropped here —
	 * free stacks, active arrays, slots — so the elements become
	 * collectable the moment the last external ref goes away. Receptor
	 * fields are nulled by Strumline.dispose AFTER the buffers clear (see
	 * the reordered NoteSystem.dispose).
	 */
	function dispose() {
		activeNotes = null;
		activeSustains = null;
		pooledNotes = null;
		pooledSustains = null;
		inactiveVirtualNotes = null;
		inactiveVirtualSusses = null;
		virtualNoteSlots = null;
		virtualSustainSlots = null;
		frameOpen = false;
	}

	/**
	 * F7: grow headroom below slot 0. A backward scroll can walk the
	 * window below the current base; the live bindings are shifted UP by
	 * `padding` and slotBase drops to the new window bottom, so the local
	 * slot index is never negative. O(live window) once per backward jump.
	 */
	function rebaseUp(globalBottom:Int) {
		var padding = slotBase - globalBottom;
		if (padding <= 0)
			return;
		// Insert `padding` dead entries at the head; existing live entries
		// keep their relative order at a higher local index.
		for (i in 0...padding)
			virtualNoteSlots.insert(0, null);
		for (i in 0...padding)
			virtualSustainSlots.insert(0, null);
		slotBase = globalBottom;
	}

	/**
	 * F7: reclaim the dead prefix. During a long forward scroll the null
	 * entries BELOW the window (already-recycled slots) are pure waste —
	 * the slot arrays used to be global-indexed and grow-only, so a full
	 * end-to-end scroll left one dead entry per chart note. Called by the
	 * spawner when the dead prefix passes double the live window size:
	 * every live binding is shifted down to base 0 (their global keys are
	 * implicit: local + new slotBase) and the arrays are truncated to the
	 * live window. All live bindings at that moment sit inside
	 * [windowBottom, windowTop) — the spawner guarantees it — so nothing
	 * live can be dropped.
	 */
	function compactSlots(windowBottom:Int64, windowTop:Int64) {
		var bottom = Int64.toInt(windowBottom);
		var top = Int64.toInt(windowTop);
		var dead = bottom - slotBase;
		var live = top - bottom;
		// Guards: dead <= 0 → nothing to reclaim (or bottom walked below
		// slotBase — getNote's rebaseUp will fix headroom); live < 0 → the
		// window is transiently inverted mid-seek; dead <= live → not
		// worth the shift yet.
		if (dead <= 0 || live < 0 || dead <= live)
			return;

		// Shift live entries [bottom-slotBase, top-slotBase) down to 0.
		// Destination is always BELOW the source (dead prefix removal), so
		// a forward copy can never overwrite an unread entry. Grow first:
		// writing past .length is undefined on cpp/hl arrays.
		var noteSrc = bottom - slotBase;
		var susSrc = bottom - slotBase;
		if (virtualNoteSlots.length < live)
			virtualNoteSlots.resize(live);
		if (virtualSustainSlots.length < live)
			virtualSustainSlots.resize(live);
		var i = 0;
		while (i < live) {
			virtualNoteSlots[i] = (noteSrc + i < virtualNoteSlots.length) ? virtualNoteSlots[noteSrc + i] : null;
			virtualSustainSlots[i] = (susSrc + i < virtualSustainSlots.length) ? virtualSustainSlots[susSrc + i] : null;
			i++;
		}
		virtualNoteSlots.resize(live);
		virtualSustainSlots.resize(live);
		slotBase = bottom;
	}

	/**
	 * Resets the pool for a song-position jump.
	 * Clears the GPU buffers entirely, re-adds the persistent receptor
	 * notes, and returns all pooled elements to their free stacks.
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

		// Return active pooled elements to free stacks
		// (already removed from the buffer by clear above)
		for (note in activeNotes) {
			pooledNotes.push(note);
		}
		for (sustain in activeSustains) {
			pooledSustains.push(sustain);
		}

		activeNotes.resize(0);
		activeSustains.resize(0);
		noteSlot = 0;
		sustainSlot = 0;
		prevNoteCount = 0;
		prevSustainCount = 0;
		frameOpen = false; // a reset mid-bracket re-closes the frame state
		noteGeneration++; // F9: invalidate every cached sprite reference

		// Rebuild the free stacks from the slot arrays so recycled
		// virtual objects survive the jump instead of being orphaned.
		// F2: this USED to push bindings that were already on the free
		// stack (an edit's recycleWindowRange followed by this reset),
		// duplicating them — two slots then aliased one object. The
		// rebuild now routes through recycleNoteAt/recycleSustainAt, whose
		// onFreeStack guard refuses the duplicate push by construction.
		// F7: the rebuild re-bases the slots at global 0.
		slotBase = 0;
		inactiveVirtualNotes = new Stack<VirtualNote>();
		for (i in 0...virtualNoteSlots.length) {
			var obj = virtualNoteSlots[i];
			if (obj != null) {
				obj.onFreeStack = false; // fresh stack — object was only in a slot
				obj.ref = null;
				inactiveVirtualNotes.push(obj);
				virtualNoteSlots[i] = null;
			}
		}
		virtualNoteSlots.resize(0);

		inactiveVirtualSusses = new Stack<VirtualSustain>();
		for (i in 0...virtualSustainSlots.length) {
			var obj = virtualSustainSlots[i];
			if (obj != null) {
				obj.onFreeStack = false;
				obj.ref = null;
				inactiveVirtualSusses.push(obj);
				virtualSustainSlots[i] = null;
			}
		}
		virtualSustainSlots.resize(0);
	}
}
