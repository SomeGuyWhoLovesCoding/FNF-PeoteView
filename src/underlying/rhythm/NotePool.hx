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

	// =================================================================
	//  F19: the index-ordered element store (tier-2 rework)
	// =================================================================
	// The pooled Note/Sustain ELEMENTS now live in two persistent arrays
	// where the ARRAY SLOT IS THE DRAW-ORDER INDEX — the exact order the
	// render loops emit virtual notes/sustains (which is also the order
	// the note buffer feeds the sustain buffer: every sustain element is
	// added to its buffer AFTER the whole note store, so the sustain
	// buffer sits directly behind the note buffer in GPU element order).
	//
	// Why: the old tier-2 pool (free stacks + active arrays) recycled
	// GPU elements per frame through addElement/removeElement — the
	// buffer-level bookkeeping churn that left orphaned elements parked
	// in the buffers between edits (the ~0.5 MB/s growth on the 2.35M
	// spam chart). In this store an element is addElement-ed EXACTLY
	// ONCE (when the store grows to its slot) and NEVER removed:
	//   - acquireNote()/acquireSustain() return store[orderCounter++]
	//     (growing the store on demand) — in-place property writes
	//     follow, which is all rendering ever was;
	//   - endFrame() PARKS every element beyond this frame's order
	//     count off-screen (x=-9999, w=0, alpha 0) instead of removing
	//     it — no buffer mutation, no orphan can exist;
	//   - dispose()/reset() drop the whole store — nothing per-element.
	//
	// The store only ever grows to the chart's high-water mark of
	// simultaneous visible elements (the folded AO sprite count), and
	// every slot below the current count is live — no gaps, no free
	// list, no generation churn beyond the existing F9 counter.

	// The persistent element stores (see the F19 block above). The old
	// free stacks / active arrays are GONE — every element lives in its
	// store for the pool's whole lifetime.
	var noteStore(default, null):Array<Note>;
	var sustainStore(default, null):Array<Sustain>;

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
		// F19: the element stores replace the free stacks + active arrays
		// as the mechanism; the old fields stay as null compatibility
		// views (nothing may push to them anymore).
		noteStore = [];
		sustainStore = [];
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
	 * Acquire the pooled Note at the NEXT order index (F19). The store's
	 * slot IS the draw order: the render loops acquire sequentially, so
	 * store[0..noteSlot) is exactly this frame's emission order. The
	 * element is already inside `notesBuf` — it was added once when the
	 * store grew to this slot — so acquiring is an index bump plus a
	 * lazy grow; all rendering is in-place property writes afterwards.
	 */
	function acquireNote():Note {
		notesDirty = true;
		var slot = noteSlot++;
		if (slot < noteStore.length)
			return noteStore[slot];
		// Grow the store by exactly one: create, add to the buffer ONCE,
		// park it until this frame's writes position it.
		var note = new Note(0, 0, 0, 0, NoteSystem.typeToHandle[0]);
		note.x = -9999;
		note.w = 0;
		note.h = 0;
		NoteSystem.notesBuf.addElement(note);
		noteStore.push(note);
		return note;
	}

	/**
	 * Acquire the pooled Sustain at the NEXT order index (F19). Same
	 * contract as acquireNote. Every sustain element joins sustainsBuf
	 * only through this growth path, which runs strictly AFTER the note
	 * render pass — so in element order the sustain buffer's contents
	 * sit directly behind the note buffer's, the intended layering.
	 */
	function acquireSustain():Sustain {
		sustainsDirty = true;
		var slot = sustainSlot++;
		if (slot < sustainStore.length)
			return sustainStore[slot];
		var sustain = new Sustain(-9999, -9999, 0, 0, NoteSystem.typeToHandle[0], 0, 1, 1, 0);
		sustain.w = 0;
		NoteSystem.sustainsBuf.addElement(sustain);
		sustainStore.push(sustain);
		return sustain;
	}

	/**
	 * Called at the end of each render frame (F19 semantics).
	 *
	 * Every element BEYOND this frame's order count is PARKED off-screen
	 * (x=-9999, zero size, zero alpha) — not removed from the buffer.
	 * Elements never leave the GPU buffer between frames, so the
	 * per-frame addElement/removeElement churn (and the orphaned-element
	 * states it could leave behind on an exception) is structurally
	 * gone: an element is either written this frame (slot < counter) or
	 * parked (slot >= counter). The store itself lives until
	 * dispose()/reset().
	 *
	 * F1: robust against a mid-render exception — the counters are
	 * wherever the interrupted loop left them, and everything past them
	 * parks identically. The frameOpen flag keeps a double endFrame a
	 * no-op.
	 */
	function endFrame() {
		if (!frameOpen)
			return;
		frameOpen = false;

		// Park the unused tail of the note store off-screen.
		var n = noteStore.length;
		var i = noteSlot;
		while (i < n) {
			var note = noteStore[i];
			if (note.x != -9999) { // already parked — skip the write
				note.x = -9999;
				note.y = -9999;
				note.w = 0;
				note.h = 0;
				note.initialAlpha = 0;
				note.addedAlpha = 0;
			}
			i++;
		}
		prevNoteCount = noteSlot;

		// Park the unused tail of the sustain store.
		var m = sustainStore.length;
		var j = sustainSlot;
		while (j < m) {
			var sustain = sustainStore[j];
			if (sustain.x != -9999) {
				sustain.x = -9999;
				sustain.y = -9999;
				sustain.w = 0;
				sustain.h = 0;
			}
			j++;
		}
		prevSustainCount = sustainSlot;
	}

	/**
	 * Cleans up all pool arrays and references for garbage collection.
	 * F5: the teardown ORDER matters. The caller clears the static GPU
	 * buffers afterwards (NoteSystem.dispose does notesBuf.clear() /
	 * sustainsBuf.clear()), which resets every contained element's bytePos
	 * to -1. To keep a stale pooled Note from being rooted by anything
	 * that outlives this teardown (a Receptor field, a cached sprite
	 * reference), every reference the pool itself holds is dropped here —
	 * the whole element store, the free stacks, the slots — so the
	 * elements become collectable the moment the last external ref goes
	 * away. Receptor fields are nulled by Strumline.dispose AFTER the
	 * buffers clear (see the reordered NoteSystem.dispose).
	 * F19: the store dies as ONE unit — no per-element buffer surgery,
	 * because the elements never leave the buffers between frames; the
	 * buffers' own clear() is what ends their GPU residency.
	 */
	function dispose() {
		noteStore = null;
		sustainStore = null;
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
	 * Resets the pool for a song-position jump (F19 semantics).
	 *
	 * The old reset recycled elements through buffer remove/clear + free
	 * stacks. The store-based pool has nothing to recycle: the elements
	 * STAY in the buffers, the order counters rewind to zero, and the
	 * very next frame parks everything (endFrame with zero acquires) or
	 * rewrites it in place. Only the static buffers are re-initialized
	 * so the receptors re-enter first (they must keep their positions in
	 * the note buffer ahead of the store's elements), which is the same
	 * element order the first frame after construction had.
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

		// F19: the stores die whole — the elements' buffer membership
		// ended with the clear above, and fresh elements will be created
		// (and addElement-ed once each) as the next frames demand them.
		noteStore = [];
		sustainStore = [];
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
