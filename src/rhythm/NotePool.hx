package rhythm;

import tooling.Stack;
import rhythm.NoteVB.VirtualNote;
import rhythm.NoteVB.VirtualSustain;

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

	var parent(default, null):NoteSystem;

	/**
	 * Initializes the NotePool with parent reference and empty arrays.
	 * @param parent The NoteSystem instance that owns this pool.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;
		inactiveVirtualNotes = new Stack<VirtualNote>();
		inactiveVirtualSusses = new Stack<VirtualSustain>();
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
	inline function getNote(id:Int, n:MetaNote, index:Int64):VirtualNote {
		var obj = inactiveVirtualNotes.pop();
		if (obj == null)
			obj = new VirtualNote(0, 0, 0);
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
	inline function getSustain(id:Int, n:MetaNote, index:Int64):VirtualSustain {
		var obj = inactiveVirtualSusses.pop();
		if (obj == null) {
			obj = new VirtualSustain(-9999, -9999, 0, 0);
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
	inline function putNote(n:MetaNote, index:Int64) {}

	/**
	 * Deactivates a sustain and returns it to the inactive pool.
	 * Resets all visual properties and alpha.
	 * @param n The underlying meta note to deactivate.
	 * @param index The global note index.
	 */
	inline function putSustain(n:MetaNote, index:Int64) {}

	// =================================================================
	//  Peote Note / Sustain element pool  (GPU-buffer-persistent)
	// =================================================================

	/**
	 * Called at the start of each render frame.
	 * Resets the acquire counters so slots are filled from 0.
	 */
	inline function beginFrame() {
		noteSlot = 0;
		sustainSlot = 0;
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
	 */
	function endFrame() {
		// Release unused notes (from the tail — no shifting)
		while (noteSlot < prevNoteCount) {
			var note = activeNotes.pop();
			NoteSystem.notesBuf.removeElement(note);
			pooledNotes.push(note);
			prevNoteCount--;
		}
		prevNoteCount = noteSlot;

		// Release unused sustains (from the tail — no shifting)
		while (sustainSlot < prevSustainCount) {
			var sustain = activeSustains.pop();
			NoteSystem.sustainsBuf.removeElement(sustain);
			pooledSustains.push(sustain);
			prevSustainCount--;
		}
		prevSustainCount = sustainSlot;
	}

	/**
	 * Cleans up all pool arrays and references for garbage collection.
	 * Does NOT individually removeElement — the caller is expected to
	 * `notesBuf.clear()` / `sustainsBuf.clear()` afterwards.
	 */
	function dispose() {
		activeNotes = null;
		activeSustains = null;
		pooledNotes = null;
		pooledSustains = null;
		inactiveVirtualNotes = null;
		inactiveVirtualSusses = null;
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

		inactiveVirtualNotes = null;
		inactiveVirtualSusses = null;
		inactiveVirtualNotes = new Stack<VirtualNote>();
		inactiveVirtualSusses = new Stack<VirtualSustain>();
	}
}
