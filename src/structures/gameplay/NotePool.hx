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
	var virtualNotes(default, null):MetaNoteMap<VirtualNote>;
	var inactiveVirtualNotes(default, null):Array<VirtualNote>;
	var virtualSustains(default, null):MetaNoteMap<VirtualSustain>;
	var inactiveVirtualSusses(default, null):Array<VirtualSustain>;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;

		virtualNotes = new MetaNoteMap<VirtualNote>();
		virtualSustains = new MetaNoteMap<VirtualSustain>();
		inactiveVirtualNotes = [];
		inactiveVirtualSusses = [];
	}

	/**
	 * Creates a new note and determines when to add it to note pool or not.
	 * This function is called every time you call `drawNote`, constantly. Do not implement anything else in there if you want to change something in this note system.
	 * @param id The index the note sprite (existing or not) should change to.
	 * @param n The underlying meta note the note sprite's data should be set to.
     * @param index The index the note belongs to.
	 */
	function getNote(id:Int, n:MetaNote, index:Int64) {
		var allocated = virtualNotes.get(n);

		if (allocated == null) {
			var inactiveObject = inactiveVirtualNotes.pop();
			if (inactiveObject == null) inactiveObject = new VirtualNote(-9999, -9999, 0, 0);
			inactiveObject.initialAlpha = Note.defaultAlpha;
			inactiveObject.addedAlpha = 0;
			inactiveObject.notesInOne = 1;
			inactiveObject.greedyMergeAlphaMultiplier = 0;
			inactiveObject.greedyMergeType = 0;
			inactiveObject.ref = n;
			allocated = inactiveObject;
			virtualNotes.set(n, inactiveObject);
		}

		allocated.initialAlpha = Note.defaultAlpha;
		allocated.ref = n;

		return allocated;
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 * @param id The index the sustain sprite (existing or not) should change to.
	 * @param n The underlying meta note the sustain sprite's data should be set to.
	 */
	function getSustain(id:Int, n:MetaNote) {
		var allocated = virtualSustains.get(n);

		if (allocated == null) {
			var tex = TextureSystem.getTexture("sustainTex");

			var inactiveObject = inactiveVirtualSusses.pop();
			if (inactiveObject == null) {
				inactiveObject = new VirtualSustain(-9999, -9999,
				Math.floor(tex.width / tex.tilesX),
			        Math.floor(tex.height / tex.tilesY)
				);
				inactiveObject.alpha = Sustain.defaultAlpha;
			}
			allocated = inactiveObject;
			virtualSustains.set(n, inactiveObject);
		}


		return allocated;
	}

	/**
	 * Puts a note in its inactive list.
	 * @param n The underlying meta note in which selects the note sprite to be put in the inactive list.
	 */
	function putNote(n:MetaNote, index:Int64) {
		var allocated:VirtualNote = virtualNotes.get(n);

		if (virtualNotes.remove(n)) {
			allocated.initialAlpha = Note.defaultAlpha;
			allocated.addedAlpha = 0;
			allocated.greedyMergeAlphaMultiplier = 0;
			allocated.greedyMergeType = 0;
			allocated.x = -9999;
			allocated.y = -9999;
			inactiveVirtualNotes.push(allocated);
		}

		n.flag = false;
		n.missed = false;
		n.held = false;
		parent.noteSpawner.setCachedNote(index, n);
	}

	/**
	 * Puts a sustain in its inactive list.
	 * @param n The underlying meta note in which selects the sustain sprite to be put in the inactive list.
	 */
	function putSustain(n:MetaNote) {
		var allocated:VirtualSustain = virtualSustains.get(n);
		if (virtualSustains.remove(n)) {
			allocated.x = -9999;
			allocated.y = -9999;
			allocated.alpha = Sustain.defaultAlpha;
			inactiveVirtualSusses.push(allocated);
		}
	}

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		if (virtualNotes != null) {
			virtualNotes.clear();
			virtualNotes = null;
		}

		if (virtualSustains != null) {
			virtualSustains.clear();
			virtualSustains = null;
		}
	}
}