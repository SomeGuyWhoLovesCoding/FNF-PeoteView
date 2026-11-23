package underlying.rhythm;

import underlying.rhythm.NoteVB.VirtualNote;
import underlying.rhythm.NoteVB.VirtualSustain;

/**
 * This is where notes behave when interconnected to the note system.
 * Ambient note occlusion is now the AUTOMATIC overlap removal system:
 * groups are precomputed in the chart loader (same strumline, receptor
 * column, notetype, duration and speed-2 timing row) and read here in
 * bulk from the chart-lifetime block — see overlapCounts and
 * File.getNotesFromRange. No per-frame pixel estimation is left.
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
	// Automatic overlap removal (the ambient-occlusion rework).
	//
	// Overlap is no longer ESTIMATED per frame from each note's current
	// pixel row — under lag that estimate could be stale for a frame, and
	// the combo/score/accuracy multipliers that ride on the sprite's
	// notesInOne (opponent/botplay auto-hit and miss paths) fluctuated
	// with it. It is now a precomputed chart property: the native loader
	// groups notes by (strumline lane, 256-wide receptor column,
	// notetype, duration, speed-2 timing row) and bakes each group's size
	// into 4 bytes per note — one persistent block for the whole chart
	// lifetime, read here in bulk once per pass.
	// ------------------------------------------------------------------
	#if cpp
	/** Pointer into the chart-lifetime overlap block, refetched each pass. */
	var overlapCounts(default, null):cpp.Pointer<cpp.UInt32>;
	/** Global note index that overlapCounts[0] corresponds to. */
	var overlapBase:Int64;
	#end

	/**
	 * The note's EXACT overlap-group size: a plain array index into the
	 * block captured this pass (cpp), falling back to the per-note extern
	 * call. Never below 1 — a lone note is its own group.
	 */
	inline function overlapCountOf(idx:Int64):Int {
		#if cpp
		if (overlapCounts != null && idx >= overlapBase)
			return overlapCounts[Int64.toInt(idx - overlapBase)];
		#end
		var c = File.getNoteOverlapCount(idx);
		return c > 0 ? c : 1;
	}

	function update(pos:Int64) {
		_lastbottom = bottom;
		_lasttop = top;

		// EDITOR MODE: the render path is pure (no judgement writes, no
		// miss/hit side effects), so the gameplay-only minBottom guard —
		// which exists to stop processNotes re-running miss side effects
		// on already-judged notes after a forward jump — must not censor
		// the window there. Clamp it to 0 per pass: every note between
		// bottom and top must draw, including ones behind the frozen
		// playhead (same as the un-paused editor at position 0 on entry).
		// Gameplay keeps its stored value untouched.
		if (parent.parent.playfieldEditorMode)
			minBottom = 0;

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
		var j:Int = 0;

		// One bulk read per pass: a pointer into the chart-lifetime
		// overlap block covering [i, top). The per-note lookups below are
		// plain array indexes into it — zero per-note extern calls.
		#if cpp
		overlapCounts = File.getNotesFromRange(i, top);
		overlapBase = i;
		#end

		// Open overlap classes of the CURRENT timing row: pruned the
		// moment the pass's position-sorted stream advances to a new row,
		// so it only ever holds the handful of classes sharing one
		// instant. (The native precompute groups by the same class
		// identity — receptor lane + column + notetype + duration +
		// speed-2 timing row — so the sprite a note merges into and the
		// combo count that sprite carries can never disagree.)
		var openClasses:Array<{lane:Int, idx:Int, type:Int, dur:Int, spr:VirtualNote}> = [];
		var passRow:Int64 = Int64.ofInt(-1);

		while (i < top) {
			var n = File.getNote(i);

			var strumCount = parent.strumlines.length;
			if (strumCount == 0)
				break; // no receptors available; nothing can be drawn
			// The lane is STORED on the note (v2 format) — clamped only
			// against a stale value, never re-derived from the type.
			var lane = NoteSystem.clampLane(n.lane, strumCount);

			var n_position = n.position;

			var diff = (MetaNote.metaNotePositionToSongTime(n_position - pos)) * scrollSpeed;

			var row = Int64.div(n_position, MetaNote.OVERLAP_ROW_TICKS);
			if (row != passRow) {
				// Rows never decrease (the stream is position-sorted):
				// every open class belongs to a row the stream has left
				// behind — drop them all at once.
				passRow = row;
				openClasses.resize(0);
			}

			// Does this note belong to one of this row's open classes?
			var mergeTarget:VirtualNote = null;
			for (openClass in openClasses) {
				if (openClass.lane == lane && openClass.idx == n.index && openClass.type == n.type && openClass.dur == n.duration) {
					mergeTarget = openClass.spr;
					break;
				}
			}

			if (mergeTarget != null) {
				mergeNoteIntoSprite(mergeTarget, i);
			} else {
				++j;
				var spr = parent.drawNote(pos, n, diff, i, overlapCountOf(i));
				if (spr != null)
					openClasses.push({lane: lane, idx: n.index, type: n.type, dur: n.duration, spr: spr});
			}

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
		// No `top > bottom` cross-guard: on a backward seek out of an
		// empty section, `top` must be allowed to walk BELOW the stale
		// `bottom` (the window is transiently inverted) so it can reach
		// the first note within spawn range of the new position. The
		// range condition alone is the correct bound — and since
		// despawnDist < spawnDist, `bottom <= top` re-establishes itself
		// as an invariant once both culls have run. The old guard is what
		// wedged the renderer in empty sections (top == bottom could
		// never move backward).
		while (top > 0) {
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
		// No `bottom < top` cross-guard, same reasoning as cullTop's
		// backward loop: a backward seek can transiently invert the window
		// (bottom must walk DOWN from a stale-high value while top has
		// already moved). The despawn range condition alone bounds the
		// loop; `bottom <= top` re-establishes itself because despawnDist
		// < spawnDist. The old guard is the other half of the empty-window
		// wedge (an empty section scrolled INTO could never reopen
		// backward either).
		while (bottom > 0) {
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
		// Window mirrors the cull semantics exactly:
		//   bottom = first note NOT yet despawned (pos - duration - notePos
		//            <= despawnDist  <=>  notePos >= songPos - despawnDist)
		//   top    = first note OUTSIDE spawn range (notePos - songPos
		//            >= spawnDist  <=>  notePos > songPos + spawnDist)
		// The old `songPos - spawnDist` top bound was an INVERTED offset
		// that made top <= bottom on every reset, leaving the window
		// empty until the next update's cull loops healed it.
		var minPos:Int64 = songPos - despawnDist;
		var maxPos:Int64 = songPos + spawnDist;

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

		// bottom/top are EXCLUSIVE window ends — both can legitimately be
		// == len (playhead past the last note). File.getNote(len) would
		// read out of bounds, so null them there instead.
		curBottomNote = bottom < len ? File.getNote(bottom) : null;
		curTopNote = top < len ? File.getNote(top) : null;

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

	inline function mergeNoteIntoSprite(noteSpr:VirtualNote, i:Int64) {
		var alphaToAdd = File.getHitFlag(i) ? Note.defaultMissAlpha : Note.defaultAlpha;
		noteSpr.addedAlpha = Math.min(noteSpr.addedAlpha + alphaToAdd, 256);
		// No notesInOne++ here: the sprite's count is the exact
		// precomputed group size, set at creation from the same block —
		// the stale-one-frame merge tally is gone for good.
	}
}
