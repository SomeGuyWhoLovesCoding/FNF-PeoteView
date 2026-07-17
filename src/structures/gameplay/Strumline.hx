package structures.gameplay;

import lime.system.System;

/**
 * The home of inputs, whether you own it or not.
 * @since Development
**/
@:publicFields
class Strumline {
	var receptors(default, null):Array<Receptor>;

	var x(default, set):Int;
	var y(default, set):Int;
	var offsetX(default, set):Int;
	var offsetY(default, set):Int;
	var scale(default, set):Float;
	var gap(default, set):Int;
	var length(default, set):Int;
	var playable:Bool;
	var noteskinHandle(default, set):NoteskinHandle;

	function set_x(value:Int) {
		for (i in 0...length) {
			receptors[i].note.x = value + Math.floor(gap * i) + offsetX;
		}
		return x = value;
	}

	function set_y(value:Int) {
		if (value != y) {
			for (i in 0...length) {
				receptors[i].note.y = value + offsetY;
			}
		}
		return y = value;
	}

	inline function set_offsetX(value:Int) {
		offsetX = value;
		set_x(x);
		return value;
	}

	inline function set_offsetY(value:Int) {
		offsetY = value;
		set_y(y);
		return value;
	}

	inline function set_noteskinHandle(handle:NoteskinHandle) {
		noteskinHandle = handle;

		for (i in 0...length) {
			var receptor = receptors[i];
			receptor.note.handle = handle;
			receptor.note.changeID(i);
			receptor.note.reset();
		}

		return handle;
	}

	function set_scale(value:Float) {
		if (value != scale) {
			for (i in 0...length) {
				receptors[i].note.scale = value;
			}
		}
		return scale = value;
	}

	inline function set_gap(value:Int) {
		gap = value;
		set_x(x);
		return value;
	}

	function set_length(value:Int) {
		receptors.resize(value);

		for (i in 0...value) {
			var rec = receptors[i];
			if (rec == null) {
				var note = new Note(x, y, 0, 0, noteskinHandle);
				note.changeID(i);
				note.reset();
				receptors[i] = new Receptor(note);
			}
		}

		return length = value;
	}

	public var scrollDirection:Int = -90;

	var parent(default, null):NoteSystem;

	function new(x:Int, y:Int, noteskinHandle:NoteskinHandle, gap:Int, scale:Float, length:Int, parent:NoteSystem) {
		receptors = [];

		this.parent = parent;

		this.length = length;
		this.x = x;
		this.y = y;
		this.scale = scale;
		this.gap = gap;
		this.noteskinHandle = noteskinHandle;
	}

	function applyNoteskinProperties(handle:NoteskinHandle, mania:Int) {
		var cfgM = handle.data.configMania[mania];
		this.offsetX = cfgM.offsetX;
		this.offsetY = cfgM.offsetY;
		this.gap = cfgM.gap;
		this.length = mania;
	}

	function draw(buf:Buffer<Note>) {
		for (i in 0...length) {
			buf.addElement(receptors[i].note);
		}
	}

	function press(index:Int) {
		var rec = receptors[index];
		var noteToHit = rec.noteToHit;
		var note = rec.note;
		var noteIndex = rec.noteToHit_index;

		if (noteToHit != null && !File.getJudgement(noteIndex)) {
			var pf = parent.parent;
			var type = noteToHit.type;

			var noteTypeCall:Int->Int->Bool->Void = parent.noteTypeFunctionalityPre[type];
			var noteTypeCallExists = noteTypeCall != null;

			if (noteTypeCallExists) {
				noteTypeCall(index, type, false);
			}

			if (!note.confirmed()) {
				note.confirm();
			}

			var sprite = rec.noteToHit_sprite;
			if (sprite != null) {
				sprite.initialAlpha = 0;
				if (@:privateAccess sprite.bytePos != -1)
					NoteSystem.notesBuf.updateElement(sprite);
				rec.noteToHit_sprite = null;
			}

			// mark as hit: missed=false, then set judgement
			File.setHitFlag(noteIndex, false);
			File.setJudgement(noteIndex, true);

			rec.sustainToHold_duration = noteToHit.duration;
			rec.sustainResolved = false;

			if (noteToHit.duration > 20) {
				rec.sustainResolved = false;
				rec.sustainToHold = noteToHit;
				rec.sustainToHold_index = noteIndex;
			}

			var posWithLatency = MetaNote.floatToMetaNotePosition(pf.songPosition + Main.conductor.offset);
			var _timing = MetaNote.metaNotePositionToSongTime(noteToHit.position - posWithLatency);
			var timing = (_timing / parent._cachedHitbox) * 0.9;

			if (@:privateAccess pf.onNoteHit.__listeners.length != 0)
				pf.onNoteHit.dispatch(noteToHit, timing, 1);
			if (pf.field != null)
				pf.field.hitNote(noteToHit, timing, 1);
			pf.hitNote(noteToHit, timing, 1, noteIndex);

			rec.noteToHit = null;
			rec.noteToHit_index = 0;
		} else {
			if (!note.pressed()) {
				note.press();
			}
		}
	}

	function release(index:Int) {
		var rec = receptors[index];
		var sustainToRelease = rec.sustainToHold;
		var note = rec.note;
		var sustainIndex = rec.sustainToHold_index;

		// Sustain release fires if: note exists, correct lane, was hit, and not yet resolved
		var hitflag = File.getHitFlag(sustainIndex);
		var sustainReleaseCallbackCanRun = sustainToRelease != null
			&& sustainToRelease.index == index
			&& File.getJudgement(sustainIndex)
			&& !hitflag
			&& !rec.sustainResolved;

		if (sustainReleaseCallbackCanRun) {
			var pf = parent.parent;

			rec.sustainResolved = true;

			if (@:privateAccess pf.onSustainRelease.__listeners.length != 0)
				pf.onSustainRelease.dispatch(sustainToRelease);
			if (pf.field != null)
				pf.field.releaseSustain(sustainToRelease);
			pf.releaseSustain(sustainToRelease, sustainIndex);

			rec.sustainToHold = null;
			rec.sustainToHold_index = 0;
			rec.sustainToHold_duration = 0;

			var hud = pf.hud;
			if (SaveData.state.preferences.ratingPopup && hud != null) {
				hud.hideRatingPopup();
			}
		}

		if (!note.idle()) {
			note.reset();
		}
	}

	inline function confirmed(index:Int) {
		return receptors[index].note.confirmed();
	}

	function resetInputs() {
		for (i in 0...length) {
            var rec = receptors[i];
            if (rec != null) {
                rec.resetState();
            }
        }
	}

	function resetAnimations() {
		for (i in 0...length) {
			var rec = receptors[i];
			rec.note.reset();
		}
		try {
			NoteSystem.notesBuf.update();
		} catch (e) {}
	}

	function dispose() {
		if (receptors != null) {
			while (receptors.length > 0) {
				var rec = receptors.pop();
				if (rec != null) {
					rec.note = null;
					rec.noteToHit = null;
					rec.noteToHit_sprite = null;
					rec.sustainToHold = null;
				}
			}
			receptors = null;
		}
	}
}