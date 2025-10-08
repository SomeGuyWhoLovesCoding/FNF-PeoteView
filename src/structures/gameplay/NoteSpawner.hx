package structures.gameplay;

/**
	The note render command class.
	This is used for the rendering queue.
	@since Development
**/
@:structInit
@:publicFields
class NoteCmd {
	var data:MetaNote;
	var x:Int;
	var y:Int;
	var notesInOne:Int64;
	var greedyMerge:Bool; // false = 1x, true = 128x
	var addedAlpha:Float;
	var id_:Int64;
	var diff:Float;
}

/**
	The note render command queue class.
	This is an isolated class because a nobody else does note render queues. Hell, it might be useful for greedy note merging.
	@since Development
**/
@:publicFields
class NoteQueue {
	var _queue(default, null):Array<Array<Array<NoteCmd>>>;

	var parent(default, null):NoteSystem;

	function new(parent:NoteSystem) {
		this.parent = parent;

		_queue = [for (i in 0...parent.strumlines.length) {
			[for (j in 0...parent.strumlines[i].buffer.length) []];
		}];
	}

	inline function addToQueue(n:NoteCmd, lane:Int) {
		_queue[lane][n.data.index].push(n);
	}

	function run(pos:Int64) {
		for (i in 0..._queue.length) { // base
			var queueLane = _queue[i];
			for (j in 0...queueLane.length) { // lane
				var queueIndex = queueLane[i];
				for (k in 0...queueIndex.length) { // index
					while (queueIndex.length != 0) {
						var noteSpr = queueIndex.pop();
						parent.drawNote(pos, noteSpr.data, noteSpr.diff, noteSpr.id_, noteSpr.x, noteSpr.y, noteSpr.notesInOne, noteSpr.addedAlpha);
					}
				}
			}
		}
	}
}

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

	var queue(default, null):NoteQueue;

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

		queue = new NoteQueue(parent);
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
		//Sys.println('Why');
		//var pos = MetaNote.floatToMetaNotePosition(songPosition);
		//Sys.println('Song Position ${parent.parent.songPosition}, MetaNote Song Position ${MetaNote.metaNotePositionToSongTime(pos)}');

		cacheHotWindow();

		_lastbottom = bottom;
		_lasttop = top;

		cullTop(pos);
		cullBottom(pos);

		cacheHotWindow2();

		//Sys.println('Top $top bottom $bottom');

		var i = bottom;

		var scrollSpeed = parent.parent.scrollSpeed;
		var diff = 0.0;
		var noteY = 0;
		var noteSpr:NoteCmd = null;

		var prev:Null<MetaNote> = null;
		while (i < top) {
			var n = File.getNote(i);

			// lane/receptor/fake storage lookups
			var lane = parent.noteTypeFunctionalityPre.exists(n.type) ? 1 : (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = parent.strumlines[lane].fakeOverlapStorage;

			// compute diff/newY for this note FIRST (important!)
			diff = MetaNote.metaNotePositionToSongTime((n.position - pos)) * scrollSpeed;
			var newX = receptor.x;
			var newY = receptor.y + Math.floor(parent.parent.downScroll ? -diff : diff);

			// update fake storage for this index now that we have the current computed Y
			// (we'll still use prev's stored value to decide overlap)
			// but delay writing it until after overlap decision? Either way, compare against prev value below.
			// We'll not overwrite it yet so prev comparison can use the prior prev value:
			// fakeOverlapStorage[n.index] = newY; // only write after deciding not to merge

			// safe ghost check (ensure prev exists)
			var ghost = (prev != null) && prev.position == n.position && prev.index == n.index && prev.type == n.type;

			// small pixel threshold: how many pixels difference still counts as overlapping
			// tune this to taste; 0 requires exact same floored pixel, 1 allows a 1-pixel gap, etc.
			var OVERLAP_PIXEL_THRESHOLD = 0;

			// compute prevY only if prev exists
			var prevY = (prev != null) ? fakeOverlapStorage[prev.index] : -99999;

			// requirements: only consider fake-overlap if we actually have a note sprite and a prev to compare with
			var requirementsForNoteOverlapSimulationBS = noteSpr != null
				&& prev != null
				&& (Math.abs(Math.floor(newY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)) - Math.floor(prevY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))) <= OVERLAP_PIXEL_THRESHOLD)
				&& (prev.type == n.type)
				&& (prev.index == n.index)
				&& (prev.duration == n.duration)
				&& (noteSpr.x == receptor.x);

			// now write the computed Y into fake overlap storage (so next notes compare to this)
			fakeOverlapStorage[n.index] = newY;

			if (requirementsForNoteOverlapSimulationBS) {
				// treat as overlap: merge into existing sprite
				noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + (n.missed ? Note.defaultMissAlpha : Note.defaultAlpha), 254);
				noteSpr.notesInOne++;
				parent.resolveNoteLogic(lane, pos, n, diff, i, 1);
				prev = n;
				++i;
				continue;
			} else {
				if (!ghost) {
					noteSpr = {
						data: parent.resolveNoteLogic(lane, pos, n, diff, i, 1),
						x: newX, y: newY,
						notesInOne: 1, greedyMerge: false, addedAlpha: 0,
						id_: i, diff: diff
					}; //parent.drawNote(pos, n, diff, i);
					queue.addToQueue(noteSpr, lane);
				} else {
					// ghost -> same exact meta-note (position, index, type) so just increment
					noteSpr.notesInOne++;
				}
				prev = n;
				++i;
			}
		}

		queue.run(pos);
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