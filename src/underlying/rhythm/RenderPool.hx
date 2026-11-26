package underlying.rhythm;

import underlying.rhythm.NoteSystem;

/**
	The v3.9.0 render pool — the GPU-element half of the old NotePool,
	rewritten around one discipline: elements are created ONCE, stay in
	the peote buffer FOREVER, and are PARKED (scale 0) instead of removed.

	The old pool's churn was the residual leak's home turf: acquire →
	addElement, endFrame → removeElement — every despawn hit the GPU
	buffer's remove path (internal shifts, capacity bookkeeping), and
	every spawn paid the add path back. The persistent-manual-stack
	approach removes that entire class of work: the stack array only
	grows, an element's index NEVER changes after creation, and a frame
	is just "how deep into the stack the renderer walked".

	`active` doubles as the manual stack: the renderer pops upward from
	0 each frame (renderFrame resets cursor to 0); elements above the
	high-water mark are parked with scale 0 and alpha 0 in the SAME
	pass, then notesBuf.update() flushes once. No free list, no removal,
	no per-frame buffer membership churn.
	@since Development
**/
@:publicFields
class RenderPool {
	// The manual stack: entry i is i-th pooled element ever created.
	// Grows only; entries are never removed or reordered.
	var notes:Array<Note>;
	var sustains:Array<Sustain>;

	// This frame's stack cursor and last frame's high-water mark.
	var noteCursor:Int;
	var sustainCursor:Int;
	var prevNoteCount:Int;
	var prevSustainCount:Int;

	var parent(default, null):NoteSystem;

	function new(parent:NoteSystem) {
		this.parent = parent;
		notes = [];
		sustains = [];
		noteCursor = 0;
		sustainCursor = 0;
		prevNoteCount = 0;
		prevSustainCount = 0;
	}

	/**
		Starts a render frame: cursor back to the bottom of the stack.
	**/
	inline function beginFrame() {
		noteCursor = 0;
		sustainCursor = 0;
	}

	/**
		Takes the next pooled Note off the stack — or grows the stack by
		one (created ONCE, addElement ONCE, never removed). The returned
		element is already in `notesBuf`; just set its properties.
	**/
	inline function acquireNote():Note {
		if (noteCursor < notes.length)
			return notes[noteCursor++];
		var note = new Note(0, 0, 0, 0, NoteSystem.typeToHandle[0]);
		NoteSystem.notesBuf.addElement(note);
		notes.push(note);
		noteCursor = notes.length;
		return note;
	}

	/** Same contract as acquireNote, for sustains. */
	inline function acquireSustain():Sustain {
		if (sustainCursor < sustains.length)
			return sustains[sustainCursor++];
		var sustain = new Sustain(-9999, -9999, 0, 0, NoteSystem.typeToHandle[0], 0, 1, 1, 0);
		NoteSystem.sustainsBuf.addElement(sustain);
		sustains.push(sustain);
		sustainCursor = sustains.length;
		return sustain;
	}

	/**
		Ends the render frame: parks every element ABOVE this frame's
		high-water mark (scale 0, alpha 0 — one properties write each,
		flushed by the single notesBuf.update() the caller does). The
		stack only ever grew; nothing is removed; the next frame's
		beginFrame walks up from 0 again.
	**/
	inline function endFrame() {
		var i = noteCursor;
		var n = notes.length;
		while (i < n) {
			var note = notes[i];
			note.scale = 0;
			note.initialAlpha = 0;
			note.addedAlpha = 0;
			i++;
		}
		prevNoteCount = noteCursor;

		i = sustainCursor;
		n = sustains.length;
		while (i < n) {
			var sustain = sustains[i];
			sustain.scale = 0;
			sustain.c.aF = 0;
			sustain.c.luminanceF = 0;
			i++;
		}
		prevSustainCount = sustainCursor;
	}

	/**
		Frees the pooled elements' backing arrays (dispose only — the
		notesBuf.clear() that follows releases the GPU memberships).
	**/
	function dispose() {
		notes = null;
		sustains = null;
	}
}
