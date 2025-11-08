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
	var virtualNotes(default, null):Array<VirtualNote>;
	var virtualNotesLen(default, null):Int;
	var virtualSustains(default, null):Array<VirtualSustain>;
	var virtualSustainsLen(default, null):Int;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;

		virtualNotes = [];
		virtualSustains = [];
	}

	/**
	 * Creates a new note and determines when to add it to note pool or not.
	 * This function is called every time you call `drawNote`, constantly. Do not implement anything else in there if you want to change something in this note system.
	 * @param id The index the note sprite (existing or not) should change to.
	 * @param n The underlying meta note the note sprite's data should be set to.
     * @param index The index the note belongs to.
	 */
	function getNote() {
		var allocated:VirtualNote = null;

		if (virtualNotesLen >= virtualNotes.length - 1) {
			var inactiveObject:VirtualNote = virtualNotes[++virtualNotesLen] = new VirtualNote(-9999, -9999, 0, 0);
			inactiveObject.initialAlpha = Note.defaultAlpha;
			inactiveObject.addedAlpha = 0;
			inactiveObject.notesInOne = 1;
			inactiveObject.greedyMergeAlphaMultiplier = 0;
			inactiveObject.greedyMergeType = 0;
			inactiveObject.ref = n;
			allocated = inactiveObject;
			virtualNotes.set(n, inactiveObject);
		} else {
			allocated = virtualNotes[++virtualNotesLen];
			allocated.initialAlpha = Note.defaultAlpha;
		    allocated.ref = n;
		}

		return allocated;
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 * @param id The index the sustain sprite (existing or not) should change to.
	 * @param n The underlying meta note the sustain sprite's data should be set to.
	 */
	function getSustain(ref:MetaNote) {
		var allocated:VirtualSustain = null;

		if (virtualSustainsLen >= virtualSustains.length - 1) {
			var tex = TextureSystem.getTexture("sustainTex");
			var inactiveObject:VirtualSustain = virtualSustains[++virtualSustainsLen] = new VirtualSustain(-9999, -9999,
				Math.floor(tex.width / tex.tilesX),
			        Math.floor(tex.height / tex.tilesY)
				);
			}
			allocated = inactiveObject;
		} else {
			allocated = virtualSustains[++virtualSustainsLen];
		}
		allocated.alpha = ref.missed ? Sustain.defaultMissAlpha : Sustain.defaultAlpha;
		return allocated;
	}

	/**
	 * Start over the notes to be used for another day.
	**/
    function startOver() {
		virtualNotesLen = 0;
		virtualSustainsLen = 0;
	}

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		if (virtualNotes != null) {
			virtualNotes.resize(0);
			virtualNotes = null;
		}

		if (virtualSustains != null) {
			virtualSustains.resize(0);
			virtualSustains = null;
		}
	}
}
