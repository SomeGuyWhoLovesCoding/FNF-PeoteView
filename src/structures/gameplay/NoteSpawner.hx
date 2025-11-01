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

	var spawnDist:Int64 = MetaNote.floatToMetaNotePosition(1300);
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

		/*for (i in 0...200) {
			var note = File.getNote(i);
			Sys.println('${note.position}, ${note.duration}, ${note.index}, ${note.type}');
		}*/
	}

	/**
	 * Updates the note spawner.
	 * @param pos The song's position in the note position format.
	 */
	function update(pos:Int64) {
		// Store previous bounds for cache optimization
		_lastbottom = bottom;
		_lasttop = top;

		// Update note boundaries
		cullTop(pos);
		cullBottom(pos);

		// Process notes in current window
		processNotes(pos);
	}

	var timeSpentOnIt:Float = 0;

	/**
	 * Processes all notes in the current window.
	 * @param pos The current song position in note format.
	 */
	function processNotes(pos:Int64) {
		var i = bottom;
		var scrollSpeed = parent.parent.scrollSpeed;
		var prev:MetaNote = -1;
		var noteSpr:VirtualNote = null;

		//var time = haxe.Timer.stamp();
		while (i < top) {
			var n = File.getNote(i);

			// Get lane and receptor information
			var lane = parent.noteTypeFunctionalityPre[n.type] != null
				? 1
				: (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = parent.strumlines[lane].fakeOverlapStorage;

			// Calculate note position
			var diff = MetaNote.metaNotePositionToSongTime((n.position - pos)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);

			// Check if this is a ghost note
			var ghost = isGhostNote(prev, n);

			// Determine if notes should overlap
			var shouldOverlap = shouldNotesOverlap(prev, n, noteSpr, receptor, newY,
				fakeOverlapStorage[prev != -1 ? prev.index : -1]) && !ghost;

			// Update fake overlap storage for next iteration
			fakeOverlapStorage[n.index] = newY;

			if (shouldOverlap) {
				// Merge into existing sprite
				mergeNoteIntoSprite(noteSpr, n);
			} else {
				if (!ghost) {
					noteSpr = parent.drawNote(pos, n, diff, i);
					noteSpr.notesInOne = 0; // don't forget this!
				} else {
					// Ghost note - same meta-note, just increment counter
					noteSpr.notesInOne++;
				}
			}

			prev = n;
			++i;
		}

		//timeSpentOnIt = haxe.Timer.stamp() - time;
	}

	/**
	 * Renders all notes in the current window.
	 * @param pos The current song position in note format.
	 */
	function renderNotes(pos:Int64) {
		var notes = parent.virtualNoteBuffer;

		renderVirtualNotes(notes);
		renderVirtualSustains(notes);
	}

	/**
	 * Renders virtual notes into actual note instances for rendering.
	 * This is separate from the main update loop onto the render loop to allow for optimizations, and most importantly, this function is separate for profiling.
	 * @param notes
	 */
	function renderVirtualNotes(notes:NoteVB) {
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
				while (k < length) {
					var increment = 1;
					var virtualNote:VirtualNote = index[k];
					if (virtualNote == null) continue;

					// but wait! hold on! do some note rendering optims just in case of a spamtrack real quick

					//// greedy note merging (16x) ////

					// Prevent branch misprediction with like—anything to be completely honest I am very proud I did this
					if (greedyMergeNearlyNotes(virtualNote, index, strumReceptor, k, 32, 2)) {
						increment = 32;
					}

					if (greedyMergeNearlyNotes(virtualNote, index, strumReceptor, k, 64, 1)) {
						increment = 64;
					}

					//// finally, do it. ////

					var note = new Note(-99999, -99999, 0, 0);
					note.x = virtualNote.x;
					note.y = virtualNote.y;
					note.w = virtualNote.w;
					note.h = virtualNote.h;
					note.scale = virtualNote.scale;

					note.initialAlpha = virtualNote.initialAlpha;
					note.addedAlpha = virtualNote.addedAlpha;

					if (virtualNote.greedyMergeAlphaMultiplier != 0) {
						note.toggleGMAlphaMult(virtualNote.greedyMergeAlphaMultiplier);
						note.initialAlpha = 1;
						note.addedAlpha = 0;
					}

					note.changeID(id);
					note.toNote();
					NoteSystem.notesBuf.addElement(note);

					k += increment;
					numIterations++;
					averageNotesPerOne += virtualNote.greedyMergeAlphaMultiplier;
				}
			}

			var zero = notes.noteLength[0][2];
			if (zero == 0) zero = 1;
		}
	}

	/**
	 * Renders virtual sustains into actual sustain instances for rendering.
	 * This function is separate for profiling.
	 * @param notes
	 */
	function renderVirtualSustains(notes:NoteVB) {
		var virtualSustains = notes.sustains;
		for (i in 0...virtualSustains.length) {
			var lane = virtualSustains[i];
			for (j in 0...lane.length) {
				var index = lane[j];
				var length = notes.sustainLength[i][j];
				var id = parent.parent.inputSystem.receptorIds[j];
				for (k in 0...length) {
					var virtualSustain:VirtualSustain = index[k];
					if (virtualSustain == null) continue;
					var sustain = new Sustain(-99999, -99999, 0, 0);
					sustain.x = virtualSustain.x;
					sustain.y = virtualSustain.y;
					sustain.w = virtualSustain.w;
					sustain.h = virtualSustain.h;
					sustain.r = virtualSustain.r;
					sustain.scale = virtualSustain.scale;
					sustain.length = virtualSustain.length;
					sustain.speed = virtualSustain.speed;
					sustain.c.aF = virtualSustain.alpha;
					sustain.c.luminanceF = virtualSustain.alpha;
					sustain.changeID(id);
					NoteSystem.sustainsBuf.addElement(sustain);
				}
			}
		}
	}

	/**
	 * Greedily merges nearly identical (already-overlapped) notes to optimize rendering.
	 * This checks up to `count` notes ahead to see if they can be merged.
	 * @param virtualNote The virtual note to attempt merging on.
	 * @param index The array of virtual notes in the current lane/index.
	 * @param strumReceptor The strum receptor for this lane/index.
	 * @param k The current index in the virtual notes array.
	 * @param count The number of notes to check for merging.
	 * @return True if merging was successful.
	 */
	function greedyMergeNearlyNotes(virtualNote:VirtualNote, index:Array<VirtualNote>, strumReceptor:Note, k:Int, count:Int = 16, granularity:Int = 2):Bool {
		// Check bounds first
		if (k + count >= index.length) return false;

		var check = true;
		if (!check) return false;

		if (virtualNote.greedyMergeAlphaMultiplier == 0) {
			var yToUse:Float = 0;
			var notesInOneMerged:Int64 = 0;

			for (g in 0...count) {
				var virtualNote2:VirtualNote = index[k + g];
				var nextNote:VirtualNote = index[k + g + 1];
				if (virtualNote2 == null || nextNote == null) return false;  // Changed from break

				var yCompare = virtualNote2.y - nextNote.y;
				if (yCompare < 0) yCompare = -yCompare;

				var notesInOneCompare = virtualNote2.notesInOne - nextNote.notesInOne;
				if (notesInOneCompare < 0) notesInOneCompare = -notesInOneCompare;

				var check1 = yCompare <= granularity;
				var check2 = notesInOneCompare <= 2;

				yToUse += yCompare;
				notesInOneMerged += virtualNote2.notesInOne;

				if (nextNote.notesInOne == 1 && (!check1 || !check2)) {
					return false;
				}
			}

			yToUse /= count;
			notesInOneMerged /= count;

			if (notesInOneMerged > Note.maxGMAlphaMult) notesInOneMerged = Note.maxGMAlphaMult;

			// If we got here, all checks passed
			virtualNote.greedyMergeType = Math.floor(yToUse);
			virtualNote.greedyMergeAlphaMultiplier = Int64.toInt(notesInOneMerged);
		}
		return true;
	}

	/**
	 * Checks if a note is a ghost (duplicate) of the previous note.
	 * @param prev The previous meta note.
	 * @param current The current meta note.
	 * @return True if the notes are duplicates.
	 */
	inline function isGhostNote(prev:MetaNote, current:MetaNote):Bool {
		return prev != -1
			&& prev.position == current.position
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
			&& noteSpr.x == receptor.x;
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

	/**
	 * Culls the top note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullTop(pos:Int64) {
		var len = File.getLength();
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