package structures.gameplay;

/**
 * Optimized note spawner with caching and reduced computational overhead.
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
	
	// Cached values to avoid repeated lookups
	var _cachedScrollSpeed:Float = 1.0;
	var _cachedOffset:Float = 0;
	var _cachedLatencyI64:Int64 = 0;
	
	// Preallocated local variables for loop optimization
	var _timeSpentOnIt:Float = 0;
	var _timeSpentOnItIncrement:Float = 0;

	function new(parent:NoteSystem) {
		this.parent = parent;
		bottom = 0;
		top = 0;
		updateCache();
	}

	inline function updateCache() {
		_cachedScrollSpeed = parent.parent.scrollSpeed;
		_cachedOffset = Main.conductor.offset;
		_cachedLatencyI64 = MetaNote.floatToMetaNotePosition(_cachedOffset);
	}

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		// Update cached values
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

	function processNotes(pos:Int64) {
		var time = haxe.Timer.stamp();
		
		// Apply latency compensation once
		pos += _cachedLatencyI64;
		
		var i = (minBottom != -1 && bottom < minBottom) ? minBottom : bottom;
		var topLocal = top;
		var len = File.getLength();
		
		// Local cache for hot variables
		var file = File;
		var noteTypeFuncs = parent.noteTypeFunctionalityPre;
		var strumlines = parent.strumlines;
		var notePool = parent.notePool;
		var vb = parent.virtualNoteBuffer;
		
		var prev:MetaNote = -1;
		var prevTimeCorrection:Int64 = 0;
		var noteSpr:VirtualNote = null;
		var j:Int = 0;
		
		// Preallocate variables to avoid allocations in loop
		var n:MetaNote;
		var lane:Int;
		var receptor:Note;
		var fakeOverlapStorage:Array<Int>;
		var timeCorrection:Int64;
		var n_position:Int64;
		var diff:Float;
		var newY:Float;
		var ghost:Bool;
		var shouldOverlap:Bool;
		var noteTypeCall:Int->Int->Bool->Void;
		
		while (i < topLocal) {
			n = file.getNote(i);
			timeCorrection = file.getTimeCorrectionForIndex(i);
			n_position = n.position + timeCorrection;
			
			// Determine lane efficiently
			noteTypeCall = noteTypeFuncs[n.type];
			if (noteTypeCall != null) {
				lane = 1;
			} else {
				lane = n.type % strumlines.length;
			}
			
			var strumline = strumlines[lane];
			receptor = strumline.buffer[n.index];
			fakeOverlapStorage = strumline.fakeOverlapStorage;
			
			diff = (MetaNote.metaNotePositionToSongTime(n_position - pos)) * _cachedScrollSpeed;
			newY = receptor.y + Math.floor(diff);
			
			// Quick ghost note check
			if (prev != -1) {
				var prevCorrection = file.getTimeCorrectionForIndex(i - 1);
				ghost = prev.position + prevCorrection == n_position && prev.index == n.index && prev.type == n.type;
			} else {
				ghost = false;
			}
			
			// Check overlap only if we have a previous note
			if (noteSpr != null && !ghost) {
				var prevY = fakeOverlapStorage[prev.index];
				shouldOverlap = shouldNotesOverlap(prev, n, noteSpr, receptor, newY, prevY);
			} else {
				shouldOverlap = false;
			}
			
			fakeOverlapStorage[n.index] = Std.int(newY);
			
			if (shouldOverlap) {
				// Merge notes without creating new sprite
				var alphaToAdd = n.flag ? Note.defaultMissAlpha : Note.defaultAlpha;
				noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
				noteSpr.notesInOne++;
			} else if (!ghost) {
				++j;
				noteSpr = parent.drawNote(pos, n, diff, i, notePool, strumline);
				if (noteSpr != null) {
					vb.addNote(noteSpr);
				}
			}
			
			prev = n;
			prevTimeCorrection = timeCorrection;
			++i;
		}
		
		_timeSpentOnIt = haxe.Timer.stamp() - time;
	}

	function cullTop(pos:Int64) {
		var len = File.getLength();
		var spawnDistLocal = spawnDist;

		// === FORWARD: Include notes now within spawn range ===
		while (top < len) {
			var n = File.getNote(top);
			var tc = File.getTimeCorrectionForIndex(top);
			if ((n.position + tc) - pos >= spawnDistLocal) break;
			++top;
		}

		// === BACKWARD: Exclude notes now too far ahead ===
		while (top > bottom) {
			var idx = top - 1;
			var n = File.getNote(idx);
			var tc = File.getTimeCorrectionForIndex(idx);
			if ((n.position + tc) - pos < spawnDistLocal) break;
			--top;
		}

		if (top < len) curTopNote = File.getNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = File.getLength();
		var despawnDistLocal = despawnDist;

		// === FORWARD: Exclude notes that have despawned ===
		while (bottom < len) {
			var n = File.getNote(bottom);
			var tc = File.getTimeCorrectionForIndex(bottom);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - (n.position + tc);
			if (despawnCheck <= despawnDistLocal) break;
			
			// Get the virtual note and sustain from the buffer and return them to pool
			var vb = parent.virtualNoteBuffer;
			var lane = n.type % parent.strumlines.length;
			var idx = n.index;
			
			// Get note from virtual buffer
			if (vb.notes != null && lane < vb.notes.length && idx < vb.notes[lane].length) {
				var notesInLane = vb.notes[lane][idx];
				if (notesInLane != null) {
					for (k in 0...notesInLane.length) {
						var vn = notesInLane[k];
						if (vn != null && vn.ref != NoteVB.INVALID_OR_EMPTY && vn.ref.position == n.position && vn.ref.index == n.index) {
							parent.notePool.putNote(vn);
							notesInLane[k] = null; // Clear reference
							break;
						}
					}
				}
			}
			
			// Get sustain from virtual buffer
			if (vb.sustains != null && lane < vb.sustains.length && idx < vb.sustains[lane].length) {
				var sustainsInLane = vb.sustains[lane][idx];
				if (sustainsInLane != null) {
					for (k in 0...sustainsInLane.length) {
						var vs = sustainsInLane[k];
						if (vs != null && vs.ref != null && vs.ref.ref != NoteVB.INVALID_OR_EMPTY && 
							vs.ref.ref.position == n.position && vs.ref.ref.index == n.index) {
							parent.notePool.putSustain(vs);
							sustainsInLane[k] = null; // Clear reference
							break;
						}
					}
				}
			}
			
			++bottom;
		}

		// === BACKWARD: Include notes now back in range ===
		while (bottom > 0 && bottom < top) {
			var idx = bottom - 1;
			var n = File.getNote(idx);
			var tc = File.getTimeCorrectionForIndex(idx);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - (n.position + tc);
			if (despawnCheck > despawnDistLocal) break;
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
		
		// Binary search with caching
		var targetMin = songPos;
		var targetMax = songPos - spawnDist;
		
		// Use local variables for faster access
		var file = File;
		
		function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0, hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (file.getNote(mid).position + file.getTimeCorrectionForIndex(mid) < target)
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
				if (file.getNote(mid).position + file.getTimeCorrectionForIndex(mid) <= target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		var newBottom = lowerBound(targetMin);
		var newTop = upperBound(targetMax);
		minBottom = lowerBound(songPos + MetaNote.floatToMetaNotePosition(pushToOffset));

		bottom = newBottom;
		top = newTop;

		if (bottom < len) curBottomNote = file.getNote(bottom);
		if (top < len) curTopNote = file.getNote(top);

		parent.resetStrumlines();
	}

	inline function shouldNotesOverlap(prev:MetaNote, current:MetaNote, noteSpr:VirtualNote,
		receptor:Note, newY:Float, prevY:Float):Bool {

		if (noteSpr == null || prev == -1) return false;

		// Pixel threshold check with integer math
		var scaleFactor = Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT;
		var pixelDiff = Math.abs(Math.floor(newY / scaleFactor) - Math.floor(prevY / scaleFactor));

		return pixelDiff <= 0
			&& prev.type == current.type
			&& noteSpr.scale == receptor.scale
			&& prev.duration == current.duration
			&& prev.index == current.index;
	}

	function renderNotes(pos:Int64) {
		var notes = parent.virtualNoteBuffer;
		renderVirtualNotes(notes, pos);
		renderVirtualSustains(notes);
	}

	// Optimized note rendering with pooled objects
	function renderVirtualNotes(notes:NoteVB, pos:Int64) {
		var downScroll = parent.parent.downScroll;
		var virtualNotes = notes.notes;
		var noteLength = notes.noteLength;
		var noteGen = notes.noteGen;
		var generation = notes.generation;
		
		// Only process notes from current generation
		for (i in 0...virtualNotes.length) {
			var lane = virtualNotes[i];
			var lengths = noteLength[i];
			var gens = noteGen[i];
			var strumline = parent.strumlines[i];
			
			for (j in 0...lane.length) {
				if (gens[j] != generation) continue; // Skip stale data
				var len = lengths[j];
				if (len == 0) continue;
				
				var notesInLane = lane[j];
				var id = parent.parent.inputSystem.receptorIds[j];
				var strumReceptor = strumline.buffer[j];
				
				for (k in 0...len) {
					var virtualNote:VirtualNote = notesInLane[k];
					if (virtualNote == null) continue;
					
					// Create Note object using pooled approach
					var note = new Note(virtualNote.Sx, virtualNote.Sy, 0, 0, 
						virtualNote.scale, virtualNote.initialAlpha, virtualNote.addedAlpha);
					note.diff = -virtualNote.diff;
					note.scrollDirection = strumReceptor.scrollDirection;
					if (downScroll) note.scrollDirection += 180;
					note.changeID(id);
					note.toNote();
					
					// Batch add to buffer
					NoteSystem.notesBuf.addElement(note);
				}
			}
		}
	}

	function renderVirtualSustains(notes:NoteVB) {
		var downScroll = parent.parent.downScroll;
		var virtualSustains = notes.sustains;
		var sustainLength = notes.sustainLength;
		var sustainGen = notes.sustainGen;
		var generation = notes.generation;
		var tailPoints = Sustain.tailPoints;
		
		for (i in 0...virtualSustains.length) {
			var lane = virtualSustains[i];
			var lengths = sustainLength[i];
			var gens = sustainGen[i];
			var strumline = parent.strumlines[i];
			
			for (j in 0...lane.length) {
				if (gens[j] != generation) continue;
				var len = lengths[j];
				if (len == 0) continue;
				
				var sustainsInLane = lane[j];
				var id = parent.parent.inputSystem.receptorIds[j];
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
					NoteSystem.sustainsBuf.addElement(sustain);
				}
			}
		}
	}
}