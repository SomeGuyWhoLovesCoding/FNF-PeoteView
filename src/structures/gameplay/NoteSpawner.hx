package structures.gameplay;

/**
	The internal handler of the note system.
**/
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;

	var spawnDist:Int = 160000;
	var despawnDist:Int = 30000;

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var file(default, null):File;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note spawner.
	 * @param file The chart file to import onto the note spawner.
	 */
	function new(file:File, parent:NoteSystem) {
		this.file = file;
		this.parent = parent;

		bottom = 0;
		top = 0;

		curTopNote = file.getNote(0);
		curBottomNote = file.getNote(0);
	}

	/**
	 * Updates the note spawner.
	 * @param pos The song's position in the note position format.
	 */
	function update(pos:Int64) {
		cullTop(pos);
		cullBottom(pos);

		var i = bottom;

		while (i < top) {
			var note = file.getNote(i);
			parent.drawNote(pos, note);
			++i;
		}
	}

	/**
	 * Culls the top note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullTop(pos:Int64) {
		var len = file.length;
		while (top != len && (curTopNote.position - pos).low < spawnDist) {
			++top;
			curTopNote = file.getNote(top);
		}
	}

	/**
	 * Culls the bottom note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullBottom(pos:Int64) {
		var len = file.length;
		while (bottom != len &&
			((pos -
			(
				((curBottomNote.duration << 2) + curBottomNote.duration) * 100
			)) -
			curBottomNote.position).low > despawnDist) {
			++bottom;
			parent.notesHit.remove(curBottomNote);
			parent.notesMissed.remove(curBottomNote);
			parent.notesHeld.remove(curTopNote);
			curBottomNote = file.getNote(bottom);
		}
	}

	/**
	 * Reload the notes.
	 */
	function resetNotes() {
		var pf = parent.parent;

		if (pf.disposed || pf.died) return;

		var strumlines = parent.strumlines;
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.resetInputs();
		}

		parent.notesHit.clear();
		parent.notesMissed.clear();
		parent.notesHeld.clear();

		var file = pf.chart.file;
		var len = file.length;

		// This is the mess part and shit in which I've optimized

		var incrementAmount = 10;

		if (len > 100) {
			incrementAmount = 20;
		} else if (len > 1000) {
			incrementAmount = 200;
		} else if (len > 10000) {
			incrementAmount = 2000;
		} else if (len > 100000) {
			incrementAmount = 20000;
		} else if (len > 1000000) {
			incrementAmount = 200000;
		} else if (len > 10000000) {
			incrementAmount = 2000000;
		} else if (len > 100000000) {
			incrementAmount = 20000000;
		} else if (len > 1000000000) {
			incrementAmount = 200000000;
		}

		var decrementAmount = 2;

		if (len > 100) {
			decrementAmount = 5;
		} else if (len > 1000) {
			decrementAmount = 50;
		} else if (len > 10000) {
			decrementAmount = 500;
		} else if (len > 100000) {
			decrementAmount = 5000;
		} else if (len > 1000000) {
			decrementAmount = 50000;
		} else if (len > 10000000) {
			decrementAmount = 500000;
		} else if (len > 100000000) {
			decrementAmount = 5000000;
		} else if (len > 1000000000) {
			decrementAmount = 50000000;
		}

		var songPos = Tools.betterInt64FromFloat(pf.songPosition * 100);
		var lenSub1 = len - 1;

		if (top > incrementAmount) {
			while (file.getNote(clampCull(top += incrementAmount, lenSub1)).position < songPos - spawnDist) {}
			while (file.getNote(clampCull(top--, lenSub1)).position > songPos - spawnDist) {}
		}

		bottom = top;

		if (bottom > decrementAmount) {
			while (file.getNote(clampCull(bottom -= decrementAmount, lenSub1)).position > songPos) {}
			while (file.getNote(clampCull(bottom++, lenSub1)).position < songPos) {}
		}
	}

	inline function clampCull(val:Int64, max:Int64) {
		return val < max ? val : max;
	}
}