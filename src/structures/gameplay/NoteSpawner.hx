package structures.gameplay;

import sys.thread.Thread;
import sys.thread.Deque;

/**
 * Multithreaded note spawner with self-contained threading.
 * @since Development
 */
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;
	static var minBottom:Int64 = -1;

	var _lastbottom:Int64;
	var _lasttop:Int64;

	var spawnDist:Int64 = MetaNote.floatToMetaNotePosition(1300);
	var despawnDist:Int64 = MetaNote.floatToMetaNotePosition(300);

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var parent(default, null):NoteSystem;
	
	// Thread pool
	var workerThreads:Array<Thread>;
	var workQueue:Deque<ThreadWork>;
	var resultQueue:Deque<ThreadResult>;
	var threadRunning:Bool = false;
	var threadCount:Int;
	
	// Cache frequently accessed values
	var _cachedScrollSpeed:Float = 1.0;
	var _cachedLatencyI64:Int64 = 0;
	var _cachedLen:Int64 = 0;
	var _cachedOffset:Float = 0;

	function new(parent:NoteSystem) {
		this.parent = parent;
		bottom = 0;
		top = 0;
		_cachedLen = File.getLength();
		
		// Use CPU cores for thread count, cap at 8 for stability
		threadCount = Std.int(8);
		if (threadCount < 2) threadCount = 2;
		
		initThreading();
	}
	
	function initThreading() {
		workQueue = new Deque<ThreadWork>();
		resultQueue = new Deque<ThreadResult>();
		workerThreads = [];
		threadRunning = true;
		
		// Create worker threads
		for (i in 0...threadCount) {
			var thread = Thread.create(() -> workerLoop(i));
			workerThreads.push(thread);
		}
	}
	
	function workerLoop(id:Int) {
		while (threadRunning) {
			var work = workQueue.pop(false);
			if (work == null) {
				continue;
			}
			
			// Process the work chunk
			var result = processNoteChunk(work);
			resultQueue.push(result);
		}
	}
	
	function processNoteChunk(work:ThreadWork):ThreadResult {
		var result = new ThreadResult();
		result.notes = [];
		
		var scrollSpeed = _cachedScrollSpeed;
		var posWithLatency = work.pos + _cachedLatencyI64;
		var strumlines = parent.strumlines;
		var noteTypeFuncs = parent.noteTypeFunctionalityPre;
		
		var i = work.startIndex;
		while (i < work.endIndex) {
			var n = File.getNote(i);
			var timeCorrection = File.getTimeCorrectionForIndex(i);
			var n_position = n.position + timeCorrection;
			
			var lane = (noteTypeFuncs[n.type] != null) ? 1 : (n.type % strumlines.length);
			var strumline = strumlines[lane];
			var receptor = strumline.buffer[n.index];
			
			var diff = (MetaNote.metaNotePositionToSongTime(n_position - posWithLatency)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);
			
			// Store processed note data
			result.notes.push({
				index: i,
				note: n,
				diff: diff,
				newY: newY,
				lane: lane,
				timeCorrection: timeCorrection,
				position: n_position
			});

			++i;
		}
		
		return result;
	}

	var timeSpentOnIt:Float = 0;
	var timeSpentOnItIncrement:Float = 0;

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		// Update cache
		_cachedScrollSpeed = parent.parent.scrollSpeed;
		_cachedOffset = Main.conductor.offset;
		_cachedLatencyI64 = MetaNote.floatToMetaNotePosition(_cachedOffset);

		cullTop(pos);
		cullBottom(pos);

		if (parent.movingBackward) {
			for (i in 0...parent.strumlines.length) {
				var strumline = parent.strumlines[i];
				for (j in 0...strumline.notesToHit.length) {
					strumline.notesToHit[j] = null;
					strumline.notesToHit_indexes[j] = 0;
				}
			}
		}

		processNotes(pos);
	}

	function processNotes(pos:Int64) {
		var time = haxe.Timer.stamp();
		
		var i = (minBottom != -1 && bottom < minBottom) ? minBottom : bottom;
		var totalNotes = top - i;
		
		// For small note counts, process on main thread
		if (totalNotes < 1000) {
			processNotesSingleThreaded(pos, i, top);
		} else {
			processNotesMultiThreaded(pos, i, top);
		}
		
		timeSpentOnIt = haxe.Timer.stamp() - time;
		
		// Clean up any leftover results
		while (resultQueue.pop(false) != null) {}
	}
	
	function processNotesSingleThreaded(pos:Int64, start:Int64, end:Int64) {
		var scrollSpeed = _cachedScrollSpeed;
		var posWithLatency = pos + _cachedLatencyI64;
		var strumlines = parent.strumlines;
		var noteTypeFuncs = parent.noteTypeFunctionalityPre;
		var vb = parent.virtualNoteBuffer;
		
		var prev:MetaNote = -1;
		var prevTimeCorrection:Int64 = 0;
		var noteSpr:VirtualNote = null;

		var i = start;
		while (i < end) {
			var n = File.getNote(i);
			var timeCorrection = File.getTimeCorrectionForIndex(i);
			var n_position = n.position + timeCorrection;
			
			var lane = (noteTypeFuncs[n.type] != null) ? 1 : (n.type % strumlines.length);
			var strumline = strumlines[lane];
			var receptor = strumline.buffer[n.index];
			var fakeOverlapStorage = strumline.fakeOverlapStorage;
			
			var diff = (MetaNote.metaNotePositionToSongTime(n_position - posWithLatency)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);
			
			var ghost = prev != -1 && 
				prev.position + prevTimeCorrection == n_position && 
				prev.index == n.index && 
				prev.type == n.type;
			
			var shouldOverlap = noteSpr != null && !ghost &&
				shouldNotesOverlap(prev, n, noteSpr, receptor, newY,
					fakeOverlapStorage[prev != -1 ? prev.index : -1]);
			
			fakeOverlapStorage[n.index] = Std.int(newY);
			
			if (shouldOverlap) {
				mergeNoteIntoSprite(noteSpr, n);
			} else if (!ghost) {
				noteSpr = parent.drawNote(pos, n, diff, i);
				if (noteSpr != null) {
					vb.addNote(noteSpr);
				}
			}
			
			prev = n;
			prevTimeCorrection = timeCorrection;

			++i;
		}
	}
	
	function processNotesMultiThreaded(pos:Int64, start:Int64, end:Int64) {
		// Clear previous results
		while (resultQueue.pop(false) != null) {}
		
		var totalNotes = end - start;
		var notesPerThread = totalNotes / threadCount;
		if (notesPerThread < 100) notesPerThread = 100;
		
		var currentStart = start;
		var workItems = [];
		
		// Distribute work to threads
		for (i in 0...threadCount) {
			if (currentStart >= end) break;
			var chunkEnd = currentStart + notesPerThread;
			if (chunkEnd > end) chunkEnd = end;
			
			var work = new ThreadWork();
			work.startIndex = currentStart;
			work.endIndex = chunkEnd;
			work.pos = pos;
			
			workQueue.push(work);
			workItems.push(work);
			currentStart = chunkEnd;
		}
		
		// Collect results
		var completed = 0;
		var expected = workItems.length;
		var timeout = 0;
		var maxTimeout = 100; // 100ms timeout
		
		while (completed < expected && timeout < maxTimeout) {
			var result = resultQueue.pop(false);
			if (result != null) {
				// Process results from worker
				for (noteData in result.notes) {
					// Draw the note on main thread
					var n = noteData.note;
					var noteSpr = parent.drawNote(pos, n, noteData.diff, noteData.index);
					if (noteSpr != null) {
						parent.virtualNoteBuffer.addNote(noteSpr);
					}
				}
				completed++;
			} else {
				timeout++;
			}
		}
		
		// If timeout occurred, process remaining notes on main thread
		if (timeout >= maxTimeout) {
			var remainingStart = currentStart;
			if (remainingStart < end) {
				processNotesSingleThreaded(pos, remainingStart, end);
			}
		}
	}

	function cullTop(pos:Int64) {
		var len = _cachedLen;

		// === FORWARD: Include notes now within spawn range ===
		while (top < len) {
			var n = File.getNote(top);
			var tc = File.getTimeCorrectionForIndex(top);
			if ((n.position + tc) - pos >= spawnDist) break;
			++top;
		}

		// === BACKWARD: Exclude notes now too far ahead ===
		while (top > bottom) {
			var n = File.getNote(top - 1);
			var tc = File.getTimeCorrectionForIndex(top - 1);
			if ((n.position + tc) - pos < spawnDist) break;
			--top;
		}

		if (top < len) curTopNote = File.getNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = _cachedLen;

		// === FORWARD: Exclude notes that have despawned ===
		while (bottom < len) {
			var n = File.getNote(bottom);
			var tc = File.getTimeCorrectionForIndex(bottom);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - (n.position + tc);
			if (despawnCheck <= despawnDist) break;
			var notePool = parent.notePool;
			notePool.putNote(n, bottom);
			notePool.putSustain(n, bottom);
			++bottom;
		}

		// === BACKWARD: Include notes now back in range ===
		while (bottom > 0 && bottom < top) {
			var n = File.getNote(bottom - 1);
			var tc = File.getTimeCorrectionForIndex(bottom - 1);
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

		var len = _cachedLen;
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

	function renderNotes(pos:Int64) {
		var notes = parent.virtualNoteBuffer;
		renderVirtualNotes(notes, pos);
		renderVirtualSustains(notes);
	}

	var regularNoteList:Array<Note> = [];

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

					var noteToHitIdx = strumline.notesToHit_indexes[j];
					strumline.notesToHit_sprites[j] = noteToHitIdx == virtualNote.globalIndex ? note : null;

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

	inline function isGhostNote(prev:MetaNote, current:MetaNote, prevIndex:Int64, curIndex:Int64):Bool {
		var prevCorrection = File.getTimeCorrectionForIndex(prevIndex);
		var curCorrection = File.getTimeCorrectionForIndex(curIndex);
		return prev != -1
			&& prev.position + prevCorrection == current.position + curCorrection
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
			&& prev.index == current.index;
	}

	inline function mergeNoteIntoSprite(noteSpr:VirtualNote, n:MetaNote) {
		var alphaToAdd = n.flag ? Note.defaultMissAlpha : Note.defaultAlpha;
		noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
		noteSpr.notesInOne++;
	}
	
	function dispose() {
		threadRunning = false;
		for (thread in workerThreads) {
			try {
				thread = null;
			} catch (e) {}
		}
		workerThreads = [];
		workQueue = null;
		resultQueue = null;
	}
}

// Helper classes for thread communication
@:publicFields
class ThreadWork {
	var startIndex:Int64;
	var endIndex:Int64;
	var pos:Int64;

	function new() {}
}

@:publicFields
class ThreadResult {
	var notes:Array<{
		index:Int64,
		note:MetaNote,
		diff:Float,
		newY:Float,
		lane:Int,
		timeCorrection:Int64,
		position:Int64
	}>;
	
	function new() {
		notes = [];
	}
}