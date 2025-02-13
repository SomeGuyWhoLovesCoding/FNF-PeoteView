package structures.gameplay;

/**
	The pool of the note system.
**/
@:publicFields
class NotePool {
	private var notes(default, null):ObjectPool<Note>;
	private var sustains(default, null):ObjectPool<Sustain>;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 * @param notesToPrealloc How many notes the note pool should preallocate.
	 * @param sustainsToPrealloc How many sustains the note pool should preallocate.
	 */
	function new(parent:NoteSystem, notesToPrealloc:Int = 100, sustainsToPrealloc:Int = 20) {
		this.parent = parent;

		var tex = TextureSystem.getTexture("sustainTex");
		notes = new ObjectPool<Note>(() -> return new Note(0, 0, 0, 0), __resetNote, notesToPrealloc);
		sustains = new ObjectPool<Sustain>(() -> return new Sustain(0, 0, Math.floor(tex.width / tex.tilesX), Math.floor(tex.height / tex.tilesY)), __resetSustain, sustainsToPrealloc);
	}

	/**
	 * Creates a new note and determines when to add it to note pool or not.
	 */
	inline function note() {
		return notes.acquire();
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 */
	inline function sustain() {
		return sustains.acquire();
	}

	/**
	 * Releases a note from its pool.
	 */
	inline function releaseNote() {
		return notes.release(note());
	}

	/**
	 * Releases a note from its pool.
	 */
	inline function releaseSustain() {
		return sustains.release(sustain());
	}

	/**
	 * Resets an inactive note object.
	 */
	inline function __resetNote(n:Note) {
		if (n == null) return;
		n.x = -9999;
		n.y = -9999;
		n.w = 0;
		n.h = 0;
		n.hit = false;
		n.c.aF = 1;
		n.changeID(0);
	}

	/**
	 * Resets an inactive sustain object.
	 */
	inline function __resetSustain(s:Sustain) {
		if (s == null) return;
		s.x = -9999;
		s.y = -9999;
		s.w = 0;
		s.h = 0;
		s.held = false;
		s.c.aF = 1;
		s.changeID(0);
	}

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		if (notes != null) {
			notes = null;
		}

		if (sustains != null) {
			sustains = null;
		}
	}
}
