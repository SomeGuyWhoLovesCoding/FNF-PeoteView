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
	 * @param notesToPrealloc How many notes the note pool should preallocate.
	 * @param sustainsToPrealloc How many sustains the note pool should preallocate.
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
	 * @param id The index the note sprite (existing or not) should change to.
	 * @param n The underlying meta note the note sprite's data should be set to.
	 */
	function newNote(id:Int, n:MetaNote) {
		var allocated = notes[notesPos];

		if (allocated == null) {
			allocated = notes[notesPos] = new Note(-9999, -9999, 0, 0);
			allocated.toNote();
		}

		allocated.changeID(id);
		allocated.toNote();
		allocated.data = n;

		++notesPos;

		return allocated;
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 * @param id The index the sustain sprite (existing or not) should change to.
	 */
	function newSustain(id:Int) {
		var allocated = sustains[sustainsPos];

		if (allocated == null) {
			var tex = TextureSystem.getTexture("sustainTex");
			allocated = sustains[sustainsPos] = new Sustain(-9999, -9999,
				Math.floor(tex.width / tex.tilesX),
			        Math.floor(tex.height / tex.tilesY)
			);
		}

		allocated.changeID(id);

		++sustainsPos;

		return allocated;
	}

	/**
	 * Resets the note pool positioning.
	 */
	inline function resetPositions() {
		notesPos = sustainsPos = 0;
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