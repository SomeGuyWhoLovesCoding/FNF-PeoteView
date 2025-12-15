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

	// --- Optimized cache system ---
	var noteCache:Array<MetaNote> = [];
	var cacheStart:Int64 = 0;
	var cacheEnd:Int64 = 0;  // Track end explicitly
	var cacheSize:Int64 = 1048576;
	
	// Dirty tracking for batched writes
	var dirtyNotes:Array<MetaNote> = [];
	var dirtyIndices:Array<Int64> = [];
	var dirtyCount:Int = 0;
	var maxDirtyBatch:Int = 1024;  // Flush after this many dirty writes

	function new(parent:NoteSystem) {
		this.parent = parent;

		bottom = 0;
		top = 0;

		loadCache(0, cacheSize);
		cacheEnd = cacheStart + noteCache.length;
		curTopNote = noteCache[0];
		curBottomNote = noteCache[0];
		
		// Pre-allocate dirty arrays
		dirtyNotes.resize(maxDirtyBatch);
		dirtyIndices.resize(maxDirtyBatch);
	}

	// --- Optimized cache loading with pre-allocation ---
	function loadCache(startIdx:Int64, size:Int64) {
		var len = File.getLength();
		if (startIdx >= len) {
			noteCache = [];
			cacheStart = startIdx;
			cacheEnd = startIdx;
			return;
		}

		cacheStart = startIdx;
		
		var maxLoad = len - startIdx;
		if (maxLoad > size) maxLoad = size;
		if (maxLoad < 0) maxLoad = 0;

		var loadSize = Int64.toInt(maxLoad);
		
		// Reuse array if possible to avoid allocation
		if (noteCache.length != loadSize) {
			noteCache = [];
			noteCache.resize(loadSize);
		}

		// Bulk load notes
		var i:Int64 = 0;
		while (i < maxLoad) {
			noteCache[Int64.toInt(i)] = File.getNote(startIdx + i);
			i++;
		}
		
		cacheEnd = cacheStart + maxLoad;
	}

	// --- Optimized get with bounds caching ---
	inline function getCachedNote(idx:Int64):MetaNote {
		// Fast path: check cached bounds first
		if (idx >= cacheStart && idx < cacheEnd) {
			return noteCache[Int64.toInt(idx - cacheStart)];
		}

		// Slow path: reload cache
		return getCachedNoteSlow(idx);
	}
	
	function getCachedNoteSlow(idx:Int64):MetaNote {
		var len = File.getLength();
		if (idx >= len) return -1;

		// Slide cache window to center around requested index
		var newStart = idx - (cacheSize >> 2);  // Center with 25% padding before
		if (newStart < 0) newStart = 0;
		
		var newSize = cacheSize;
		if (newStart + newSize > len) {
			newSize = len - newStart;
		}
		
		loadCache(newStart, newSize);
		
		// Return from new cache
		var cacheIdx = idx - cacheStart;
		if (cacheIdx >= 0 && cacheIdx < noteCache.length) {
			return noteCache[Int64.toInt(cacheIdx)];
		}
		
		return -1;
	}

	// --- Batched write system ---
	inline function setCachedNote(idx:Int64, value:MetaNote) {
		// Fast path: if in cache, mark dirty
		if (idx >= cacheStart && idx < cacheEnd) {
			var cacheIdx = Int64.toInt(idx - cacheStart);
			noteCache[cacheIdx] = value;
			
			// Add to dirty batch
			dirtyIndices[dirtyCount] = idx;
			dirtyNotes[dirtyCount] = value;
			dirtyCount++;
			
			// Auto-flush if batch is full
			if (dirtyCount >= maxDirtyBatch) {
				flushDirtyNotes();
			}
			return;
		}

		// Slow path: outside cache, write directly
		File.setNote(idx, value);
	}
	
	// --- Flush dirty notes in one batch ---
	function flushDirtyNotes() {
		if (dirtyCount == 0) return;
		
		// Write all dirty notes back to file in batch
		// This is where you'd do bulk I/O if File supports it
		for (i in 0...dirtyCount) {
			File.setNote(dirtyIndices[i], dirtyNotes[i]);
		}
		
		dirtyCount = 0;
	}

	// --- Smart cache management with hysteresis ---
	var lastManagePos:Int64 = 0;
	var manageThreshold:Int64 = 256;  // Only manage every N notes moved
	
	function manageCache() {
		var len = File.getLength();
		
		// Calculate center of active window
		var center = (bottom + top) >> 1;
		
		// Only reposition if we've moved significantly
		var movement = center - lastManagePos;
		if (movement < 0) movement = -movement;
		
		if (movement < manageThreshold) return;
		lastManagePos = center;
		
		// Calculate ideal cache window
		var cachePadding = cacheSize >> 2;
		var idealStart = center - cachePadding;
		if (idealStart < 0) idealStart = 0;
		
		var idealEnd = idealStart + cacheSize;
		if (idealEnd > len) {
			idealEnd = len;
			idealStart = idealEnd - cacheSize;
			if (idealStart < 0) idealStart = 0;
		}
		
		// Check if current cache still has good overlap
		var overlapStart = cacheStart > idealStart ? cacheStart : idealStart;
		var overlapEnd = cacheEnd < idealEnd ? cacheEnd : idealEnd;
		var overlap = overlapEnd - overlapStart;
		
		// Only reload if overlap is less than 60%
		if (overlap < (cacheSize * 3) / 5) {
			flushDirtyNotes();  // Flush before reloading
			loadCache(idealStart, idealEnd - idealStart);
		}
	}

	function pruneCache() {
		manageCache();
	}

	var timeSpentOnIt:Float = 0;

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		cullTop(pos);
		cullBottom(pos);

		processNotes(pos);

		// Flush dirty writes at end of frame
		flushDirtyNotes();
		
		pruneCache();
	}

	function processNotes(pos:Int64) {
		var scrollSpeed = parent.parent.scrollSpeed;
		var time = haxe.Timer.stamp();
		
		var batchSize = Int64.toInt(top - bottom);
		if (batchSize <= 0) {
			timeSpentOnIt = 0;
			return;
		}
		
		// Cache everything
		var strumlines = parent.strumlines;
		var noteTypeFunctionalityPre = parent.noteTypeFunctionalityPre;
		var strumlineCount = strumlines.length;
		var heightScale = Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT;
		
		var prev:MetaNote = -1;
		var noteSpr:VirtualNote = null;
		var prevY:Float = 0;
		var prevLane:Int = -1;
		var prevFakeOverlapStorage:Array<Float> = null;
		var j:Int = 0;
		
		var i = bottom;
		while (i < top) {
			var n = getCachedNote(i);
			
			// Fast lane calculation
			var lane:Int;
			if (noteTypeFunctionalityPre[n.type] != null) {
				lane = 1;
			} else {
				lane = n.type % strumlineCount;
			}
			
			// Cache strumline data per lane change
			var fakeOverlapStorage:Array<Float>;
			var receptor:Note;
			
			if (lane != prevLane) {
				var strumline = strumlines[lane];
				fakeOverlapStorage = strumline.fakeOverlapStorage;
				receptor = strumline.buffer[n.index];
				prevLane = lane;
				prevFakeOverlapStorage = fakeOverlapStorage;
			} else {
				fakeOverlapStorage = prevFakeOverlapStorage;
				receptor = strumlines[lane].buffer[n.index];
			}
			
			// Calculate position
			var diff = MetaNote.metaNotePositionToSongTime((n.position - pos)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);
			
			// Fast ghost check
			var ghost = prev != -1
				&& prev.position == n.position
				&& prev.index == n.index
				&& prev.type == n.type;
			
			// Overlap check with early exits
			var shouldOverlap = false;
			if (!ghost && noteSpr != null && prev != -1) {
				if (prev.type == n.type && prev.duration == n.duration) {
					if (noteSpr.scale == receptor.scale && noteSpr.x == receptor.x) {
						var pixelDiff = Math.abs(
							Math.floor(newY / heightScale) -
							Math.floor(prevY / heightScale)
						);
						shouldOverlap = pixelDiff == 0;
					}
				}
			}
			
			fakeOverlapStorage[n.index] = newY;
			
			if (shouldOverlap) {
				var alphaToAdd = n.missed ? Note.defaultMissAlpha : Note.defaultAlpha;
				noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
				noteSpr.notesInOne++;
			} else if (!ghost) {
				++j;
				noteSpr = parent.drawNote(pos, n, diff, i);
			}
			
			prev = n;
			prevY = newY;
			++i;
		}
		
		timeSpentOnIt = haxe.Timer.stamp() - time;
	}

	function cullTop(pos:Int64) {
		var len = File.getLength();
		while (top != len) {
			var n = getCachedNote(top);
			if (n.position - pos >= spawnDist) break;

			// Modify note and mark dirty
			n.flag = false;
			n.missed = false;
			n.held = false;
			setCachedNote(top, n);

			++top;
		}

		if (top < len) curTopNote = getCachedNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = File.getLength();
		while (bottom != len) {
			var n = getCachedNote(bottom);

			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
			if (despawnCheck <= despawnDist) break;

			// Return to pool
			var notePool = parent.notePool;
			notePool.putNote(n, bottom);
			notePool.putSustain(n);

			++bottom;
		}

		if (bottom < len) curBottomNote = getCachedNote(bottom);
	}

	function resetNotes(songPosition:Float) {
		var pf = parent.parent;
		if (pf.disposed || pf.died) return;

		var len = File.getLength();
		if (len <= 0) return;
		
		// Flush any pending writes before reset
		flushDirtyNotes();

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var minPos:Int64 = songPos - spawnDist;
		var maxPos:Int64 = songPos;
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

		bottom = lowerBound(minPos);
		top = upperBound(maxPos) - 1;

		if (bottom < 0) bottom = 0;
		else if (bottom >= len) bottom = len - 1;

		if (top < 0) top = 0;
		else if (top >= len) top = len - 1;

		curBottomNote = getCachedNote(bottom);
		curTopNote = getCachedNote(top);

		// Slide cache to cover current bottom/top
		loadCache(bottom, cacheSize);

		parent.resetStrumlines();
	}

	// [Rest of your render functions unchanged...]
	
	function renderNotes(pos:Int64) {
		var notes = parent.virtualNoteBuffer;
		renderVirtualNotes(notes, pos);
		renderVirtualSustains(notes);
	}

	var regularNoteList:Array<Note> = [];
	var greedyMergedNoteList:Array<Note> = [];

	function renderVirtualNotes(notes:NoteVB, pos:Int64) {
		var downScroll = parent.parent.downScroll;
		var virtualNotes = notes.notes;
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

					if (virtualNote.y < -200 || virtualNote.y > Main.current.peoteView.height + 10) {
						k += increment;
						continue;
					}

					if (Note.enableGM) {
						greedyMerged = greedyMergeNearlyNotes(virtualNote, index, k, 64);
						if (greedyMerged) {
							increment = 64;
						}
					}

					var note = new Note(virtualNote.x, virtualNote.y, 0, 0);
					note.w = virtualNote.w;
					note.h = virtualNote.h;
					note.scale = virtualNote.scale;
					note.initialAlpha = virtualNote.initialAlpha;
					note.addedAlpha = virtualNote.addedAlpha;
					note.changeID(id);
					note.toNote();

					var noteToHit = strumline.notesToHit[j];
					strumline.notesToHit_sprites[j] = noteToHit == virtualNote.ref ? note : null;

					if (Note.enableGM && greedyMerged && virtualNote.greedyMergeAlphaMultiplier != 0 && virtualNote.greedyMergeType != 0) {
						var h = note.h;
						note.toggleGMVariant(granularity, false);
						note.initialAlpha = Note.defaultAlpha;
						note.addedAlpha = 0;
						
						if (downScroll) {
							note.y -= note.h - h;
						}

						var cover = new Note(note.x, note.y, 0, 0);
						cover.initialAlpha = 1;
						cover.addedAlpha = virtualNote.greedyMergeAlphaMultiplier * virtualNote.addedAlpha;
						cover.changeID(id);
						cover.toNote();
						cover.toggleGMVariant(granularity, true);
						greedyMergedNoteList.push(cover);
						greedyMergedNoteList.push(note);
					} else {
						regularNoteList.push(note);
					}

					k += increment;
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
		}
	}

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

	function greedyMergeNearlyNotes(virtualNote:VirtualNote, index:Array<VirtualNote>, k:Int, count:Int = 16):Bool {
		if (k + count >= index.length) return false;

		var firstNote = index[k];
		var lastNote = index[k + count - 1];
		
		if (firstNote == null || lastNote == null) return false;
		
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

		virtualNote.greedyMergeType = Math.floor(totalSpan);
		virtualNote.greedyMergeAlphaMultiplier = Int64.toInt(notesInOneMerged);
		
		return true;
	}

	inline function isGhostNote(prev:MetaNote, current:MetaNote):Bool {
		return prev != -1
			&& prev.position == current.position
			&& prev.index == current.index
			&& prev.type == current.type;
	}

	inline function shouldNotesOverlap(prev:MetaNote, current:MetaNote, noteSpr:VirtualNote,
		receptor:Note, newY:Float, prevY:Float):Bool {

		if (noteSpr == null || prev == -1) return false;

		var OVERLAP_PIXEL_THRESHOLD = 0;

		var pixelDiff = Math.abs(
			Math.floor(newY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT)) -
			Math.floor(prevY / (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT))
		);

		return pixelDiff <= OVERLAP_PIXEL_THRESHOLD
			&& prev.type == current.type
			&& noteSpr.scale == receptor.scale
			&& prev.duration == current.duration
			&& noteSpr.x == receptor.x;
	}

	inline function mergeNoteIntoSprite(noteSpr:VirtualNote, n:MetaNote) {
		var alphaToAdd = n.missed ? Note.defaultMissAlpha : Note.defaultAlpha;
		noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
		noteSpr.notesInOne++;
	}
}
