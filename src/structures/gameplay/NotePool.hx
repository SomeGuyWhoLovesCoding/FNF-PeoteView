package structures.gameplay;

import utils.Stack;

/**
 * The pool of the note system with full object recycling.
 * Uses free lists for O(1) reuse and generation-based validation.
 * @since Development
**/
@:publicFields
class NotePool {
	var inactiveVirtualNotes(default, null):Stack<VirtualNote>;
	var inactiveVirtualSustains(default, null):Stack<VirtualSustain>;
	
	// Cache texture dimensions for sustain creation
	static var sustainWidth:Int = 0;
	static var sustainHeight:Int = 0;
	
	var parent(default, null):NoteSystem;

	function new(parent:NoteSystem) {
		this.parent = parent;
		inactiveVirtualNotes = new Stack<VirtualNote>();
		inactiveVirtualSustains = new Stack<VirtualSustain>();
		
		// Cache texture dimensions once
		if (sustainWidth == 0) {
			var tex = TextureSystem.getTexture("sustainTex");
			sustainWidth = Math.floor(tex.width / tex.tilesX);
			sustainHeight = Math.floor(tex.height / tex.tilesY);
		}
	}

	/**
	 * Gets a VirtualNote from the pool or creates a new one.
	 * @param note The underlying meta note to reference.
	 * @param index The global note index.
	 * @return The allocated VirtualNote.
	 */
	function getNote(n:MetaNote, index:Int64):VirtualNote {
		var obj = inactiveVirtualNotes.pop();
		if (obj == null) {
			obj = new VirtualNote(0, 0, 0);
		}
		
		// Reset to default state
		obj.ref = n;
		obj.globalIndex = index;
		obj.initialAlpha = Note.defaultAlpha;
		obj.addedAlpha = 0;
		obj.notesInOne = 1;
		obj.diff = 0;
		obj.Sx = 0;
		obj.Sy = 0;
		obj.scale = 1.0;
		
		return obj;
	}

	/**
	 * Gets a VirtualSustain from the pool or creates a new one.
	 * @param note The underlying meta note to reference.
	 * @param index The global note index.
	 * @return The allocated VirtualSustain.
	 */
	function getSustain(n:MetaNote, index:Int64):VirtualSustain {
		var obj = inactiveVirtualSustains.pop();
		if (obj == null) {
			obj = new VirtualSustain(-9999, -9999, sustainWidth, sustainHeight);
		}
		
		// Reset to default state
		obj.alpha = Sustain.defaultAlpha;
		obj.scale = 1.0;
		obj.speed = 0;
		obj.length = 0;
		obj.diff = 0;
		obj.ref = null;
		obj.r = 0;
		obj.Sx = 0;
		obj.Sy = 0;
		obj.wh = 0;
		
		return obj;
	}

	/**
	 * Returns a VirtualNote to the pool for reuse.
	 */
	inline function putNote(note:VirtualNote) {
		if (note != null) {
			note.ref = NoteVB.INVALID_OR_EMPTY;
			note.globalIndex = -1;
			inactiveVirtualNotes.push(note);
		}
	}

	/**
	 * Returns a VirtualSustain to the pool for reuse.
	 */
	inline function putSustain(sustain:VirtualSustain) {
		if (sustain != null) {
			sustain.ref = null;
			inactiveVirtualSustains.push(sustain);
		}
	}

	/**
	 * Completely clears the pool.
	 */
	function reset() {
		// Clear stacks without iterating - just create new ones
		inactiveVirtualNotes = new Stack<VirtualNote>();
		inactiveVirtualSustains = new Stack<VirtualSustain>();
	}

	/**
	 * Disposes the pool.
	 */
	function dispose() {
		inactiveVirtualNotes = null;
		inactiveVirtualSustains = null;
	}
}