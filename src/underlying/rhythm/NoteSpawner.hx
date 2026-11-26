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
			// v3.9.1: the in-window walk reads through the pool's
			// window-note cache (fetchNote) — one MetaNote allocation per
			// note when it ENTERS the window, zero per frame after that.
			// The old File.getNote(i) here allocated ~4,190 fresh
			// MetaNotes per frame on a 2.36M-note chart (the walk
			// re-fetched every in-window note every frame).
			var n = parent.notePool.fetchNote(i);
			var diff = (MetaNote.metaNotePositionToSongTime(n.position - pos)) * scrollSpeed;
			parent.drawNote(pos, n, diff, i);
			++i;
		}

	}

	function cullTop(pos:Int64) {
		var len = File.getLength();
		var notePool = parent.notePool;

		// v3.9.2 FIRST-FRAME HEAL: a reset that primed entries before
		// the first cull ran can leave the cache epoch's base ABOVE the
		// window the culls are about to establish (fetchNote primes at
		// whatever index was asked for first — the first reset reads
		// bottom's note). Anchoring the base to the CURRENT bottom here
		// (a no-op whenever the base already sits at or below bottom —
		// the steady state) guarantees every fetch in this pass maps
		// inside the cached span, so cullTop's probes are all cache
		// hits and the walk allocates nothing.
		notePool.advanceWindowTo(bottom);

		// === FORWARD: Include notes now within spawn range ===
		// v3.9.1/v3.9.2: this loop is where entering notes get their
		// cache entry PRIMED (a pooled MetaNote, re-SET in place —
		// zero steady-state allocation); the cull itself only probes
		// ONE note per step — the note at the edge — so the misses here
		// are one per NEW window member, the exact rate the pool pays.
		while (top < len) {
			var n = notePool.fetchNote(top);
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
		//
		// v3.9.2: the backward probe is gated on movingBackward. In pure
		// forward play the edge note is IN THE CACHE (primed on entry,
		// still cached — nothing re-fetches it off the top), so this loop
		// would pay one UNPOOLED getNote per frame for a check the window
		// arithmetic already answers. Backward play (a seek) re-opens
		// the window above and may read notes the cache no longer
		// covers — those fetch uncached and re-prime, as designed.
		if (parent.movingBackward) {
			while (top > 0) {
				var n = notePool.fetchNote(top - 1);
				if (n.position - pos < spawnDist)
					break;
				--top;
			}
		}

		if (top < len)
			curTopNote = notePool.fetchNote(top);
	}

	function cullBottom(pos:Int64) {
		var len = File.getLength();
		var notePool = parent.notePool;

		// === FORWARD: Exclude notes that have despawned ===
		// v3.9.2: the despawn probe reads through the cache too — the
		// note at `advancedBottom` is the window's bottom edge, cached
		// since it entered, so the probe is a cache hit (the old plain
		// getNote here was the last per-frame allocation in the walk).
		var advancedBottom = bottom;
		while (advancedBottom < len) {
			var n = notePool.fetchNote(advancedBottom);
			var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
			if (despawnCheck <= despawnDist)
				break;
			notePool.putNote(n, advancedBottom);
			notePool.putSustain(n, advancedBottom);
			++advancedBottom;
		}
		// v3.9.1/v3.9.2: the window-note cache compacts here, exactly
		// where the leading edge advances — the dropped indexes can never
		// be fetched again (every hot walk anchors inside [bottom, top)),
		// and the re-base keeps the cache array window-sized for the
		// whole playthrough instead of growing to chart length. The
		// dropped POOLED MetaNotes return to the free pool inside
		// advanceWindowTo and are re-SET for the next entering note:
		// steady state recycles the same window-sized object set forever.
		if (advancedBottom != bottom) {
			notePool.advanceWindowTo(advancedBottom);
			bottom = advancedBottom;
			// v3.9.2 STALE-REF SWEEP: pooled MetaNotes are MUTATED in
			// place now — a receptor (noteToHit / sustainToHold) still
			// holding one of the notes that just despawned is pointing
			// at an object whose fields are about to be re-set for a
			// NEW note. The old architecture never had this hazard: each
			// note was its own object. Clear the receptor fields whose
			// note fell out of the window here — the same note-leave
			// moment update() already handles for movingBackward.
			sweepReceptorsForLeftNotes();
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
		// v3.9.2: gated on movingBackward — in pure forward play
		// bottom only ever advances (the despawn pass above), so this
		// loop's probe would pay one uncached getNote per frame for a
		// question the window arithmetic already answered. Backward play
		// (a seek) re-opens the window below and re-primes through
		// fetchNote as designed.
		if (parent.movingBackward) {
			while (bottom > 0) {
				var n = notePool.fetchNote(bottom - 1);
				var despawnCheck = pos - MetaNote.intToMetaNoteDuration(n.duration) - n.position;
				if (despawnCheck > despawnDist)
					break;
				--bottom;
			}
			notePool.advanceWindowTo(bottom);
		}

		if (bottom < len)
			curBottomNote = notePool.fetchNote(bottom);
	}

	/**
	 * v3.9.2: clears the per-receptor note references whose notes just
	 * left the window. Pooled MetaNotes are re-set in place when their
	 * slot re-enters the pool, so a receptor holding a departed note
	 * would read the fields of a DIFFERENT note (judgement reads by
	 * index stay correct — receptor.noteToHit_index is the authority;
	 * the object ref is only a field cache). Cost: receptors x 4 field
	 * writes, only on frames where the leading edge actually advanced
	 * (the despawn tick — a few times a second on normal charts, the
	 * wall rate on spam charts).
	 */
	function sweepReceptorsForLeftNotes() {
		for (i in 0...parent.strumlines.length) {
			var strumline = parent.strumlines[i];
			for (j in 0...strumline.receptors.length) {
				var receptor = strumline.receptors[j];
				if (receptor.noteToHit != null) {
					var gi = receptor.noteToHit_index;
					if (gi < bottom || gi >= top) {
						receptor.noteToHit = null;
						receptor.noteToHit_index = 0;
					}
				}
				if (receptor.sustainToHold != null) {
					var sgi = receptor.sustainToHold_index;
					if (sgi < bottom || sgi >= top) {
						receptor.sustainToHold = null;
						receptor.sustainToHold_index = 0;
						receptor.sustainToHold_duration = 0;
					}
				}
			}
		}
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

		// v3.9.2: the search probes read through fetchNote — they converge
		// on the new window's edges, so the last probes prime exactly the
		// edge notes the next frame reads (and the pool takes the middle
		// probe misses back, re-set for entering notes). Allocation-free
		// on every target: a miss pops a pooled MetaNote and re-sets it.
		function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0, hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (parent.notePool.fetchNote(mid).position < target)
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
				if (parent.notePool.fetchNote(mid).position <= target)
				lo = mid + 1;
				else
				hi = mid;
			}
			return lo;
		}

		var newBottom = lowerBound(minPos);
		var newTop = upperBound(maxPos);

		// v3.9.1: the re-derived window anchors a fresh cache epoch —
		// the light reset's edge recycle (recycleWindowRange) ran with
		// the OLD window's strip, and the new [bottom, top) can be far
		// from the old one (a seek). Re-basing the cache to the NEW
		// bottom drops everything the new window left behind; the
		// prime-on-fetch behavior rebuilds exactly what it covers.
		parent.notePool.advanceWindowTo(newBottom);

		// v3.8.7: recycle the old window's slot bindings (see
		// NotePool.recycleWindowRange). Must run BEFORE the window edges
		// take their new values — the strip is measured from the OLD
		// window, and a structural edit inside the window shifts
		// in-window indexes without moving the edges at all.
		if (notePoolNeedsEdgeRecycle) {
			notePoolNeedsEdgeRecycle = false;
			parent.notePool.recycleWindowRange(bottom, top);
		}

		minBottom = lowerBound(songPos + MetaNote.floatToMetaNotePosition(pushToOffset));

		bottom = newBottom;
		top = newTop;

		// bottom/top are EXCLUSIVE window ends — both can legitimately be
		// == len (playhead past the last note). File.getNote(len) would
		// read out of bounds, so null them there instead.
		curBottomNote = bottom < len ? parent.notePool.fetchNote(bottom) : null;
		curTopNote = top < len ? parent.notePool.fetchNote(top) : null;

		if (resetStrumlinesAfter && !lightReset)
			parent.resetStrumlines();
	}
}
