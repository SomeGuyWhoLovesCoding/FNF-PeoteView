package structures.gameplay;

/**
	The internal handler of the note system.
**/
@:publicFields
class NoteSpawner {
	var top:Int64;
	var bottom:Int64;

	var spawnDist(default, null):Int = 160000;
	var despawnDist(default, null):Int = 30000;

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

	var file(default, null):File;

	/**
	 * Creates the note spawner.
	 * @param file The chart file to import onto the note spawner.
	 */
	function new(file:File) {
		this.file = file;

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
	}

	/**
	 * Draws to the note system.
	 * @param notesBuf The note buffer where the strumlines are also stored to.
	 * @param sustainsBuf The sustain buffer behind the note buffer.
	 */
	function draw(notesBuf:Buffer<Note>, sustainsBuf:Buffer<Sustain>) {
		var i = top;

		while (i < bottom) {

			++i;
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
			++bottom;
			curBottomNote = file.getNote(bottom);
		}
	}
}