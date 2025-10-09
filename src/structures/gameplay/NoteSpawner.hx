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
		var i = bottom;

		var prev:Null<MetaNote> = null;

		while (i < top) {
			var n = File.getNote(i);

			// --- lane/receptor/fake storage lookups ---
			var lane = parent.noteTypeFunctionalityPre.exists(n.type) ? 1 : (n.type % parent.strumlines.length);
			var strumline = parent.strumlines[lane];
			var receptor = strumline.buffer[n.index];

			// init greedyMergeTemp subarray if null
			if (strumline.greedyMergeTemp[n.index] == null) {
				strumline.greedyMergeTemp[n.index] = [];
			}

			var greedyMergeLane = strumline.greedyMergeTemp[n.index];
			var fakeOverlapStorage = strumline.fakeOverlapStorage;

			// --- compute diff and newY ---
			var diff = MetaNote.metaNotePositionToSongTime(n.position - pos) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);

			// --- fake-overlap storage for next comparisons ---
			var prevY = (prev != null) ? fakeOverlapStorage[prev.index] : -99999;
			var OVERLAP_PIXEL_THRESHOLD = 0;

			// Get the last drawn sprite for fake overlap checking
			var currentSprite:Null<Note> = null;

			var requirementsForFakeOverlap = prev != null
				&& greedyMergeLane.length > 0
				&& (Math.abs(Math.floor(newY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))
						- Math.floor(prevY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))) <= OVERLAP_PIXEL_THRESHOLD)
				&& prev.type == n.type
				&& prev.index == n.index
				&& prev.duration == n.duration;

			var ghost = prev != null && prev.position == n.position && prev.index == n.index && prev.type == n.type;

			fakeOverlapStorage[n.index] = newY;

			var lastCmd = greedyMergeLane[greedyMergeLane.length - 1];

			// Check if current note is compatible with previous note for greedy merging
			var canGreedyMerge = prev != null
				&& prev.type == n.type
				&& prev.duration == n.duration
				&& prev.index == n.index
				&& prev.position != n.position
				&& !requirementsForFakeOverlap
				//&& (lastCmd != null && lastCmd.notesInOne >= 1) breaks all together
				&& !ghost;

			if (requirementsForFakeOverlap && greedyMergeLane.length != 0) {
				// Add to existing greedy batch's alpha/count
				lastCmd.addedAlpha += (n.missed ? Note.defaultMissAlpha : Note.defaultAlpha);
				lastCmd.notesInOne++;
			} else if (ghost && greedyMergeLane.length != 0) {
				// Add to existing greedy batch's count only
				lastCmd.notesInOne++;
				prev = n;
				++i;
				continue;
			} else if (canGreedyMerge) {
				// Add current note to greedy merge queue
				greedyMergeLane.push({
					n: n,
					diff: diff,
					id_: i,
					pos: pos,
					notesInOne: 1,
					addedAlpha: (n.missed ? Note.defaultMissAlpha : Note.defaultAlpha)
				});

				// If this is the first note in the queue, draw it immediately
				// Subsequent compatible notes will be batched with it
				if (greedyMergeLane.length == 1) {
					currentSprite = parent.drawNote(pos, n, diff, i);
				}

				// Flush and draw if 16 notes accumulated
				if (greedyMergeLane.length >= 16) {
					var firstData:NoteCmd = greedyMergeLane[0];
					currentSprite = parent.drawNote(firstData.pos, firstData.n, firstData.diff, firstData.id_);
					currentSprite.notesInOne = 1;
					currentSprite.addedAlpha = 0;
					for (cmd in greedyMergeLane) {
						currentSprite.notesInOne += cmd.notesInOne;
						currentSprite.addedAlpha += cmd.addedAlpha;
					}
					greedyMergeLane.resize(0);
				}
			} else {
				// Not compatible - flush any existing batch first
				if (greedyMergeLane.length > 0) {
					var firstData:NoteCmd = greedyMergeLane[0];
					for (cmd in greedyMergeLane) {
						currentSprite = parent.drawNote(cmd.pos, cmd.n, cmd.diff, cmd.id_);
						// Reset to individual note defaults
						currentSprite.notesInOne = 1;
						currentSprite.addedAlpha = 0;
					}
					greedyMergeLane.resize(0);
				}

				// Draw current note normally
				currentSprite = parent.drawNote(pos, n, diff, i);
				// Reset to individual note defaults
				currentSprite.notesInOne = 1;
				currentSprite.addedAlpha = 0;
			}

			prev = n;
			++i;
		}

		// --- flush remaining greedy notes at the end ---
		for (lane in 0...parent.strumlines.length) {
			var strumline = parent.strumlines[lane];
			for (index in 0...strumline.greedyMergeTemp.length) {
				var greedyQueue = strumline.greedyMergeTemp[index];
				if (greedyQueue != null && greedyQueue.length > 0) {
					var firstData:NoteCmd = greedyQueue[0];
					var sprite = parent.drawNote(firstData.pos, firstData.n, firstData.diff, firstData.id_);
					sprite.notesInOne = 1;
					sprite.addedAlpha = 0;
					for (cmd in greedyQueue) {
						sprite.notesInOne += cmd.notesInOne;
						sprite.addedAlpha += cmd.addedAlpha;
					}
					greedyQueue.resize(0);
				}
			}
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
}