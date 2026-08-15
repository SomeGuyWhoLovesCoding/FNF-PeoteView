package structures.notes;

import structures.notes.NoteVB.VirtualNote;
import structures.notes.NoteVB.VirtualSustain;

/**
 * This is where notes behave when interconnected to the note system.
 * TODO: Rework Ambient Note occlusion system to be better than ever.
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
	}

	var timeSpentOnIt:Float = 0;
	var timeSpentOnItIncrement:Float = 0;

	// ------------------------------------------------------------------
	// Overlap scale: precomputed inverse of (INITIAL_HEIGHT / VARIABLE_HEIGHT)
	// so the per-note overlap check uses multiplication instead of division.
	// Updated lazily when the window scale changes.
	// ------------------------------------------------------------------
	static var _overlapScaleInv:Float = 0;
	static var _overlapScaleCachedInitH:Float = -1;
	static var _overlapScaleCachedVarH:Float = -1;

	inline static function getOverlapScaleInv():Float {
		var initH = Main.INITIAL_HEIGHT;
		var varH = Main.VARIABLE_HEIGHT;
		if (initH != _overlapScaleCachedInitH || varH != _overlapScaleCachedVarH) {
			_overlapScaleInv = varH / initH;
			_overlapScaleCachedInitH = initH;
			_overlapScaleCachedVarH = varH;
		}
		return _overlapScaleInv;
	}

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		cullTop(pos);
		cullBottom(pos);

		if (parent.movingBackward) {
			for (i in 0...parent.strumlines.length) {
				var strumline = parent.strumlines[i];
				for (j in 0...strumline.receptors.length) {
					var receptor = strumline.receptors[j];
					receptor.noteToHit = null;
					receptor.noteToHit_index = 0;
				}
			}
		}

		processNotes(pos);
	}

	function processNotes(pos:Int64) {
		// pos is already latency-corrected noteTime as Int64 from PlayField
		// No conductor.offset adjustment needed

		var i = (minBottom != -1 && bottom < minBottom) ? minBottom : bottom;
		var scrollSpeed = parent.parent.scrollSpeed;
		var noteSpr:VirtualNote = null;
		var j:Int = 0;

		// Precompute overlap scale inverse once for the entire loop
		var overlapInv = getOverlapScaleInv();

		while (i < top) {
			var n = File.getNote(i);

			var strumCount = parent.strumlines.length;
			if (strumCount == 0)
				break; // no receptors available; nothing can be drawn
			var lane = n.type % strumCount;
			var strumline = parent.strumlines[lane];
			var receptor = strumline.receptors[n.index];
			var rec = receptor.note;

			var n_position = n.position;

			var diff = (MetaNote.metaNotePositionToSongTime(n_position - pos)) * scrollSpeed;
			var newY = rec.y + Math.floor(diff);

			var prevNote = strumline.getPrevNote(n.index);

			receptor.ambientOccludeYCur = newY;

			var shouldOverlap = noteSpr != null
				&& shouldNotesOverlap(prevNote, n, noteSpr, rec, receptor.ambientOccludeYPrev, receptor.ambientOccludeYCur, overlapInv);

			if (shouldOverlap) {
				mergeNoteIntoSprite(noteSpr, i);
			} else {
				++j;
				noteSpr = parent.drawNote(pos, n, diff, i);
			}

			strumline.setPrevNote(n.index, n);
			receptor.ambientOccludeYPrev = receptor.ambientOccludeYCur;
			++i;
		}

	}

	function cullTop(pos:Int64) {
		var len = File.getLength();

		// === FORWARD: Include notes now within spawn range ===
		while (top < len) {
			var n = File.getNote(top);
			if (n.position - pos >= spawnDist)
				break;
			++top;
		}

		// === BACKWARD: Exclude notes now too far ahead ===
		while (top > bottom) {
			var n = File.getNote(top - 1);
			if (n.position - pos < spawnDist)
				break;
			--top;
		}

		if (top < len)
			curTopNote = File.getNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = File.getLength();

		// === FORWARD: Exclude notes that have despawned ===
		while (bottom < len) {
			var n = File.getNote(bottom);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
			if (despawnCheck <= despawnDist)
				break;
			var notePool = parent.notePool;
			notePool.putNote(n, bottom);
			notePool.putSustain(n, bottom);
			++bottom;
		}

		// === BACKWARD: Include notes now back in range ===
		while (bottom > 0 && bottom < top) {
			var n = File.getNote(bottom - 1);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
			if (despawnCheck > despawnDist)
				break;
			--bottom;
		}

		if (bottom < len)
			curBottomNote = File.getNote(bottom);
	}

	function resetNotes(songPosition:Float, pushToOffset:Float = 0) {
		var pf = parent.parent;
		if (pf.disposed || pf.died)
			return;

		parent.notePool.reset();

		var len = File.getLength();
		if (len <= 0)
			return;

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		var minPos:Int64 = songPos;
		var maxPos:Int64 = songPos - spawnDist;

		function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0, hi:Int64 = len;
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
			var lo:Int64 = 0, hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position <= target)
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

	function renderVirtualNotes(notes:NoteVB, pos:Int64) {
		var downScroll = parent.parent.downScroll;
		var virtualNotes = notes.notes;
		for (i in 0...virtualNotes.length) {
			var lane = virtualNotes[i];
			var strumline = parent.strumlines[i];
			var maxReceptor = strumline.receptors.length;
			for (j in 0...Std.int(Math.min(lane.length, maxReceptor))) {
				var index = lane[j];
				var length = notes.noteLength[i][j];
				if (length == 0)
					continue;
				var receptor = strumline.receptors[j];
				var strumReceptor = receptor.note;

				// Lane-constant values hoisted from inner loop
				var mania = strumline.length;
				var baseScrollDir = strumReceptor.scrollDirection;
				if (downScroll)
					baseScrollDir += 180;

				var k = 0;
				while (k < length) {
					var virtualNote:VirtualNote = index[k];
					k++;
					if (virtualNote == null)
						continue;

					var handle = NoteSystem.typeToHandle[virtualNote.ref.type];
					var note = parent.notePool.acquireNote();

					if (note.handle != handle || note.texUnit != handle.texUnit || note.texSlot != handle.texSlot)
						note.setHandle(handle);
					note.x = virtualNote.Sx;
					note.y = virtualNote.Sy;
					note.scale = virtualNote.scale;
					note.initialAlpha = virtualNote.initialAlpha;
					note.addedAlpha = virtualNote.addedAlpha;

					note.mania_for_clipruntimehelper = mania;
					note.diff = -virtualNote.diff;
					note.scrollDirection = baseScrollDir;

					note.changeID(j);
					note.toNote();

					var noteToHitIdx = receptor.noteToHit_index;
					receptor.noteToHit_sprite = noteToHitIdx == virtualNote.globalIndex ? note : null;
				}
			}
		}
	}

	function renderVirtualSustains(notes:NoteVB) {
		var downScroll = parent.parent.downScroll;
		var virtualSustains = notes.sustains;
		for (i in 0...virtualSustains.length) {
			var lane = virtualSustains[i];
			var strumline = parent.strumlines[i];
			var maxReceptor = strumline.receptors.length;
			for (j in 0...Std.int(Math.min(lane.length, maxReceptor))) {
				var index = lane[j];
				var length = notes.sustainLength[i][j];
				var receptor = strumline.receptors[j];
				var strumReceptor = receptor.note;

				// Lane-constant values hoisted from inner loop
				var mania = strumline.length;
				var baseScrollDir = strumReceptor.scrollDirection;
				var baseRot = baseScrollDir;
				if (downScroll) {
					baseRot += 180;
					baseScrollDir += 180;
				}

				for (k in 0...length) {
					var virtualSustain:VirtualSustain = index[k];
					if (virtualSustain == null)
						continue;

					var handle = NoteSystem.typeToHandle[virtualSustain.ref.ref.type];
					var sustain = parent.notePool.acquireSustain();

					if (sustain.handle != handle || sustain.texUnit != handle.texUnit || sustain.texSlot != handle.texSlot)
						sustain.setHandle(handle);
					sustain.x = virtualSustain.Sx;
					sustain.y = virtualSustain.Sy;
					sustain.w = virtualSustain.w;
					sustain.speed = virtualSustain.speed;
					sustain.scale = virtualSustain.scale;

					sustain.mania_for_clipruntimehelper = mania;
					sustain.length = virtualSustain.length;
					sustain.c.aF = virtualSustain.alpha;
					sustain.c.luminanceF = virtualSustain.alpha;
					sustain.diff = -virtualSustain.diff;
					sustain.scrollDirection = baseScrollDir;
					sustain.r = baseRot;
					sustain.changeID(j);
				}
			}
		}
	}

	/**
	 * Overlap check — uses precomputed inverse scale (multiplication)
	 * instead of division per-note.
	 *
	 * @param overlapInv  Precomputed VARIABLE_HEIGHT / INITIAL_HEIGHT
	 */
	inline function shouldNotesOverlap(prev:MetaNote, current:MetaNote, noteSpr:VirtualNote, receptor:Note, newY:Int, prevY:Int, overlapInv:Float):Bool {
		if (noteSpr == null || prev == null)
			return false;

		var OVERLAP_PIXEL_THRESHOLD = 0;

		// Multiplication (overlapInv) replaces division by (INITIAL_HEIGHT / VARIABLE_HEIGHT).
		// Mathematically: floor(y / (IH/VH)) == floor(y * (VH/IH))
		var pixelDiff = Math.abs(Math.floor(newY * overlapInv) - Math.floor(prevY * overlapInv));

		return pixelDiff <= OVERLAP_PIXEL_THRESHOLD
			&& prev.type == current.type
			&& noteSpr.scale == receptor.scale
			&& prev.duration == current.duration
			&& prev.index == current.index;
	}

	inline function mergeNoteIntoSprite(noteSpr:VirtualNote, i:Int64) {
		var alphaToAdd = File.getHitFlag(i) ? Note.defaultMissAlpha : Note.defaultAlpha;
		noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
		noteSpr.notesInOne++;
	}
}
