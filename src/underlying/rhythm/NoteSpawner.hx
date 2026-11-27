package underlying.rhythm;

/**
 * This is where notes behave when interconnected to the note system.
 * The behavior pass COUNTS EVERY NOTE: processNotes draws — and therefore
 * judges — each note in the window on its own timing. No overlap folding
 * happens here anymore; the ambient note occlusion lives in the render
 * block now (NoteSystem.renderVirtualNotes / renderVirtualSustains),
 * which is decoupled from this pass, so combo counting stays 100%
 * accurate while the pixels still fold.
 * @since Development
 */
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;

	// F12: minBottom is per-session state (the lowest note index whose miss
	// side effects have already run), so it is an INSTANCE field — as a
	// static it survived any dispose that was skipped (crash paths) and a
	// new session inherited a stale value from a previous chart, silently
	// censoring its window (invisible, un-judged notes until the playhead
	// passed the stale index). Initialized per instance below.
	var minBottom:Int64 = -1;

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
		minBottom = -1; // F12: fresh session, fresh censor guard
	}

	var timeSpentOnIt:Float = 0;
	var timeSpentOnItIncrement:Float = 0;

	// Set by the light reset (onChartMutated) so the binary-search edge
	// recycle runs exactly once per mutation — after the new window is
	// derived, before the edges take effect (v3.8.7).
	var notePoolNeedsEdgeRecycle:Bool = false;

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

		// === COUNT EVERY NOTE ===
		// Every note in the window is drawn — and therefore judged — on its
		// own timing here. The ambient-occlusion overlap folding no longer
		// happens in this behavior pass: it moved to the render block
		// (NoteSystem.renderVirtualNotes / renderVirtualSustains), which is
		// decoupled from note behavior. Each note is counted, judged and
		// scored individually (100% accurate combo counting); only the
		// PIXELS fold, purely visually, at render time.

		var i = (minBottom != -1 && bottom < minBottom) ? minBottom : bottom;
		var scrollSpeed = parent.parent.scrollSpeed;

		while (i < top) {
			if (parent.strumlines.length == 0)
				break; // no receptors available; nothing can be drawn
			var n = File.getNote(i);
			var diff = (MetaNote.metaNotePositionToSongTime(n.position - pos)) * scrollSpeed;
			parent.drawNote(pos, n, diff, i);
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

		// F7: reclaim the dead slot prefix once it dwarfs the live window
		// — a long forward scroll otherwise leaves one dead (null) entry
		// per chart note in the global-indexed slot arrays forever.
		parent.notePool.compactSlots(bottom, top);

		if (bottom < len)
			curBottomNote = File.getNote(bottom);
	}

	// v3.8.7 + F4: full-strip recycle for structural edits detected at
	// recycle time (NotePool.putNote/putSustain identity mismatch). The
	// light-reset strip is measured from the window edges; this variant
	// covers the UNION of the window and the minBottom cursor — every
	// slot key a shifted binding can be parked in — because processNotes
	// starts iterating at max(minBottom, bottom) and bindings between
	// minBottom and bottom were never recycled by the measured strip.
	function recycleWindowForEdit() {
		var lo = bottom;
		var hi = top;
		if (minBottom != -1 && minBottom < lo)
			lo = minBottom;
		parent.notePool.recycleWindowRange(lo, hi);
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
	// work are UNCHANGED, so none of it applies. What an edit does
	// invalidate is the window's global indexes (the store re-sorted):
	// those are re-derived below by binary search, O(log n). Skipped in
	// light mode: notePool.reset() (notesBuf clear + receptor re-add +
	// next-frame re-acquire and full re-upload of every visible note)
	// and the tail resetStrumlines() (per-lane 4097-entry LUT rebuild +
	// per-strumline notesBuf.update() GPU flush + per-receptor
	// ReceptorTimer allocation). The render pool reconciles itself on
	// the next frame via beginFrame/endFrame — the exact mechanism the
	// frozen seek relies on, where notes slide in and out of the window
	// with no reset at all (PlayFieldEditorMode.seekTo, frozen branch).
	//
	// v3.8.7: the binary search JUMPS the window edges, so slot
	// bindings that fell outside the new window would never be recycled
	// by the cull loops the search replaced (the leak: free stacks
	// deplete one binding per edit while the slots hold refs into a
	// store the edit may have erased). recycleWindowEdges recycles
	// exactly the two edge strips the window no longer covers — O(shift)
	// — before the new edges take effect.
	function resetNotes(songPosition:Float, pushToOffset:Float = 0, resetStrumlinesAfter:Bool = true, lightReset:Bool = false) {
		var pf = parent.parent;
		if (pf.disposed || pf.died)
			return;

		if (!lightReset)
			parent.notePool.reset();
		else
			notePoolNeedsEdgeRecycle = true;

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

		// v3.8.7: recycle the old window's slot bindings (see
		// NotePool.recycleWindowRange). Must run BEFORE the window edges
		// take their new values — the strip is measured from the OLD
		// window, and a structural edit inside the window shifts
		// in-window indexes without moving the edges at all.
		if (notePoolNeedsEdgeRecycle) {
			notePoolNeedsEdgeRecycle = false;
			// F4: recycle the UNION of the old window and the minBottom
			// cursor — bindings parked between minBottom and bottom (the
			// processNotes iteration start) were missed by the plain
			// [bottom, top) strip and stayed rooting stale MetaNotes.
			var lo = bottom;
			var hi = top;
			if (minBottom != -1 && minBottom < lo)
				lo = minBottom;
			parent.notePool.recycleWindowRange(lo, hi);
		}

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

		// (F7 compaction note: reset() above already emptied and re-based
		// the slot arrays at 0, so there is nothing left to compact here.)
	}
}
