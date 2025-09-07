package structures.gameplay;

/**
	The pool of the note system.
	I'm proud of this class, it is the most efficient way to handle notes and sustains when working with peote-view.
	It uses a map to store the notes and sustains, and an array to store the inactive notes and sustains.
	When a note or sustain is needed, it checks if it is already allocated, if not, it creates a new one.
	When a note or sustain is no longer needed, it puts it in the inactive list.
	When a note or sustain is needed again, it checks the inactive list first, if it is not empty, it uses the last inactive note or sustain.
	This way, it reduces the number of objects created and destroyed, which is a performance boost.
	It also allows for easy access to the notes and sustains by their underlying meta note.
	This is a very important class for the note system, and it is used in the NoteSystem class.
	It is also used in said class to handle the notes and sustains.
	This entire passage was written with github copilot, and I am very proud of it.
	@since Development
**/
@:publicFields
class NotePool {
	var notes(default, null):MetaNoteMap<Note>;
	var inactiveNotes(default, null):Array<Note>;
	var sustains(default, null):MetaNoteMap<Sustain>;
	var inactiveSustains(default, null):Array<Sustain>;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 * @param notesToPrealloc How many notes the note pool should preallocate.
	 * @param sustainsToPrealloc How many sustains the note pool should preallocate.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;

		notes = new MetaNoteMap<Note>();
		sustains = new MetaNoteMap<Sustain>();
		inactiveNotes = [];
		inactiveSustains = [];
	}

	/**
	 * Creates a new note and determines when to add it to note pool or not.
	 * @param id The index the note sprite (existing or not) should change to.
	 * @param n The underlying meta note the note sprite's data should be set to.
	 */
	function newNote(id:Int, n:MetaNote) {
		var allocated = notes.get(n);

		if (allocated == null) {
			var inactiveObject = inactiveNotes.pop();
			if (inactiveObject == null) inactiveObject = new Note(-9999, -9999, 0, 0);
			inactiveObject.initialAlpha = Note.defaultAlpha;
			inactiveObject.data = n;
			allocated = inactiveObject;
			notes.set(n, inactiveObject);
		}

		allocated.data = n;
		allocated.changeID(id);
		allocated.toNote();
		allocated.notesInOne = 1;

		return allocated;
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 * @param id The index the sustain sprite (existing or not) should change to.
	 * @param n The underlying meta note the sustain sprite's data should be set to.
	 */
	function newSustain(id:Int, n:MetaNote) {
		var allocated = sustains.get(n);

		if (allocated == null) {
			var tex = TextureSystem.getTexture("sustainTex");

			var inactiveObject = inactiveSustains.pop();
			if (inactiveObject == null) {
				inactiveObject = new Sustain(-9999, -9999,
				Math.floor(tex.width / tex.tilesX),
			        Math.floor(tex.height / tex.tilesY)
				);
				inactiveObject.c.aF = Sustain.defaultAlpha;
				inactiveObject.c.luminanceF = Sustain.defaultAlpha;
			}
			allocated = inactiveObject;
			sustains.set(n, inactiveObject);
		}

		allocated.changeID(id);

		return allocated;
	}

	/**
	 * Puts a note in its inactive list.
	 * @param n The underlying meta note in which selects the note sprite to be put in the inactive list.
	 */
	function putNote(n:MetaNote) {
		var allocated:Note = notes.get(n);
		if (notes.remove(n)) {
			allocated.initialAlpha = 1;
			allocated.x = -9999;
			allocated.y = -9999;
			inactiveNotes.push(allocated);
		}
	}

	/**
	 * Puts a sustain in its inactive list.
	 * @param n The underlying meta note in which selects the sustain sprite to be put in the inactive list.
	 */
	function putSustain(n:MetaNote) {
		var allocated:Sustain = sustains.get(n);
		if (sustains.remove(n)) {
			allocated.x = -9999;
			allocated.y = -9999;
			allocated.c.aF = Sustain.defaultAlpha;
			allocated.c.luminanceF = Sustain.defaultAlpha;
			inactiveSustains.push(allocated);
		}
	}

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		if (notes != null) {
			notes.clear();
			notes = null;
		}

		if (sustains != null) {
			sustains.clear();
			sustains = null;
		}
	}
}