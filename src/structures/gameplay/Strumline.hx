package structures.gameplay;

/**
	Strumline class for the note system.
**/
@:publicFields
class Strumline {
	var notesToHit(default, null):Array<Note>;
	var sustainsToHold(default, null):Array<Sustain>;
	var botHitsToCheck(default, null):Array<Bool>;
	var buffer(default, null):Array<Note>;

	var x(default, set):Int;
	var y(default, set):Int;
	var scale(default, set):Float;
	var gap(default, set):Int;
	var length(default, set):Int;
	var playable:Bool;

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
		sustainsToHold.resize(value);
		botHitsToCheck.resize(value);
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

	var parent(default, null):NoteSystem;

	function new(x:Int, y:Int, gap:Int, scale:Float, length:Int, parent:NoteSystem) {
		notesToHit = [];
		sustainsToHold = [];
		botHitsToCheck = [];
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

	function press(index:Int) {
		var noteToHit = notesToHit[index];
		var rec = buffer[index];

		if (noteToHit != null && !noteToHit.missed && !noteToHit.hit) {
			var pf = parent.parent;

			if (!rec.confirmed()) {
				rec.confirm();
			}

			noteToHit.hit = true;
			sustainsToHold[index] = noteToHit.child;

			var data = noteToHit.data;
			var posWithLatency = Tools.betterInt64FromFloat((pf.songPosition + pf.latencyCompensation) * 100);
			pf.onNoteHit.dispatch(data, Int64.toInt(Int64.div(data.position - posWithLatency, 100)));
			notesToHit[index] = null;
		} else {
			if (!rec.pressed()) {
				rec.press();
			}
		}
	}

	function release(index:Int) {
		var sustainToRelease = sustainsToHold[index];
		var rec = buffer[index];

		if (sustainToRelease != null && (sustainToRelease.c.aF != 0 && sustainToRelease.w > 100)) {
			var pf = parent.parent;

			sustainToRelease.c.aF = Sustain.defaultMissAlpha;
			sustainToRelease.held = true;
			pf.onSustainRelease.dispatch(sustainToRelease.parent.data);
			sustainsToHold[index] = null;

			var hud = pf.hud;
			if (SaveData.state.preferences.ratingPopup && hud != null) {
				hud.hideRatingPopup();
			}
		}

		if (!rec.idle()) {
			rec.reset();
		}
	}

	inline function confirmed(index:Int) {
		return buffer[index].confirmed();
	}

	function resetInputs() {
		notesToHit.resize(0);
		sustainsToHold.resize(0);
		notesToHit.resize(length);
		sustainsToHold.resize(length);
	}

	function resetAnimations() {
		for (i in 0...length) {
			var rec = buffer[i];
			rec.reset();
			try {
				NoteSystem.notesBuf.updateElement(rec);
			} catch (e) {}
		}
	}

	function dispose() {
		if (notesToHit != null) {
			while (notesToHit.pop() != null) {}
			notesToHit = null;
		}
		if (sustainsToHold != null) {
			while (sustainsToHold.pop() != null) {}
			sustainsToHold = null;
		}
	}
}
