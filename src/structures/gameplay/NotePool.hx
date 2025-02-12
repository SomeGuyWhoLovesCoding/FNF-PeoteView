package structures.gameplay;

/**
	The pool of the note system.
**/
@:publicFields
class NotePool {
	private var notes(default, null):Array<Note>;
	private var notesPos(default, null):Int;
	private var sustains(default, null):Array<Sustain>;
	private var sustainsPos(default, null):Int;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 */
	function new(parent:NoteSystem, notesToPrealloc:Int = 100, sustainsToPrealloc:Int = 20) {
		this.parent = parent;

		notes = [];
		sustains = [];

		notes.resize(notesToPrealloc);
		sustains.resize(sustainsToPrealloc);
	}
	
	/**
	 * Creates a new note and determines when to add it to note pool or not.
	 */
	function newNote() {
		var allocated = notes[notesPos];
		if (allocated == null) {
			allocated = notes[notesPos] = new Note(0, 0, 0, 0);
			allocated.toNote();
		}
		++notesPos;
		return allocated;
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 */
	function newSustain() {
		var allocated = sustains[sustainsPos];
		if (allocated == null) {
			var tex = TextureSystem.getTexture("sustainTex"):
			allocated = sustains[sustainsPos] = new Sustain(0, 0,
				Math.floor(tex.width / tex.tilesX),
			        Math.floor(tex.height / tex.tilesY)
			);
		}
		++sustainsPos;
		return allocated;
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
