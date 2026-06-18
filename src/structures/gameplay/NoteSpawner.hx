package structures.gameplay;

/**
 * This is where notes behave when interconnected to the note system.
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

	function new(parent:NoteSystem) {
		this.parent = parent;

		bottom = 0;
		top = 0;

		/*for (i in 0...20) {
			var note:MetaNote = File.getNote(i);
			Sys.println('Is it judged? ${File.getJudgement(i)}. Note flag? ${note.flag}. Here\'s the position of the note for reference: ${(note.position + File.getTimeCorrectionForIndex(i))}');
		}*/
	}

	var timeSpentOnIt:Float = 0;
	var timeSpentOnItIncrement:Float = 0;

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

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
		var latency = Main.conductor.offset;
		var latencyI64 = MetaNote.floatToMetaNotePosition(latency);

		pos += latencyI64;

		var i = (minBottom != -1 && bottom < minBottom) ? minBottom : bottom;
		var scrollSpeed = parent.parent.scrollSpeed;
		var prev:MetaNote = -1;
		var prevTimeCorrection:Int64 = 0;
		var noteSpr:VirtualNote = null;
		var j:Int = 0;

		var time = haxe.Timer.stamp();
		while (i < top) {
			if (top - i < 50) Sys.println('[NOTESYSTEM] Print note $i');
			var n = File.getNote(i);

			var lane = parent.noteTypeFunctionalityPre[n.type] != null
				? 1
				: (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var fakeOverlapStorage = parent.strumlines[lane].fakeOverlapStorage;

			var timeCorrection = File.getTimeCorrectionForIndex(i);
			var n_position = n.position + timeCorrection;

			var diff = (MetaNote.metaNotePositionToSongTime(n_position - pos)) * scrollSpeed;
			var newY = receptor.y + Math.floor(diff);

			var ghost = isGhostNote(prev, n, prevTimeCorrection, i);

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
			prevTimeCorrection = i;
			++i;
		}
		timeSpentOnIt = haxe.Timer.stamp() - time;

		pos -= latencyI64;
	}

	function cullTop(pos:Int64) {
		var len = File.getLength();

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
		var len = File.getLength();

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
}
