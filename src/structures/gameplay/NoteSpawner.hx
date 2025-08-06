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

	var file(default, null):File;

	var parent(default, null):NoteSystem;

	/**
	 * Creates the note spawner.
	 * @param file The chart file to import onto the note spawner.
	 */
	function new(file:File, parent:NoteSystem) {
		this.file = file;
		this.parent = parent;

		bottom = 0;
		top = 0;

		curTopNote = file.getNote(0);
		curBottomNote = file.getNote(0);
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
		var noteSpr:Null<Note> = null;

		var prev:Null<MetaNote> = null;
		while (i < top) {
			var n = file.getNote(i);

			var ghost = prev.position == n.position && prev.index == n.index && prev.lane == n.lane;
			var lastDiff = diff;
			var receptor = parent.strumlines[n.lane].buffer[n.index];

			var requirementsForNoteOverlapSimulationBS = noteSpr != null
				&& floorByPixels(lastDiff) == floorByPixels(diff)
				&& (prev.position != n.position && prev.type == n.type)
				&& (prev.index == n.index && prev.lane == n.lane)
				&& (noteSpr.r == 0 /* 0 is the default angle for the note sprite */)
				&& (noteSpr.w == receptor.w && noteSpr.h == receptor.h)
				&& (noteSpr.scale == receptor.scale)
				&& (prev.duration == n.duration)
			&& noteSpr.x == receptor.x;

			if (requirementsForNoteOverlapSimulationBS) {
				noteSpr.addedAlpha += parent.notesMissed[n] ? Note.defaultMissAlpha : Note.defaultAlpha;
				prev = n;
				++i;
				continue;
			} else {
				diff = (Int64.toInt(n.position - pos) * 0.01) * scrollSpeed;
				if (!ghost) noteSpr = parent.drawNote(pos, n, diff);
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
		var len = file.length;
		while (top != len && (curTopNote.position - pos).low < spawnDist) {
			++top;
			curTopNote = file.getNote(top);
		}
	}

	/**
	 * Culls the bottom note cull.
	 * @param pos The song's position in the note position format.
	 */
	function cullBottom(pos:Int64) {
		var len = file.length;
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

			curBottomNote = file.getNote(bottom);
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

		var file = pf.chart.file;
		var len = file.length;

		var incrementAmount = (len / 100) * 25;
		var decrementAmount = (len / 100) * 12;

		var songPos = Tools.betterInt64FromFloat(songPosition * 100);
		var songPosTop = songPos + spawnDist;

		if (file.getNote(0).position > songPosTop || file.getNote(0).position > songPos) {
			top = bottom = 0;
			curBottomNote = curTopNote = file.getNote(0);
			parent.resetStrumlines();
			return;
		}

		var lenSub1 = len - 1;

		while (file.getNote(top).position < songPosTop) {
			if ((top += incrementAmount) > lenSub1) top = lenSub1;
		}
		while (file.getNote(top--).position > songPosTop) {}

		bottom = top;

		while (file.getNote(bottom).position > songPos) {
			if ((bottom -= decrementAmount) < zero) bottom = zero;
		}
		while (file.getNote(bottom++).position < songPos) {}

		curBottomNote = file.getNote(bottom);
		curTopNote = file.getNote(top);

		parent.resetStrumlines();
	}

	/**
	 * Floors the given value by pixels.
	 * @param value The value to floor.
	 * @return The floored value.
	 */
	function floorByPixels(value:Float):Int {
		var dividend = Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT;
		return Int64.fromFloat(Math.floor(value * dividend) / dividend);
	}

	private var zero(default, null):Int64 = 0;
}