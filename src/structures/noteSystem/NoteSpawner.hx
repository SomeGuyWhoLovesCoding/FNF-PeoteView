package structures.noteSystem;

/**
  The park of the note system.
**/
@:publicFields
class NoteSpawner {
    var top:Int64;
    var bottom:Int64;

	var spawnDist(default, null):Int = 160000;
	var despawnDist(default, null):Int = 30000;

	inline function setScrollSpeed(value:Float) {
		spawnDist = Math.floor(160000 / value);
		despawnDist = Math.floor(40000 / Math.min(value, 1.0));
		Main.current.playField.hitbox = 200 * value;
		return value;
	}

	var curTopNote(default, null):MetaNote;
	var curBottomNote(default, null):MetaNote;

    var file(default, null):File;

    function new(file:File) {
        this.file = file;

        top = 0;
        bottom = 0;

        curTopNote = file.getNote(0);
        curBottomNote = file.getNote(0);
    }

    function update(pos:Int64) {
        cullTop(pos);
        cullBottom(pos);
    }

    function draw(notesBuf:Buffer<Note>, sustainBuf:Buffer<Sustain>) {
        var i = top;
        while (i < bottom) {
            ++i;
        }
    }

    function cullTop(pos:Int64) {
        var len = file.length;
		while (top != len && (curTopNote.position - pos).low < spawnDist) {
			++top;
			curTopNote = file.getNote(top);
		}
	}

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