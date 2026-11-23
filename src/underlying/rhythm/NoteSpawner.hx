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
}
