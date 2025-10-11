package structures.gameplay;

/**
	The internal note handler.
	This class is responsible for spawning and despawning notes based on the song's position.
	It handles the culling of notes that are too far away from the current position, and it draws the notes that are within the spawn distance.
	It also handles the resetting of notes when the song position changes significantly.
	@since Development
**/
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;

	var _lastbottom:Int64;
	var _lasttop:Int64;

	var spawnDist:Int64 = MetaNote.floatToMetaNotePosition(1600);
	var despawnDist:Int64 = MetaNote.floatToMetaNotePosition(300);

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note spawner.
	 * @param parent The note system to implement this note spawner on.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;

		bottom = 0;
		top = 0;

		curTopNote = File.getNote(0);
		curBottomNote = File.getNote(0);

		/*for (i in 0...File.getLength().low) {
			var note = File.getNote(i);
			var position = note.position;
			var duration = note.duration;
			var index = note.index;
			var type = note.type;
			trace('Position: $position, Duration: $duration, Index: $index, Type: $type');
		}*/
	}

	// before updating / drawing notes
	// Doing this in a contiguous range ensures tens of thousands of notes in a hot zone are already resident before the loop.
	// You don't need to loop through every note in the file, only the nearby window.
	function cacheHotWindow() {
		var len = File.getLength();
		if (len <= 0) return;

		var cacheStart = bottom - 8192;  // back-fill 8192 notes
		if (cacheStart < 0) cacheStart = 0;
		var cacheEnd   = top + 8192;  // forward-fill a bit
		if (cacheEnd > len) cacheEnd = len - 1;

		var i = cacheStart;
		while (i < cacheEnd) {
			File.getNote(++i);  // accessing the note touches the page
		}
	}

	// after updating (to cache more)
	function cacheHotWindow2() {
		var len = File.getLength();
		if (len <= 0) return;

		var threshold = (bottom - _lastbottom) * 3;
		var cacheStart = bottom - threshold;  // back-fill 8192 notes
		if (cacheStart < 0) cacheStart = 0;
		var cacheEnd   = top + threshold;  // forward-fill a bit
		if (cacheEnd > len) cacheEnd = len - 1;

		var i = cacheStart;
		while (i < cacheEnd) {
			File.getNote(++i);  // accessing the note touches the page
		}
	}

	/**
	 * Updates the note spawner.
	 * @param pos The song's position in the note position format.
	 */
	function update(pos:Int64) {
		cacheHotWindow();

		_lastbottom = bottom;
		_lasttop = top;

		cullTop(pos);
		cullBottom(pos);

		cacheHotWindow2();

		var scrollSpeed = parent.parent.scrollSpeed;
		var strumlines = parent.strumlines;
		var laneCount = strumlines.length;
		var indexCount = 128; // assuming 128 per strumline, adjust if needed

		// Pre-allocate logical merge arrays
		var mergedNoteCount:Array<Array<Int>> = [];
		var mergedAlpha:Array<Array<Float>> = [];
		for (lane in 0...laneCount) {
			mergedNoteCount[lane] = [];
			mergedAlpha[lane] = [];
			mergedNoteCount[lane].resize(strumlines[lane].buffer.length);
			mergedAlpha[lane].resize(strumlines[lane].buffer.length);
		}

		var i = bottom;
		var prev:Null<MetaNote> = null;

		while (i < top) {
			var n = File.getNote(i);

			var lane = parent.noteTypeFunctionalityPre.exists(n.type) ? 1 : (n.type % laneCount);
			var rec = strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = strumlines[lane].fakeOverlapStorage;

			var diff = MetaNote.metaNotePositionToSongTime(n.position - pos) * scrollSpeed;
			if (parent.parent.downScroll) diff = -diff;
			var newY = rec.y + Std.int(diff);

			var prevY = (prev != null) ? fakeOverlapStorage[prev.index] : -99999;
			var OVERLAP_PIXEL_THRESHOLD = 0;
			var overlap = prev != null
				&& prev.type == n.type
				&& Math.abs(newY - prevY) <= OVERLAP_PIXEL_THRESHOLD;

			if (overlap) {
				mergedNoteCount[lane][n.index]++;
				mergedAlpha[lane][n.index] = Math.min(254, mergedAlpha[lane][n.index] + (n.missed ? Note.defaultMissAlpha : Note.defaultAlpha));
			} else {
				mergedNoteCount[lane][n.index] = 1;
				mergedAlpha[lane][n.index] = n.missed ? Note.defaultMissAlpha : Note.defaultAlpha;
			}

			var createSprite = true; // or your existing conditional
			var noteSpr:Null<Note> = null;
			if (createSprite) {
				noteSpr = parent.drawNote(pos, n, diff, i, true);
				noteSpr.notesInOne = mergedNoteCount[lane][n.index];
				noteSpr.addedAlpha = mergedAlpha[lane][n.index];
			}

			fakeOverlapStorage[n.index] = newY;
			prev = n;
			++i;
		}
	}


	/**
	 * Culls the top note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullTop(pos:Int64) {
		var len = File.getLength();
		//Sys.println('Top song position ${MetaNote.metaNotePositionToSongTime(pos)}, Song position: $songPosition');
		//Sys.println('Top note position ${curTopNote.position}');
		//Sys.println('TOP: ' + (curTopNote.position - pos));
		//Sys.println('Top ${curTopNote.position - pos}');
		//Sys.println('Pos: $pos');
		//Sys.println(top != len && curTopNote.position - pos < spawnDist);
		while (top != len && curTopNote.position - pos < spawnDist) {
			++top;
			var n:Int64 = File.getNote(top).toNumber();
			(n:MetaNote).flag = false;
			(n:MetaNote).missed = false;
			(n:MetaNote).held = false;
			File.setNote(top, n);
			curTopNote = n;
		}
	}

	/**
	 * Culls the bottom note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullBottom(pos:Int64) {
		var len = File.getLength();
		//Sys.println('BOTTOM: ' + ((pos - MetaNote.intToMetaNoteDuration(curBottomNote.duration)) - curBottomNote.position));
		//Sys.println('Bottom song position $pos');
		//Sys.println('Bottom note position ${curBottomNote.position}');
		//Sys.println('Bottom ${curBottomNote.position - pos}');
		while (bottom != len && (pos - MetaNote.intToMetaNoteDuration(curBottomNote.duration)) - curBottomNote.position > despawnDist) {
			var notePool = parent.notePool;
			notePool.putNote(curBottomNote, bottom);
			notePool.putSustain(curBottomNote);

			++bottom;

			curBottomNote = File.getNote(bottom);
		}
	}

	/**
	 * Reload the notes.
	 * @param songPosition The time from the song.
	 */
	function resetNotes(songPosition:Float) {
		var pf = parent.parent;
		if (pf.disposed || pf.died) return;

		var i = bottom;
		while (i < top) {
			var note = File.getNote(i);
			note.flag = false;
			note.missed = false;
			note.held = false;
			File.setNote(i, note);
			i++;
		}

		var len = File.getLength();
		if (len <= 0) return; // no notes, nothing to do

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var songPosTop = songPos + spawnDist;

		// --- Fast check: before first note ---
		var firstNote = File.getNote(0);
		if (firstNote.position > songPosTop || firstNote.position > songPos) {
			top = bottom = 0;
			curBottomNote = curTopNote = firstNote;
			parent.resetStrumlines();
			return;
		}

		// --- Fast check: after last note ---
		var lastNote = File.getNote(len - 1);
		if (lastNote.position < songPos) {
			// clamp to last note so we don't freeze
			top = bottom = len - 1;
			curBottomNote = curTopNote = lastNote;
			parent.resetStrumlines();
			return;
		}

		// --- Binary search helpers ---
		inline function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0;
			var hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position < target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}
		inline function upperBound(target:Int64):Int64 {
			var lo:Int64 = 0;
			var hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position <= target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		// --- Find bottom (first note >= songPos) ---
		bottom = lowerBound(songPos);
		if (bottom >= len) bottom = len - 1;

		// --- Find top (last note <= songPosTop) ---
		top = upperBound(songPosTop) - 1;
		if (top < 0) top = 0;

		curBottomNote = File.getNote(bottom);
		curTopNote = File.getNote(top);

		parent.resetStrumlines();
	}

	/**
	 * Floors the given value by pixels.
	 * @param value The value to floor.
	 * @return The floored value.
	 */
	function floorByPixels(value:Float):Int {
		var dividend = (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT);
		return Math.floor(Math.floor(value / dividend) * dividend);
	}

	private var zero(default, null):Int64 = 0;
}