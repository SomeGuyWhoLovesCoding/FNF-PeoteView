package structures.gameplay;

/**
	The pool of the note system.
**/
@:publicFields
class NotePool {
	private var notes(default, null):Array<Note>;
	private var sustains(default, null):Array<Sustain>;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;

		notes = [];
		sustains = [];
	}

	function addNote(n:MetaNote) {
		// TODO
	}

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		if (notes != null) {
			while (notes.pop() != null) {}
			notes = null;
		}

		if (sustains != null) {
			while (sustains.pop() != null) {}
			sustains = null;
		}
	}
}