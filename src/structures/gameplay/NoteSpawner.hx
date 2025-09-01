package structures.gameplay;

/**
	The internal note handler.
	This class is responsible for spawning and despawning notes based on the song's position.
	It handles the culling of notes that are too far away from the current position, and it draws the notes that are within the spawn distance.
	It also handles the resetting of notes when the song position changes significantly.
	@since Development
**/
@:publicFields
class NoteSpawner {
	var bottom:Int64;
	var top:Int64;

	var spawnDist:Int = 160000;
	var despawnDist:Int = 30000;

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note spawner.
	 * @param parent The note system to implement this note spawner on.
	 */
	function new(parent:NoteSystem) {
		this.parent = parent;

		bottom = 0;
		top = 0;

		curTopNote = File.getNote(0);
		curBottomNote = File.getNote(0);
	}

	/**
	 * Updates the note spawner.
	 * @param pos The song's position in the note position format.
	 */
	function update(pos:Int64) {
		cullTop(pos);
		cullBottom(pos);

		var i = bottom;

		var scrollSpeed = parent.parent.scrollSpeed;
		var diff = 0.0;
		var noteY = 0;
		var noteSpr:Null<Note> = null;

		var prev:Null<MetaNote> = null;
		while (i < top) {
			var n = File.getNote(i);

			var ghost = prev.position == n.position && prev.index == n.index && prev.lane == n.lane;
			var lastDiff = diff;
			var receptor = parent.strumlines[n.lane].buffer[n.index];
			var lastNoteY = noteY;

			var requirementsForNoteOverlapSimulationBS = noteSpr != null
				&& floorByPixels(lastNoteY) == floorByPixels(noteY)
				&& (prev.position != n.position && prev.type == n.type)
				&& (prev.index == n.index && prev.lane == n.lane)
				&& (noteSpr.r == 0 /* 0 is the default angle for the note sprite */)
				&& (noteSpr.w == receptor.w && noteSpr.h == receptor.h)
				&& (noteSpr.scale == receptor.scale)
				&& (prev.duration == n.duration)
			&& noteSpr.x == receptor.x;

			if (requirementsForNoteOverlapSimulationBS) {
				noteSpr.addedAlpha += parent.notesMissed.get(n) ? Note.defaultMissAlpha : Note.defaultAlpha;
				noteSpr.notesInOne++;
				prev = n;
				++i;
				continue;
			} else {
				diff = (Int64.toInt(n.position - pos) * 0.01) * scrollSpeed;
				noteY = receptor.y + Math.floor(diff);
				if (!ghost) noteSpr = parent.drawNote(pos, n, diff);
				else noteSpr.notesInOne++;
				prev = n;
				++i;
			}
		}
	}

	/**
	 * Culls the top note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullTop(pos:Int64) {
		var len = File.getLength();
		while (top != len && (curTopNote.position - pos).low < spawnDist) {
			++top;
			curTopNote = File.getNote(top);
		}
	}

	/**
	 * Culls the bottom note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullBottom(pos:Int64) {
		var len = File.getLength();
		while (bottom != len &&
			((pos -
			(
				((curBottomNote.duration << 2) + curBottomNote.duration) * 100
			)) -
			curBottomNote.position).low > despawnDist) {
			parent.notesHit.remove(curBottomNote);
			parent.notesMissed.remove(curBottomNote);
			parent.notesHeld.remove(curBottomNote);

			var notePool = parent.notePool;
			notePool.putNote(curBottomNote);
			notePool.putSustain(curBottomNote);

			++bottom;

			curBottomNote = File.getNote(bottom);
		}
	}

	/**
	 * Reload the notes.
	 * @param songPosition The time from the song.
	 */
	function resetNotes(songPosition:Float) {
		var pf = parent.parent;
		if (pf.disposed || pf.died) return;

		parent.notesHit.clear();
		parent.notesMissed.clear();
		parent.notesHeld.clear();

		var len = File.getLength();
		if (len <= 0) return; // no notes, nothing to do

		var songPos = Tools.betterInt64FromFloat(songPosition * 100);
		var songPosTop = songPos + spawnDist;

		// --- Fast check: before first note ---
		var firstNote = File.getNote(0);
		if (firstNote.position > songPosTop || firstNote.position > songPos) {
			top = bottom = 0;
			curBottomNote = curTopNote = firstNote;
			parent.resetStrumlines();
			return;
		}

		// --- Fast check: after last note ---
		var lastNote = File.getNote(len - 1);
		if (lastNote.position < songPos) {
			// clamp to last note so we don't freeze
			top = bottom = len - 1;
			curBottomNote = curTopNote = lastNote;
			parent.resetStrumlines();
			return;
		}

		// --- Binary search helpers ---
		inline function lowerBound(target:Int64):Int64 {
			var lo:Int64 = 0;
			var hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position < target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		inline function upperBound(target:Int64):Int64 {
			var lo:Int64 = 0;
			var hi:Int64 = len;
			while (lo < hi) {
				var mid = (lo + hi) >> 1;
				if (File.getNote(mid).position <= target)
					lo = mid + 1;
				else
					hi = mid;
			}
			return lo;
		}

		// --- Find bottom (first note >= songPos) ---
		bottom = lowerBound(songPos);
		if (bottom >= len) bottom = len - 1;

		// --- Find top (last note <= songPosTop) ---
		top = upperBound(songPosTop) - 1;
		if (top < 0) top = 0;

		curBottomNote = File.getNote(bottom);
		curTopNote = File.getNote(top);

		parent.resetStrumlines();
	}

	/**
	 * Floors the given value by pixels.
	 * @param value The value to floor.
	 * @return The floored value.
	 */
	function floorByPixels(value:Float):Int {
		var dividend = (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT) * parent.parent.display.zoom;
		return Math.floor(Math.floor(value * dividend) / dividend);
	}

	private var zero(default, null):Int64 = 0;
}