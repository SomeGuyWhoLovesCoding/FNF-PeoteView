package structures.gameplay;

/**
	The internal handler of the note system.
**/
@:publicFields
class NoteSpawner {
	var top:Int64;
	var bottom:Int64;

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

		top = 0;
		bottom = 0;

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

		while (i < top) {
			var note = file.getNote(i);
			parent.drawNote(pos, note);
			++i;
		}
	}

	// TODO: Make it so the `hit` property of each note you just hit resets back to false

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
			++bottom;
			curBottomNote = file.getNote(bottom);
		}
	}
}