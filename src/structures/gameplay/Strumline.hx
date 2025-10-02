package structures.gameplay;

/**
	Strumline class for the note system.
	This class represents a line of notes in the game, which can be hit or held by the player.
	It manages the notes to hit, sustains to hold, and the buffer of notes.
	It also handles the drawing of the notes and the input handling for hitting and releasing notes.
	It is used in the NoteSystem class to manage the notes and sustains in the game.
	@since Development
**/
@:publicFields
class Strumline {
	var notesToHit(default, null):Array<Null<MetaNote>>;
	var sustainsToHold(default, null):Array<Null<MetaNote>>;
	var botHitsToCheck(default, null):Array<Bool>;
	var playerHitsToCheck(default, null):Array<Bool>;
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
		playerHitsToCheck.resize(value);
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
		playerHitsToCheck = [];
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

		if (noteToHit != null && !parent.notesMissed.get(noteToHit) && !parent.notesHit.get(noteToHit)) {
			var pf = parent.parent;
			//var spwn = parent.noteSpawner;
			var type = noteToHit.type;

			if (parent.noteTypeFunctionality.exists(type)) {
				parent.noteTypeFunctionality[type](index, type, false);
			}

			if (!rec.confirmed()) {
				rec.confirm();
			}

			parent.notesHit.set(noteToHit, true);

			if (noteToHit.duration > 20) {
				sustainsToHold[index] = noteToHit;
			}

			var posWithLatency = MetaNote.floatToMetaNotePosition(pf.songPosition + pf.latencyCompensation);
			pf.onNoteHit.dispatch(noteToHit, noteToHit.position - posWithLatency, 1);
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

		if (sustainToRelease != null && sustainToRelease.index == index &&
			(parent.notesHit.get(sustainToRelease) && !parent.notesHeld.get(sustainToRelease))) {
			var pf = parent.parent;

			parent.notesHeld.set(sustainToRelease, true);
			pf.onSustainRelease.dispatch(sustainToRelease);
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
		botHitsToCheck.resize(0);
		playerHitsToCheck.resize(0);
		notesToHit.resize(length);
		sustainsToHold.resize(length);
		botHitsToCheck.resize(length);
		playerHitsToCheck.resize(length);
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
