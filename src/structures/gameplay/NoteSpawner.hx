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

			var lane = parent.noteTypeFunctionalityPre[n.type] != null
				? 1
				: (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = parent.strumlines[lane].fakeOverlapStorage;

			// Calculate note position
			var diff = MetaNote.metaNotePositionToSongTime((n.position - pos)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);

			var ghost = isGhostNote(prev, n);

			var shouldOverlap = shouldNotesOverlap(prev, n, noteSpr, receptor, newY,
				fakeOverlapStorage[prev != -1 ? prev.index : -1]) && !ghost;

			fakeOverlapStorage[n.index] = newY;

			if (shouldOverlap) {
				mergeNoteIntoSprite(noteSpr, n);
			} else {
				if (!ghost) {
					noteSpr = parent.drawNote(pos, n, diff, i);
				} // fuck ghost notes, don't increment notesInOne on that one
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

		renderVirtualNotes(notes, pos);
		renderVirtualSustains(notes);
	}

	// both of these arrays are used to easily render notes in the opposite order.
	var regularNoteList:Array<Note> = [];
	var greedyMergedNoteList:Array<Note> = [];

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
					var granularity = 1;
					var virtualNote:VirtualNote = index[k];
					var greedyMerged:Bool = false;

					if (virtualNote == null) {
						k += increment;
						continue;
					}

					// We're cool now I think?
					if (virtualNote.y < virtualNote.h - 10 || virtualNote.y > Main.current.peoteView.height + 10) {
						k += increment;
						continue;
					}

					// but wait! hold on! do some note rendering optims just in case of a spamtrack real quick

					//// greedy note merging (64x) ////

					if (Note.enableGM) {
						greedyMerged = greedyMergeNearlyNotes(virtualNote, index, k, 64); //????????????
						if (greedyMerged) {
							increment = 64;
						}
					}

					//// finally, do it. ////

					var note = new Note(virtualNote.x, virtualNote.y, 0, 0);
					note.w = virtualNote.w;
					note.h = virtualNote.h;
					note.scale = virtualNote.scale;

					note.initialAlpha = virtualNote.initialAlpha;
					note.addedAlpha = virtualNote.addedAlpha;

					note.changeID(id);
					note.toNote();
					//@:privateAccess trace('Regular note: x=${note.clipX}, y=${note.clipY}, w=${note.clipWidth}, h=${note.clipHeight}');

					if (Note.enableGM && greedyMerged && virtualNote.greedyMergeAlphaMultiplier != 0 && virtualNote.greedyMergeType != 0) {
						var h = note.h;
						note.toggleGMVariant(granularity, false);
						//@:privateAccess trace('GM variant: x=${note.clipX}, y=${note.clipY}, w=${note.clipWidth}, h=${note.clipHeight}');
						note.initialAlpha = Note.defaultAlpha;
						note.addedAlpha = 0;
						
						if (downScroll) {
							// Move to where the last note would be, then adjust for sprite height
							//note.y -= virtualNote.greedyMergeType;  // Move to last note
							note.y -= note.h - h;  // Adjust so bottom of sprite is there
							//note.y -= h;  // Subtract original note height to align properly
						}
						//note.x += Math.floor(MetaNote.metaNotePositionToSongTime(virtualNote.ref.position - pos) * 0.08);
						greedyMergedNoteList.push(note);
					} else {
						regularNoteList.push(note);
					}

					k += increment;
					numIterations++;
					averageNotesPerOne += virtualNote.greedyMergeAlphaMultiplier;
				}
			}

			while (regularNoteList.length != 0) {
				var note = regularNoteList.pop();
				NoteSystem.notesBuf.addElement(note);
			}

			while (greedyMergedNoteList.length != 0) {
				var note = greedyMergedNoteList.pop();
				NoteSystem.notesBuf.addElement(note);
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

	// TODO; ENGINEER THIS SHIT TO HANDLE MIXED 1-2PX DISTANCES IN A 64PX VERTICAL BOUNDARY
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
	function greedyMergeNearlyNotes(virtualNote:VirtualNote, index:Array<VirtualNote>, k:Int, count:Int = 16):Bool {
		// Check bounds first
		if (k + count >= index.length) return false;

		var firstNote = index[k];
		var lastNote = index[k + count - 1];
		
		if (firstNote == null || lastNote == null) return false;
		
		// Check total span
		var totalSpan = firstNote.y - lastNote.y;
		if (totalSpan < 0) totalSpan = -totalSpan;
		
		var maxAllowedSpan = count;
		
		if (totalSpan > maxAllowedSpan) return false;
		
		var yToUse:Float = 0;
		var notesInOneMerged:Int64 = 0;

		for (g in 0...count) {
			var virtualNote2:VirtualNote = index[k + g];
			var nextNote:VirtualNote = index[k + g + 1];
			if (virtualNote2 == null || nextNote == null) return false;

			var yCompare = virtualNote2.y - nextNote.y;
			if (yCompare < 0) yCompare = -yCompare;

			var notesInOneCompare = virtualNote2.notesInOne - nextNote.notesInOne;
			if (notesInOneCompare < 0) notesInOneCompare = -notesInOneCompare;

			var check1 = yCompare == 1;
			var check2 = notesInOneCompare <= 2;

			yToUse += yCompare;
			notesInOneMerged += virtualNote2.notesInOne;

			if (nextNote.notesInOne == 1 && (!check1 || !check2)) {
				return false;
			}
		}

		yToUse /= count;
		notesInOneMerged /= count;

		// ADD THESE LINES BACK:
		virtualNote.greedyMergeType = Math.floor(totalSpan);
		virtualNote.greedyMergeAlphaMultiplier = Int64.toInt(notesInOneMerged);
		
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

		var len = File.getLength();
		if (len <= 0) return;

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var minPos:Int64;
		var maxPos:Int64;

		minPos = songPos - spawnDist;
		maxPos = songPos;

		if (minPos < 0) minPos = 0;

		// --- Binary search helpers ---
		function lowerBound(target:Int64):Int64 {
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

		function upperBound(target:Int64):Int64 {
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

		// --- Determine indices ---
		bottom = lowerBound(minPos);
		top = upperBound(maxPos) - 1;

		if (bottom < 0) bottom = 0;
		else if (bottom >= len) bottom = len - 1;

		if (top < 0) top = 0;
		else if (top >= len) top = len - 1;

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