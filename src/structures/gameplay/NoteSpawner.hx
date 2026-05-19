package structures.gameplay;

/**
	* This is a part of the note system to actually spawn notes.
	* @since Development
**/
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;

	var _lastbottom:Int64;
	var _lasttop:Int64;

	var spawnDist:Int64 = MetaNote.floatToMetaNotePosition(1300);
	var despawnDist:Int64 = MetaNote.floatToMetaNotePosition(300);

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var parent(default, null):NoteSystem;

	function new(parent:NoteSystem) {
		this.parent = parent;

		bottom = 0;
		top = 0;
	}

	var timeSpentOnIt:Float = 0;
	var timeSpentOnItIncrement:Float = 0;

	function update(pos:Int64) {
		trace("TOP AND BOTTOM (PRE-UPDATE): ",bottom,top);

		_lastbottom = bottom;
		_lasttop = top;

		// === BIDIRECTIONAL SEEK FIX ===
		// Skip culling if we just reset the window (e.g., after a seek)
		if (!_skipCullNextFrame) {
			cullTop(pos);
			cullBottom(pos);
		}
		_skipCullNextFrame = false;
		// ==============================

		processNotes(pos);

		trace("TOP AND BOTTOM (POST-UPDATE): ",bottom,top);
	}

	function processNotes(pos:Int64) {
		var latency = Main.conductor.offset;
		var latencyI64 = MetaNote.floatToMetaNotePosition(latency);

		pos += latencyI64;

		var i = bottom;
		var scrollSpeed = parent.parent.scrollSpeed;
		var prev:MetaNote = -1;
		var prevTimeCorrection:Int64 = 0;
		var noteSpr:VirtualNote = null;
		var j:Int = 0;

		var time = haxe.Timer.stamp();
		while (i < top) {
			var n = File.getNote(i);

			var lane = parent.noteTypeFunctionalityPre[n.type] != null
				? 1
				: (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = parent.strumlines[lane].fakeOverlapStorage;

			var timeCorrection = File.getTimeCorrectionForIndex(i);
			var n_position = n.position + timeCorrection;

			var diff = (MetaNote.metaNotePositionToSongTime(n_position - pos)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);

			var ghost = isGhostNote(prev, n, prevTimeCorrection, i);

			var shouldOverlap = noteSpr != null && shouldNotesOverlap(prev, n, noteSpr, receptor, newY,
				fakeOverlapStorage[prev != -1 ? prev.index : -1]) && !ghost;

			fakeOverlapStorage[n.index] = newY;

			if (shouldOverlap) {
				mergeNoteIntoSprite(noteSpr, n);
			} else {
				if (!ghost) {
					++j;
					noteSpr = parent.drawNote(pos, n, diff, i);
				}
			}

			prev = n;
			prevTimeCorrection = i;
			++i;
		}
		timeSpentOnIt = haxe.Timer.stamp() - time;

		pos -= latencyI64;
	}

	function cullTop(pos:Int64) {
		var len = File.getLength();
		while (top != len) {
			var n = File.getNote(top);
			var tc = File.getTimeCorrectionForIndex(top);
			if ((n.position + tc) - pos >= spawnDist) break;

			n.flag = false;
			n.missed = false;
			n.held = false;
			File.setNote(top, n);

			++top;
		}

		if (top < len) curTopNote = File.getNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = File.getLength();
		while (bottom != len) {
			var n = File.getNote(bottom);
			var tc = File.getTimeCorrectionForIndex(bottom);

			// FIX: Use corrected position for despawn distance check
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - (n.position + tc);
			if (despawnCheck <= despawnDist) break;

			var notePool = parent.notePool;
			notePool.putNote(n, bottom);
			notePool.putSustain(n, bottom);

			++bottom;
		}

		if (bottom < len) curBottomNote = File.getNote(bottom);
	}

	// In NoteSpawner class, add this field:
	private var _skipCullNextFrame:Bool = false;

	function resetNotes(songPosition:Float) {
		var pf = parent.parent;
		if (pf.disposed || pf.died) return;

		// Optional: reset sprite pool if you add this method to NotePool
		// parent.notePool.reset();

		var len = File.getLength();
		if (len <= 0) return;

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var minPos:Int64 = songPos - spawnDist;
		var maxPos:Int64 = songPos;
		if (minPos < 0) minPos = 0;

		function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0, hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position + File.getTimeCorrectionForIndex(mid) < target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		function upperBound(target:Int64):Int64 {
			var lo:Int64 = 0, hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position + File.getTimeCorrectionForIndex(mid) <= target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		var newBottom = lowerBound(minPos);
		var newTop = upperBound(maxPos) - 1;

		// === EFFICIENT FIX: Reset hit state only for notes in the new window ===
		// This is O(window_size) — same cost as rendering, no extra overhead
		var i = newBottom;
		while (i < newTop + 1) {
			var n = File.getNote(i);
			// Only write back if state actually changed (avoids unnecessary File.setNote)
			if (n.flag || n.missed || n.held) {
				n.flag = false;
				n.missed = false;
				n.held = false;
				File.setNote(i, n);
			}
			i++;
		}
		// =====================================================================

		bottom = newBottom;
		top = newTop;

		curBottomNote = File.getNote(bottom);
		curTopNote = File.getNote(top);
		
		// Clear receptor states to avoid lingering animations
		parent.resetStrumlines();
    
		// === FIX: Skip culling on next update to preserve reset window ===
		_skipCullNextFrame = true;
	}

	// Now we're onto the real shit.

	/**
	 * Renders all notes in the current window.
	 * @param pos The current song position in note format.
	 */
	function renderNotes(pos:Int64) {
		var notes = parent.virtualNoteBuffer;

		renderVirtualNotes(notes, pos);
		renderVirtualSustains(notes);
	}

	// both of these arrays are used to easily render notes in the opposite order.
	var regularNoteList:Array<Note> = [];

	/**
	 * Renders virtual notes into actual note instances for rendering.
	 * This is separate from the main update loop onto the render loop to allow for optimizations, and most importantly, this function is separate for profiling.
	 * @param notes
	 */
	function renderVirtualNotes(notes:NoteVB, pos:Int64) {
		var downScroll = parent.parent.downScroll;
		var numIterations = 0;
		var virtualNotes = notes.notes;
		var averageNotesPerOne:Int64 = 0;
		for (i in 0...virtualNotes.length) {
			var lane = virtualNotes[i];
			var strumline = parent.strumlines[i];
			for (j in 0...lane.length) {
				var index = lane[j];
				var length = notes.noteLength[i][j];
				var id = parent.parent.inputSystem.receptorIds[j];
				var strumReceptor = strumline.buffer[j];
				var k = 0;
				if (length == 0) continue;
				while (k < length) {
					var increment = 1;
					var virtualNote:VirtualNote = index[k];

					if (virtualNote == null) {
						k += increment;
						continue;
					}

					var note = new Note(virtualNote.Sx, virtualNote.Sy, 0, 0, virtualNote.scale, virtualNote.initialAlpha, virtualNote.addedAlpha);
					note.diff = -virtualNote.diff;
					note.scrollDirection = strumReceptor.scrollDirection;
					if (downScroll) note.scrollDirection += 180;

					note.changeID(id);
					note.toNote();

					// This is here in order to fix the note still visible for the remaining time rendering or so when inputs are polled at an extemely high rate.
					var noteToHit = strumline.notesToHit[j];
					strumline.notesToHit_sprites[j] = noteToHit == virtualNote.ref ? note : null;

					regularNoteList.push(note);

					k += increment;
					numIterations++;
					averageNotesPerOne += 1;
				}
			}

			while (regularNoteList.length != 0) {
				var note = regularNoteList.pop();
				NoteSystem.notesBuf.addElement(note);
			}
		}
	}

	/**
	 * Renders virtual sustains into actual sustain instances for rendering.
	 * This function is separate for profiling.
	 * @param notes
	 */
	function renderVirtualSustains(notes:NoteVB) {
		var downScroll = parent.parent.downScroll;
		var virtualSustains = notes.sustains;
		var tailPoints = Sustain.tailPoints;
		for (i in 0...virtualSustains.length) {
			var lane = virtualSustains[i];
			var strumline = parent.strumlines[i];
			for (j in 0...lane.length) {
				var index = lane[j];
				var length = notes.sustainLength[i][j];
				var id = parent.parent.inputSystem.receptorIds[j];
				var strumReceptor = strumline.buffer[j];
				for (k in 0...length) {
					var virtualSustain:VirtualSustain = index[k];
					if (virtualSustain == null) continue;
					var sustain = new Sustain(virtualSustain.Sx, virtualSustain.Sy, virtualSustain.w, virtualSustain.h,
						virtualSustain.r, virtualSustain.speed, virtualSustain.scale, id, tailPoints[id]);
					sustain.length = virtualSustain.length;
					sustain.c.aF = virtualSustain.alpha;
					sustain.c.luminanceF = virtualSustain.alpha;
					sustain.diff = -virtualSustain.diff;
					sustain.scrollDirection = strumReceptor.scrollDirection;
					sustain.r = sustain.scrollDirection;
					if (downScroll) {
						sustain.r += 180;
						sustain.scrollDirection += 180;
					}
					sustain.changeID(id);
					NoteSystem.sustainsBuf.addElement(sustain);
				}
			}
		}
	}

	/**
	 * Checks if a note is a ghost (duplicate) of the previous note.
	 * @param prev The previous meta note.
	 * @param current The current meta note.
	 * @return True if the notes are duplicates.
	 */
	inline function isGhostNote(prev:MetaNote, current:MetaNote, prevIndex:Int64, curIndex:Int64):Bool {
		var prevCorrection = File.getTimeCorrectionForIndex(prevIndex);
		var curCorrection = File.getTimeCorrectionForIndex(curIndex);
		return prev != -1
			&& prev.position + prevCorrection == current.position + curCorrection
			&& prev.index == current.index
			&& prev.type == current.type;
	}

	/**
	 * Determines if two notes should visually overlap.
	 * @param prev The previous meta note.
	 * @param current The current meta note.
	 * @param noteSpr The current note sprite.
	 * @param receptor The receptor for this lane.
	 * @param newY The Y position of the current note.
	 * @param prevY The Y position of the previous note.
	 * @return True if notes should overlap and merge.
	 */
	inline function shouldNotesOverlap(prev:MetaNote, current:MetaNote, noteSpr:VirtualNote,
		receptor:Note, newY:Float, prevY:Float):Bool {

		if (noteSpr == null || prev == -1) return false;

		var OVERLAP_PIXEL_THRESHOLD = 0;

		// Calculate pixel difference accounting for resolution scaling
		var pixelDiff = Math.abs(
			Math.floor(newY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)) -
			Math.floor(prevY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))
		);

		// Check all overlap requirements
		return pixelDiff <= OVERLAP_PIXEL_THRESHOLD
			&& prev.type == current.type
			&& noteSpr.scale == receptor.scale
			&& prev.duration == current.duration
			&& prev.index == current.index;
	}

	/**
	 * Merges a note into an existing sprite by increasing its alpha.
	 * @param noteSpr The note sprite to merge into.
	 * @param n The meta note being merged.
	 */
	inline function mergeNoteIntoSprite(noteSpr:VirtualNote, n:MetaNote) {
		var alphaToAdd = n.missed ? Note.defaultMissAlpha : Note.defaultAlpha;
		noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
		noteSpr.notesInOne++;
	}
}
