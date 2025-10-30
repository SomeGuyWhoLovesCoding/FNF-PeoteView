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
    private var notes:Array<VirtualNote>;
    private var freeNotes:Array<VirtualNote>;
    private var sustains:Array<VirtualSustain>;
    private var freeSustains:Array<VirtualSustain>;

	/**
	 * Creates the note pool.
	 * @param parent The parent of this class.
	 */
    public function new(initialCapacity:Int = 10000000) {
        notes = [];
        freeNotes = [];
        sustains = [];
        freeSustains = [];

        // Preallocate objects
        for (i in 0...initialCapacity) {
            var n = new VirtualNote();
            notes.push(n);
            freeNotes.push(n);

            var s = new VirtualSustain();
            sustains.push(s);
            freeSustains.push(s);
        }
    }

	/**
	 * Creates a new note and determines when to add it to note pool or not.
	 * This function is called every time you call `drawNote`, constantly. Do not implement anything else in there if you want to change something in this note system.
	 * @param id The index the note sprite (existing or not) should change to.
	 * @param n The underlying meta note the note sprite's data should be set to.
     * @param _id The index the note belongs to.
	 */
    public function getNote(id:Int, meta:MetaNote, _id:Int64):VirtualNote {
        if (freeNotes.length == 0) {
            // Grow dynamically if exhausted
            var n = new VirtualNote(-9999, -9999, 0, 0);
			n.initialAlpha = Note.defaultAlpha;
			n.addedAlpha = 0;
			n.notesInOne = 1;
			n.greedyMergeAlphaMultiplier = 0;
			n.greedyMergeType = 0;
			n.ref = n;
            notes.push(n);
            return n;
        }
        var n = freeNotes.pop();
        resetNote(n, meta);
        return n;
    }

    /** Matches your old API */
    public function getSustain(id:Int, meta:MetaNote):VirtualSustain {
        if (freeSustains.length == 0) {
            var s = new VirtualSustain();
			s.alpha = Sustain.defaultAlpha;
            sustains.push(s);
            return s;
        }
        var s = freeSustains.pop();
        resetSustain(s);
        return s;
    }

	/**
	 * Puts a note in its inactive list.
	 * @param s T
	**/
    public function putNote(n:VirtualNote):Void {
		n.initialAlpha = 1;
		n.addedAlpha = 0;
		n.greedyMergeAlphaMultiplier = 0;
		n.greedyMergeType = 0;
		n.x = -9999;
		n.y = -9999;
        freeNotes.push(n);
    }

	/**
	 * Puts a sustain in its inactive list.
	 * @param s T
	**/
    public function putSustain(s:VirtualSustain):Void {
		s.x = -9999;
		s.y = -9999;
		s.alpha = Sustain.defaultAlpha;
        freeSustains.push(s);
    }

    /** Optional: reset note state when reused */
    private inline function resetNote(n:VirtualNote, meta:MetaNote):Void {
		n.initialAlpha = Note.defaultAlpha;
		n.addedAlpha = 0;
		n.notesInOne = 1;
		n.greedyMergeAlphaMultiplier = 0;
		n.greedyMergeType = 0;
		n.ref = meta;
    }

    /** Optional: reset sustain state when reused */
    private inline function resetSustain(s:VirtualSustain):Void {
		s.alpha = Sustain.defaultAlpha;
		s.ref.ref = null;
    }

	/**
	 * Disposes the note pool.
	 */
	function dispose() {
		while (freeNotes.pop() != null) {}
		while (freeSustain.pop() != null) {}
		while (notes.pop() != null) {}
		while (sustains.pop() != null) {}
	}
}