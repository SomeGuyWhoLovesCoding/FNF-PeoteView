package structures.gameplay;

/**
	The note system's sprite collection.
	This is not an object pool for obvious reasons.
	This uses the same grow-only format as with `NoteVB`.
	@since Development
**/
@:publicFields
class NotePool {
	var virtualNotes(default, null):Array<VirtualNote>;
	var virtualSustains(default, null):Array<VirtualSustain>;

	var parent(default, null):NoteSystem;

	var notesLength(default, null):Int;
	var sustainsLength(default, null):Int;

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
	function getNote(id:Int, n:MetaNote, index:Int64) {
		var spr = virtualNotes[notesLength];

		if (spr != null) {
			notesLength++;
			return spr;
		}

		var allocated = new VirtualNote(-9999, -9999, 0, 0);
		allocated.initialAlpha = Note.defaultAlpha;
		allocated.addedAlpha = 0;
		allocated.notesInOne = 1;
		allocated.greedyMergeAlphaMultiplier = 0;
		allocated.greedyMergeType = 0;
		allocated.ref = n;

		virtualNotes[notesLength] = allocated;

		notesLength++;

		return allocated;
	}

	/**
	 * Creates a new sustain and determines when to add it to note pool or not.
	 * @param id The index the sustain sprite (existing or not) should change to.
	 * @param n The underlying meta note the sustain sprite's data should be set to.
	 */
	function getSustain(id:Int, n:MetaNote) {
		var spr = virtualSustains[sustainsLength];

		if (spr != null) {
			sustainsLength++;
			return spr;
		}

		var tex = TextureSystem.getTexture("sustainTex");

		var allocated = new VirtualSustain(-9999, -9999,
		Math.floor(tex.width / tex.tilesX),
			Math.floor(tex.height / tex.tilesY)
		);
		allocated.alpha = Sustain.defaultAlpha;

		virtualSustains[sustainsLength] = allocated;

		sustainsLength++;

		return allocated;
	}

	/**
	 * Clears the note pool for the next frame.
	**/
	inline function clearNotePool() {
		notesLength = 0;
		sustainsLength = 0;
	}

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		clearNotePool();

		while (virtualNotes.pop() != null) {}
		virtualNotes = null;
		while (virtualSustains.pop() != null) {}
		virtualSustains = null;
	}
}