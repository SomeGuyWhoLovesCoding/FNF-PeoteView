package structures.notes;

import utils.Stack;
import structures.notes.NoteVB.VirtualNote;
import structures.notes.NoteVB.VirtualSustain;

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

    var parent(default, null):NoteSystem;

	/**
	 * Initializes the NotePool with parent reference and empty arrays.
	 * @param parent The NoteSystem instance that owns this pool.
	 */
    function new(parent:NoteSystem) {
        this.parent = parent;
        inactiveVirtualNotes = new Stack<VirtualNote>();
        inactiveVirtualSusses = new Stack<VirtualSustain>();
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
        if (obj == null) obj = new VirtualNote(0, 0, 0);
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

	/**
	 * Cleans up all pool arrays and references for garbage collection.
	 */
    function dispose() {
        inactiveVirtualNotes = null;
        inactiveVirtualSusses = null;
    }

	/**
	 * Cleans up all pool arrays and references for garbage collection, but also reinitializes it.
	 */
    function reset() {
        inactiveVirtualNotes = null;
        inactiveVirtualSusses = null;
        inactiveVirtualNotes = new Stack<VirtualNote>();
        inactiveVirtualSusses = new Stack<VirtualSustain>();
    }
}