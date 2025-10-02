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

	var spawnDist:Int64 = MetaNote.floatToMetaNotePosition(1600);
	var despawnDist:Int64 = MetaNote.floatToMetaNotePosition(300);

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

		/*or (i in 0...File.getLength().low) {
			var note = File.getNote(i);
			var position = note.position;
			var duration = note.duration;
			var index = note.index;
			var type = note.type;
			trace('Position: $position, Duration: $duration, Index: $index, Type: $type');
		}*/
	}

	/**
	 * Updates the note spawner.
	 * @param pos The song's position in the note position format.
	 */
	function update(pos:Int64) {
		//Sys.println('Why');
		//var pos = MetaNote.floatToMetaNotePosition(songPosition);
		//Sys.println('Song Position ${parent.parent.songPosition}, MetaNote Song Position ${MetaNote.metaNotePositionToSongTime(pos)}');

		cullTop(pos);
		cullBottom(pos);

		Sys.println('Top $top bottom $bottom');

		var i = bottom;

		var scrollSpeed = parent.parent.scrollSpeed;
		var diff = 0.0;
		var noteY = 0;
		var noteSpr:Null<Note> = null;

		var prev:Null<MetaNote> = null;
		while (i < top) {
			var n = File.getNote(i);
			var position = n.position;
			var duration = n.duration;
			var index = n.index;
			var type = n.type;
			//trace('Position: $position, Duration: $duration, Index: $index, Type: $type');

			var ghost = prev.position == n.position && prev.index == n.index && prev.type == n.type;
			var lastDiff = diff;
			var lane = parent.noteTypeFunctionality.exists(n.type) ? 1 : (n.type % parent.strumlines.length);
			var receptor = parent.strumlines[lane].buffer[n.index];
			var lastNoteY = noteY;

			var requirementsForNoteOverlapSimulationBS = noteSpr != null
				&& floorByPixels(lastNoteY) == floorByPixels(noteY)
				&& (prev.position != n.position && prev.type == n.type)
				&& (prev.index == n.index && prev.type == n.type)
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
				diff = MetaNote.metaNotePositionToSongTime((n.position - pos)) * scrollSpeed;
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
		//Sys.println('Top song position ${MetaNote.metaNotePositionToSongTime(pos)}, Song position: $songPosition');
		//Sys.println('Top note position ${curTopNote.position}');
		//Sys.println('TOP: ' + (curTopNote.position - pos));
		//Sys.println('Top ${curTopNote.position - pos}');
		//Sys.println('Pos: $pos');
		while (top != len && curTopNote.position - pos < spawnDist) {
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
		//Sys.println('BOTTOM: ' + ((pos - MetaNote.intToMetaNoteDuration(curBottomNote.duration)) - curBottomNote.position));
		//Sys.println('Bottom song position $pos');
		//Sys.println('Bottom note position ${curBottomNote.position}');
		//Sys.println('Bottom ${curBottomNote.position - pos}');
		while ((pos - MetaNote.intToMetaNoteDuration(curBottomNote.duration)) - curBottomNote.position > despawnDist) {
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

		var songPos = MetaNote.floatToMetaNotePosition(songPosition);
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
		var dividend = (Main.INITIAL_HEIGHT / Main.VARIABLE_HEIGHT);
		return Math.floor(Math.floor(value / dividend) * dividend);
	}

	private var zero(default, null):Int64 = 0;
}