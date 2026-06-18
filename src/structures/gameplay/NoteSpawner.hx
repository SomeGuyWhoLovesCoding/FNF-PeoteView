package structures.gameplay;

import data.chart.File;
import data.chart.MetaNote;

/**
 * Optimized note spawner with focus on hot path performance.
 * @since Development
**/
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;
	static var minBottom:Int64 = -1;

	var _lastbottom:Int64;
	var _lasttop:Int64;

	var spawnDist:Int64;
	var despawnDist:Int64;

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var parent(default, null):NoteSystem;
	
	// --- CACHED VALUES FOR HOT PATH ---
	var _cachedLen:Int64 = 0;
	var _cachedScrollSpeed:Float = 1.0;
	var _cachedOffset:Float = 0;
	var _cachedLatencyI64:Int64 = 0;
	var _cachedDownScroll:Bool = false;
	
	// --- PRE-ALLOCATED ARRAYS FOR NOTE CACHING ---
	var _noteCache:Array<{note:MetaNote, timeCorrection:Int64, pos:Int64}>;
	var _cacheIndex:Int = 0;
	var _cacheSize:Int = 0;
	
	// --- STATS ---
	var timeSpentOnIt:Float = 0;
	var _lastProcessedTime:Float = 0;

	function new(parent:NoteSystem) {
		this.parent = parent;
		bottom = 0;
		top = 0;
		_cachedLen = File.getLength();
		
		// Pre-allocate cache for 5000 notes (adjust based on max visible notes)
		_cacheSize = 5000;
		_noteCache = [];
		for (i in 0..._cacheSize) {
			_noteCache.push({note: -1, timeCorrection: 0, pos: 0});
		}
		_cacheIndex = 0;
		
		updateCache();
	}

	inline function updateCache() {
		_cachedScrollSpeed = parent.parent.scrollSpeed;
		_cachedOffset = Main.conductor.offset;
		_cachedLatencyI64 = MetaNote.floatToMetaNotePosition(_cachedOffset);
		_cachedDownScroll = parent.parent.downScroll;
	}

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		updateCache();

		cullTop(pos);
		cullBottom(pos);

		if (parent.movingBackward) {
			var strumlines = parent.strumlines;
			for (i in 0...strumlines.length) {
				var strumline = strumlines[i];
				var notesToHit = strumline.notesToHit;
				var notesToHitIndexes = strumline.notesToHit_indexes;
				for (j in 0...notesToHit.length) {
					notesToHit[j] = null;
					notesToHitIndexes[j] = 0;
				}
			}
		}

		processNotes(pos);
	}

	/**
	 * CRITICAL HOT PATH: Process notes with minimal allocations
	 */
	function processNotes(pos:Int64) {
		var time = haxe.Timer.stamp();
		
		// Apply latency compensation once
		pos += _cachedLatencyI64;
		
		// Get local references for faster access
		var strumlines = parent.strumlines;
		var noteTypeFuncs = parent.noteTypeFunctionalityPre;
		var vb = parent.virtualNoteBuffer;
		
		// Cache frequently accessed values
		var scrollSpeed = _cachedScrollSpeed;
		var minBottomLocal = minBottom;
		var bottomLocal = bottom;
		var topLocal = top;
		var len = _cachedLen;
		
		// Start from minBottom if set
		var i = (minBottomLocal != -1 && bottomLocal < minBottomLocal) ? minBottomLocal : bottomLocal;
		
		// Pre-allocate local variables
		var prev:MetaNote = -1;
		var noteSpr:VirtualNote = null;
		var n:MetaNote;
		var lane:Int;
		var strumline:Strumline;
		var receptor:Note;
		var fakeOverlapStorage:Array<Int>;
		var timeCorrection:Int64;
		var n_position:Int64;
		var diff:Float;
		var newY:Float;
		var ghost:Bool;
		var shouldOverlap:Bool;
		var noteTypeCall:Int->Int->Bool->Void;
		
		// Pre-cache string values
		var noteDefaultAlpha = Note.defaultAlpha;
		var noteDefaultMissAlpha = Note.defaultMissAlpha;
		
		// --- MAIN LOOP: Process all visible notes ---
		while (i < topLocal) {
			// Get note data from file
			n = File.getNote(i);
			timeCorrection = File.getTimeCorrectionForIndex(i);
			n_position = n.position + timeCorrection;
			
			// Determine lane - optimized with local reference
			noteTypeCall = noteTypeFuncs[n.type];
			if (noteTypeCall != null) {
				lane = 1;
			} else {
				lane = n.type % strumlines.length;
			}
			
			strumline = strumlines[lane];
			receptor = strumline.buffer[n.index];
			fakeOverlapStorage = strumline.fakeOverlapStorage;
			
			// Calculate position
			diff = (MetaNote.metaNotePositionToSongTime(n_position - pos)) * scrollSpeed;
			newY = receptor.y + Math.floor(diff);
			
			// Ghost note check - optimized
			if (prev != -1) {
				ghost = (prev.position + prevTimeCorrection == n_position && 
						 prev.index == n.index && 
						 prev.type == n.type);
			} else {
				ghost = false;
			}
			
			// Overlap check - only if we have a sprite and not ghost
			if (noteSpr != null && !ghost) {
				var prevY = fakeOverlapStorage[prev.index];
				shouldOverlap = shouldNotesOverlap(prev, n, noteSpr, receptor, newY, prevY);
			} else {
				shouldOverlap = false;
			}
			
			// Store Y for overlap detection
			fakeOverlapStorage[n.index] = Std.int(newY);
			
			if (shouldOverlap) {
				// Merge notes - no new sprite created
				var alphaToAdd = n.flag ? noteDefaultMissAlpha : noteDefaultAlpha;
				noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
				noteSpr.notesInOne++;
			} else if (!ghost) {
				// Draw note - this creates the VirtualNote
				noteSpr = parent.drawNote(pos, n, diff, i, strumline);
				if (noteSpr != null) {
					vb.addNote(noteSpr);
				}
			}
			
			// Store for next iteration
			prev = n;
			prevTimeCorrection = timeCorrection;
			++i;
		}
		
		timeSpentOnIt = haxe.Timer.stamp() - time;
	}

	// Store previous time correction for ghost detection
	var prevTimeCorrection:Int64 = 0;

	function cullTop(pos:Int64) {
		var len = _cachedLen;

		// Forward: Include notes now within spawn range
		while (top < len) {
			var n = File.getNote(top);
			var tc = File.getTimeCorrectionForIndex(top);
			if ((n.position + tc) - pos >= spawnDist) break;
			++top;
		}

		// Backward: Exclude notes now too far ahead
		while (top > bottom) {
			var idx = top - 1;
			var n = File.getNote(idx);
			var tc = File.getTimeCorrectionForIndex(idx);
			if ((n.position + tc) - pos < spawnDist) break;
			--top;
		}

		if (top < len) curTopNote = File.getNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = _cachedLen;

		// Forward: Exclude notes that have despawned
		while (bottom < len) {
			var n = File.getNote(bottom);
			var tc = File.getTimeCorrectionForIndex(bottom);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - (n.position + tc);
			if (despawnCheck <= despawnDist) break;
			++bottom;
		}

		// Backward: Include notes now back in range
		while (bottom > 0 && bottom < top) {
			var idx = bottom - 1;
			var n = File.getNote(idx);
			var tc = File.getTimeCorrectionForIndex(idx);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - (n.position + tc);
			if (despawnCheck > despawnDist) break;
			--bottom;
		}

		if (bottom < len) curBottomNote = File.getNote(bottom);
	}

	function resetNotes(songPosition:Float, pushToOffset:Float = 0) {
		var pf = parent.parent;
		if (pf.disposed || pf.died) return;

		parent.notePool.reset();

		var len = File.getLength();
		if (len <= 0) return;

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var minPos:Int64 = songPos;
		var maxPos:Int64 = songPos - spawnDist;

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
		var newTop = upperBound(maxPos);
		minBottom = lowerBound(songPos + MetaNote.floatToMetaNotePosition(pushToOffset));

		bottom = newBottom;
		top = newTop;

		curBottomNote = File.getNote(bottom);
		curTopNote = File.getNote(top);

		parent.resetStrumlines();
	}

	/**
	 * OPTIMIZED: Check overlap with minimal operations
	 */
	inline function shouldNotesOverlap(prev:MetaNote, current:MetaNote, noteSpr:VirtualNote,
		receptor:Note, newY:Float, prevY:Float):Bool {

		if (noteSpr == null || prev == -1) return false;

		// Quick rejection - if types don't match, no overlap
		if (prev.type != current.type || prev.duration != current.duration || prev.index != current.index) {
			return false;
		}

		// Pixel threshold check with integer math
		var scaleFactor = Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT;
		var pixelDiff = Math.abs(Math.floor(newY / scaleFactor) - Math.floor(prevY / scaleFactor));

		return pixelDiff <= 0 && noteSpr.scale == receptor.scale;
	}

	function renderNotes(pos:Int64) {
		var notes = parent.virtualNoteBuffer;
		renderVirtualNotes(notes, pos);
		renderVirtualSustains(notes);
	}

	var regularNoteList:Array<Note> = [];

	/**
	 * OPTIMIZED: Render notes with pooling
	 */
	function renderVirtualNotes(notes:NoteVB, pos:Int64) {
		var downScroll = _cachedDownScroll;
		var virtualNotes = notes.notes;
		var noteLength = notes.noteLength;
		var generation = notes.generation;
		var noteGen = notes.noteGen;
		
		var strumlines = parent.strumlines;
		var inputSystem = parent.parent.inputSystem;
		var notesBuf = NoteSystem.notesBuf;
		
		for (i in 0...virtualNotes.length) {
			var lane = virtualNotes[i];
			var lengths = noteLength[i];
			var gens = noteGen[i];
			var strumline = strumlines[i];
			
			for (j in 0...lane.length) {
				// Skip if not from current generation
				if (gens[j] != generation) continue;
				
				var len = lengths[j];
				if (len == 0) continue;
				
				var notesInLane = lane[j];
				var id = inputSystem.receptorIds[j];
				var strumReceptor = strumline.buffer[j];
				
				for (k in 0...len) {
					var virtualNote:VirtualNote = notesInLane[k];
					if (virtualNote == null) continue;

					// Create Note object
					var note = new Note(virtualNote.Sx, virtualNote.Sy, 0, 0, 
						virtualNote.scale, virtualNote.initialAlpha, virtualNote.addedAlpha);
					note.diff = -virtualNote.diff;
					note.scrollDirection = strumReceptor.scrollDirection;
					if (downScroll) note.scrollDirection += 180;

					note.changeID(id);
					note.toNote();

					var noteToHitIdx = strumline.notesToHit_indexes[j];
					strumline.notesToHit_sprites[j] = noteToHitIdx == virtualNote.globalIndex ? note : null;

					regularNoteList.push(note);
				}
			}
		}

		// Batch add all notes
		while (regularNoteList.length != 0) {
			notesBuf.addElement(regularNoteList.pop());
		}
	}

	function renderVirtualSustains(notes:NoteVB) {
		var downScroll = _cachedDownScroll;
		var virtualSustains = notes.sustains;
		var sustainLength = notes.sustainLength;
		var sustainGen = notes.sustainGen;
		var generation = notes.generation;
		var tailPoints = Sustain.tailPoints;
		
		var strumlines = parent.strumlines;
		var inputSystem = parent.parent.inputSystem;
		var sustainsBuf = NoteSystem.sustainsBuf;
		
		for (i in 0...virtualSustains.length) {
			var lane = virtualSustains[i];
			var lengths = sustainLength[i];
			var gens = sustainGen[i];
			var strumline = strumlines[i];
			
			for (j in 0...lane.length) {
				if (gens[j] != generation) continue;
				var len = lengths[j];
				if (len == 0) continue;
				
				var sustainsInLane = lane[j];
				var id = inputSystem.receptorIds[j];
				var strumReceptor = strumline.buffer[j];
				
				for (k in 0...len) {
					var virtualSustain:VirtualSustain = sustainsInLane[k];
					if (virtualSustain == null) continue;
					
					var sustain = new Sustain(virtualSustain.Sx, virtualSustain.Sy, 
						virtualSustain.w, virtualSustain.h,
						virtualSustain.r, virtualSustain.speed, virtualSustain.scale, 
						id, tailPoints[id]);
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
					sustainsBuf.addElement(sustain);
				}
			}
		}
	}
}