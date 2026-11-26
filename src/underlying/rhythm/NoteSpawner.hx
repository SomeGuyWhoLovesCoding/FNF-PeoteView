package underlying.rhythm;

import underlying.data.chart.File;
import underlying.data.chart.MetaNote;

/**
	This is where notes behave when interconnected to the note system.
	The behavior pass COUNTS EVERY NOTE: processNotes draws — and therefore
	judges — each note in the window on its own timing. No overlap folding
	happens here anymore; the ambient note occlusion lives in the render
	block now (NoteSystem.renderVirtualNotes / renderVirtualSustains),
	which is decoupled from this pass, so combo counting stays 100%
	accurate while the pixels still fold.

	v3.9.0: the spawn pass drives the chart extern's GTFR protocol — the
	virtual-note state lives in the extern's packed, grow-only arenas,
	not in Haxe objects. `generateNotesFromRange_startIterationFromTimeRange`
	is the exactly-once loop the C++ side guarantees (head/tail live there;
	the loop's start/end variables are loop decoration).
	@since Development
**/
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

	/**
		v3.9.0 — the GTFR window sweep. The whole window [bottom, top)
		runs through the chart extern's exactly-once protocol: NOTE hands
		back the packed first8+last4 (the bits MetaNote decodes — no
		boxing, the decode struct is a stack value), INDEX the store id
		of that same note, RECYCLE drops that id's dead arena bindings.
		drawNote is the behavior pass (judge/score/receptor work) and the
		GTFR binds carry the render state out.
	**/
	function processNotes(pos:Int64) {
		// pos is already latency-corrected noteTime as Int64 from PlayField
		// No conductor.offset adjustment needed

		// === COUNT EVERY NOTE ===
		// Every note in the window is drawn — and therefore judged — on its
		// own timing here. The ambient-occlusion overlap folding no longer
		// happens in this behavior pass: it moved to the render block
		// (NoteSystem.renderVirtualNotes / renderVirtualSustains), which is
		// decoupled from note behavior. Each note is counted, judged and
		// scored individually (100% accurate combo counting); only the
		// PIXELS fold, purely visually, at render time.

		if (parent.strumlines.length == 0)
			return; // no receptors available; nothing can be drawn

		var scrollSpeed = parent.parent.scrollSpeed;
		var i = (minBottom != -1 && bottom < minBottom) ? minBottom : bottom;

		File.GTFR_START(i, top);
		while (File.GTFR_PROGRESS(i, top)) {
			var note:MetaNote = File.GTFR_NOTE();
			var noteIndex:Int64 = File.GTFR_INDEX_THEN_ADVANCE();
			File.GTFR_VIRTUAL_NOTE_RECYCLE();

			var diff = (MetaNote.metaNotePositionToSongTime(note.position - pos)) * scrollSpeed;
			parent.drawNote(pos, note, diff, noteIndex);
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
		// The despawned note's arena binding is dropped by the GTFR
		// RECYCLE the next time the window sweep crosses its id — the
		// v3.9.0 discipline (no cull-time pool calls at all).
		while (bottom < len) {
			var n = File.getNote(bottom);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
			if (despawnCheck <= despawnDist)
				break;
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

	// resetStrumlinesAfter: the per-edit path (NoteSystem.onSongPositionJump)
	// already ran resetStrumlines() itself before calling in, so it passes
	// false and the duplicate rebuild (movement LUTs over every lane x 4097,
	// receptor repositions, notesBuf GPU flush) is skipped. Every other
	// caller keeps the default true and resets exactly once, here at the
	// end, as before.
	//
	// lightReset: the chart-mutation path (NoteSystem.onChartMutated —
	// every editor add/remove/replace/undo/paste). A chart edit does not
	// move the playhead, reposition receptors, or touch scroll
	// direction/speed/formula — the inputs of all the heavyweight reset
	// work are UNCHANGED, so none of it applies. What an edit DOES
	// invalidate is the window's global indexes (the store re-sorted):
	// the GTFR discipline covers it — the old window is swept with
	// recycle-only (every binding drops), then the new window's normal
	// processNotes rebinds from the iteration itself. No binary search,
	// no free stacks, no GPU reset at all.
	function resetNotes(songPosition:Float, pushToOffset:Float = 0, resetStrumlinesAfter:Bool = true, lightReset:Bool = false) {
		var pf = parent.parent;
		if (pf.disposed || pf.died)
			return;

		var len = File.getLength();

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
		// Window mirrors the cull semantics exactly:
		//   bottom = first note NOT yet despawned (pos - duration - notePos
		//            <= despawnDist  <=>  notePos >= songPos - despawnDist)
		//   top    = first note OUTSIDE spawn range (notePos - songPos
		//            >= spawnDist  <=>  notePos > songPos + spawnDist)
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

		// v3.9.0: on a chart edit the OLD window's arena bindings are
		// recycled with the GTFR loop itself — the same exactly-once
		// protocol, recycle-only (no drawNote): every binding of the
		// old window drops in one pass, then the next update()'s
		// processNotes rebinds the new window from the iteration.
		// Stale bindings cannot survive the edit's frame.
		if (lightReset) {
			File.GTFR_START(bottom, top);
			while (File.GTFR_PROGRESS(bottom, top)) {
				File.GTFR_NOTE_THEN_ADVANCE();
				File.GTFR_INDEX_THEN_ADVANCE();
				File.GTFR_VIRTUAL_NOTE_RECYCLE();
			}
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

		if (resetStrumlinesAfter && !lightReset)
			parent.resetStrumlines();
	}
}
