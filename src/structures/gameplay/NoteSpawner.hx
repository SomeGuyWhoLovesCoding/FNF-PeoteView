package structures.gameplay;

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

	// --- Fixed-size sliding cache ---
	var noteCache:Array<MetaNote> = [];
	var cacheStart:Int64 = 0;
	var cacheSize:Int64 = 1048576; // ~1MB cache (assuming ~4 bytes per MetaNote)
	var maxCacheSize:Int64 = 1048576; // Hard limit

	function new(parent:NoteSystem) {
		this.parent = parent;

		bottom = 0;
		top = 0;

		loadCache(0, cacheSize);
		curTopNote = noteCache[0];
		curBottomNote = noteCache[0];
	}

	// --- Load cache with fixed size window ---
	function loadCache(startIdx:Int64, size:Int64) {
		var len = File.getLength();
		if (startIdx >= len) {
			noteCache = [];
			cacheStart = startIdx;
			return;
		}

		cacheStart = startIdx;
		
		var newNotes:Array<MetaNote> = [];
		var maxLoad = len - startIdx;
		if (maxLoad > size) maxLoad = size;
		if (maxLoad < 0) maxLoad = 0;

		var i:Int64 = 0;
		while (i < maxLoad) {
			// Initialize the note once
			var n = File.getNote(startIdx + i);
			n.flag = false;
			n.missed = false;
			n.held = false;
			newNotes.push(n);
			i++;
		}

		noteCache = newNotes;
	}

	// --- Get note from cache; slide window if needed ---
	function getCachedNote(idx:Int64):MetaNote {
		var cacheIdx = idx - cacheStart;
		
		// Check if index is within current cache bounds
		if (cacheIdx >= 0 && cacheIdx < noteCache.length) {
			return noteCache[Int64.toInt(cacheIdx)];
		}

		var len = File.getLength();
		if (idx >= len) return -1;

		// If index is outside cache, slide the window
		var newStart = idx;
		var newSize = cacheSize;
		
		// If we're looking far ahead, center the cache around the requested index
		if (idx > cacheStart + noteCache.length) {
			newStart = idx;
		} 
		// If we're looking behind, center the cache to include both old and new areas
		else if (idx < cacheStart) {
			newStart = idx;
		}
		
		// Ensure we don't go beyond file bounds
		if (newStart < 0) newStart = 0;
		if (newStart + newSize > len) {
			newSize = len - newStart;
		}
		
		loadCache(newStart, newSize);
		
		// Now get from new cache
		cacheIdx = idx - cacheStart;
		if (cacheIdx >= 0 && cacheIdx < noteCache.length) {
			return noteCache[Int64.toInt(cacheIdx)];
		}
		
		return -1;
	}

	// --- Set note in cache ---
	function setCachedNote(idx:Int64, value:MetaNote):MetaNote {
		var cacheIdx = idx - cacheStart;
		
		if (cacheIdx >= 0 && cacheIdx < noteCache.length) {
			noteCache[Int64.toInt(cacheIdx)] = value;
			return value;
		}

		// If outside cache, ensure it's loaded then set
		getCachedNote(idx);
		cacheIdx = idx - cacheStart;
		if (cacheIdx >= 0 && cacheIdx < noteCache.length) {
			noteCache[Int64.toInt(cacheIdx)] = value;
		}
		return value;
	}

	// --- Smart cache management ---
	function manageCache() {
		var len = File.getLength();
		
		// Calculate ideal cache window centered around current play area
		var center = (bottom + top) >> 1;
		var cachePadding = cacheSize >> 2; // Keep some padding on both sides
		
		var idealStart = center - cachePadding;
		if (idealStart < 0) idealStart = 0;
		
		var idealEnd = idealStart + cacheSize;
		if (idealEnd > len) {
			idealEnd = len;
			idealStart = idealEnd - cacheSize;
			if (idealStart < 0) idealStart = 0;
		}
		
		// Only reload cache if we've moved significantly from current window
		var currentEnd = cacheStart + noteCache.length;
		var overlapStart = cacheStart;
		if (overlapStart < idealStart) overlapStart = idealStart;
		var overlapEnd = currentEnd;
		if (overlapEnd < idealEnd) overlapEnd = idealEnd;
		
		// If less than 50% overlap, reload the cache
		if (overlapEnd - overlapStart < (idealEnd - idealStart) >> 1) {
			loadCache(idealStart, idealEnd - idealStart);
		}
	}

	// Remove the old pruneCache function and replace with:
	function pruneCache() {
		// Let manageCache handle the sliding window
		manageCache();
	}

	var timeSpentOnIt:Float = 0;
	var timeSpentOnItIncrement:Float = 0;

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		cullTop(pos);
		cullBottom(pos);

		processNotes(pos);

		pruneCache(); // manage cache sliding window
	}

	function processNotes(pos:Int64) {
		var i = bottom;
		var scrollSpeed = parent.parent.scrollSpeed;
		var prev:MetaNote = -1;
		var noteSpr:VirtualNote = null;
		var j:Int = 0;

		var time = haxe.Timer.stamp();
		while (i < top) {
			var n = getCachedNote(i); // use sliding cache

			var lane = parent.noteTypeFunctionalityPre[n.type] != null
				? 1
				: (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = parent.strumlines[lane].fakeOverlapStorage;

			var diff = MetaNote.metaNotePositionToSongTime((n.position - pos)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);

			var ghost = isGhostNote(prev, n);

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
			++i;
		}
		timeSpentOnIt = haxe.Timer.stamp() - time;

		Sys.println('top $top bottom $bottom');
	}

	function cullTop(pos:Int64) {
		
		trace('topunculled:$top');
		var len = File.getLength();
		while (top != len) {
			// Only fetch once
			var n = getCachedNote(top);
			if (n.position - pos >= spawnDist) break;

			// Initialize the note once
			n.flag = false;
			n.missed = false;
			n.held = false;
			setCachedNote(top, n);

			++top;
		}
		
		trace('topculled:$top');

		// Cache the top note once
		if (top < len) curTopNote = getCachedNote(top);
	}

	function cullBottom(pos:Int64) {
		
		trace('Bottomunculled:$bottom');
		var len = File.getLength();
		while (bottom != len) {
			var n = getCachedNote(bottom);

			// Only calculate once
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
			if (despawnCheck <= despawnDist) break;

			// Return to pool
			var notePool = parent.notePool;
			notePool.putNote(n, bottom);
			notePool.putSustain(n);

			++bottom;
		}
		
		trace('Bottomculled:$bottom');

		// Cache the bottom note once
		if (bottom < len) curBottomNote = getCachedNote(bottom);
	}

	/**
	 * Resets the note spawner to a specific song position.
	 * Handles both forward and backward seeking by resetting note states.
	 * @param songPosition The song position to seek to
	 */
	function resetNotes(songPosition:Float) {
		var pf = parent.parent;
		if (pf.disposed || pf.died) return;

		var len = File.getLength();
		if (len <= 0) return;

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var minPos:Int64 = songPos - despawnDist;
		var maxPos:Int64 = songPos + spawnDist;
		if (minPos < 0) minPos = 0;

		function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0;
			var hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (getCachedNote(mid).position < target)
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
				if (getCachedNote(mid).position <= target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		var newBottom = lowerBound(minPos);
		var newTop = upperBound(maxPos);

		if (newBottom < 0) newBottom = 0;
		else if (newBottom >= len) newBottom = len;

		if (newTop < 0) newTop = 0;
		else if (newTop > len) newTop = len;
		
		// Load cache covering the new range
		var cacheLoadSize = newTop - newBottom;
		if (cacheLoadSize > cacheSize) cacheLoadSize = cacheSize;
		loadCache(newBottom, cacheLoadSize);
		
		// Reset all notes in the range from newBottom to newTop
		// This ensures notes that were previously hit/missed/held are reset
		var i:Int64 = newBottom;
		while (i < newTop) {
			var n = getCachedNote(i);
			if (n != -1) {
				n.flag = false;
				n.missed = false;
				n.held = false;
				setCachedNote(i, n);
			}
			++i;
		}
		
		_lastbottom = bottom = newBottom;
		_lasttop = top = newTop;

		if (bottom < len) curBottomNote = getCachedNote(bottom);
		if (top < len) curTopNote = getCachedNote(top);

		parent.resetStrumlines();
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
					var virtualNote:VirtualNote = index[k];
					var greedyMerged:Bool = false;

					if (virtualNote == null) {
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

					// This is here in order to fix the note still visible for the remaining time rendering or so when inputs are polled at an extemely high rate.
					var noteToHit = strumline.notesToHit[j];
					strumline.notesToHit_sprites[j] = noteToHit == virtualNote.ref ? note : null;

					if (Note.enableGM && greedyMerged && virtualNote.greedyMergeAlphaMultiplier != 0 && virtualNote.greedyMergeType != 0) {
						var formerlyGranularity = downScroll ? 2 : 1;
						var h = note.h;
						note.toggleGMVariant(formerlyGranularity, false);
						note.initialAlpha = Note.defaultAlpha;
						note.addedAlpha = 0;

						if (downScroll) {
							note.y -= note.h - h;
						}

						// and then the addedalpha glossy cover that goes along with it
						var cover = new Note(note.x, note.y, 0, 0);
						cover.initialAlpha = 1;
						cover.addedAlpha = clampColorInt(Math.round(virtualNote.greedyMergeAlphaMultiplier * virtualNote.addedAlpha));

						cover.changeID(id);
						cover.toNote();
						cover.toggleGMVariant(formerlyGranularity, true);
						greedyMergedNoteList.push(cover);

						// you add the cover first so this goes last
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

	public static function clampColorInt(x:Int):Int {
        if (x >= 255) {
            return 255;
        }
        if (x <= 0) {
            return 0;
        }
        
        var diff = x - 255;
        return Math.round(-0.00392 * diff * diff + 255);
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
}
