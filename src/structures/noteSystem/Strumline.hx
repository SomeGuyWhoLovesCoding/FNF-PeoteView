package structures.noteSystem;

/**
	Strumline class for the note system.
**/
@:publicFields
class Strumline {
	var x(default, set):Int;
	var y(default, set):Int;
	var scale(default, set):Float;
	var gap(default, set):Int;
	var length(default, set):Int;

	function set_x(value:Int) {
		for (i in 0...length) {
			buffer[i].x = value + Math.floor(gap * i);
		}
		return x = value;
	}

	function set_y(value:Int) {
		for (i in 0...length) {
			buffer[i].y = value;
		}
		return y = value;
	}

	function set_scale(value:Float) {
		for (i in 0...length) {
			buffer[i].scale = value;
		}
		return scale = value;
	}

	inline function set_gap(value:Int) {
		gap = value;
		set_x(x);
		return value;
	}

	function set_length(value:Int) {
		notesToHit.resize(value);
		buffer.resize(value);

		var ids = parent.parent.inputSystem.receptorIds;

		for (i in 0...value) {
			var rec = buffer[i];

			if (rec == null) {
				rec = new Note(x, y, 0, 0);
				rec.changeID(ids[i]);
				rec.reset();
				buffer[i] = rec;
			}
		}

		return length = value;
	}

	private var notesToHit(default, null):Array<Array<MetaNote>>;
	private var buffer(default, null):Array<Note>;

	var parent(default, null):NoteSystem;

	function new(x:Int, y:Int, gap:Int, scale:Float, length:Int, parent:NoteSystem) {
		notesToHit = [];
		buffer = [];

		this.parent = parent;

		this.length = length;
		this.x = x;
		this.y = y;
		this.scale = scale;
		this.gap = gap;
	}

	function draw(buf:Buffer<Note>) {
		for (i in 0...length) {
			buf.addElement(buffer[i]);
		}
	}

	function press(id:Int) {
		if (id >= length) return;
		if (id < 0) return;

		var rec = buffer[id];
		rec.press();
	}

	function release(id:Int) {
		if (id >= length) return;
		if (id < 0) return;

		var rec = buffer[id];
		rec.reset();
	}

	function hitRegister(n:MetaNote) {
		var grp = notesToHit[n.index];

		if (grp == null) {
			grp = notesToHit[n.index] = [];
		}

		grp.push(n);
	}

	function hitNotes(id:Int) {
		if (id >= length) return;
		if (id < 0) return;

		var grp = notesToHit[id];

		if (grp == null) {
			grp = notesToHit[id] = [];
		}

		while (grp.length != 0) {
			var noteToHit = grp.pop();
			//parent.hitNote(noteToHit);
		}

		var rec = buffer[id];
		rec.confirm();
	}

	function dispose() {
		if (notesToHit != null) {
			while (notesToHit.length != 0) {
				var grp = notesToHit.pop();
				grp.resize(0);
				grp = null;
			}
			notesToHit = null;
		}
		notesToHit.resize(0);
		buffer.resize(0);
	}
}