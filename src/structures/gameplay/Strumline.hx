package structures.gameplay;

import lime.system.System;
import lime.ui.KeyCode;

/**
 * The home of inputs, whether you own it or not.
 * @since Development
**/
@:publicFields
class Strumline {
	var receptors(default, null):Array<Receptor>;

	var fakeReceptorMap(default, null):Array<MetaNote>;

	var x(default, set):Int;
	var y(default, set):Int;
	var offsetX(default, set):Int;
	var offsetY(default, set):Int;
	var scale(default, set):Float;
	var gap(default, set):Int;
	var length(default, set):Int;
	var noteskinHandle(default, set):NoteskinHandle;

	// input system keybind rework to be based off the current strumline
	var playable(default, set):Bool;

	function set_playable(value:Bool) {
		playable = value;
		updateKeybinds();
		return value;
	}

	var keybinds:Array<KeyCode> = [];
	var keybindsTwo:Array<KeyCode> = [];

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
		var scale = this.scale; // use current scale

		for (i in 0...length) {
			var receptor = receptors[i];
			receptor.note.handle = handle;
			receptor.note.mania_for_clipruntimehelper = length;
			receptor.note.changeID(i);
			receptor.note.reset();
		}
		calculateSustainPivot();

		return handle;
	}

	function set_scale(value:Float) {
		if (value != scale) {
			for (i in 0...length) {
				var receptor = receptors[i];
				receptor.note.scale = value;
				receptor.note.mania_for_clipruntimehelper = length;
			}
		}
		updateKeybinds();
		calculateSustainPivot();
		return scale = value;
	}

	inline function set_gap(value:Int) {
		gap = value;
		set_x(x);
		return value;
	}

	function set_length(value:Int) {
		receptors.resize(value);
		fakeReceptorMap.resize(value);

		for (i in 0...value) {
			var rec = receptors[i];
			if (rec == null) {
				var note = new Note(x, y, 0, 0, noteskinHandle);
				note.changeID(i);
				note.reset();
				receptors[i] = new Receptor(note);
			}
		}
		updateKeybinds();
		calculateSustainPivot();

		return length = value;
	}

	public var scrollDirection:Int = -90;

	var parent(default, null):NoteSystem;

	function new(x:Int, y:Int, noteskinHandle:NoteskinHandle, gap:Int, scale:Float, length:Int, parent:NoteSystem) {
		receptors = [];
		fakeReceptorMap = [];

		this.parent = parent;

		this.length = length;
		this.noteskinHandle = noteskinHandle;
		this.scale = scale;
		this.x = x;
		this.y = y;
		this.gap = gap;

		calculateSustainPivot();
	}

	function calculateSustainPivot() {
		for (i in 0...length) {
			var receptor = receptors[i];
			var idleClip = NoteskinRuntimeHelper.getIdleClip(noteskinHandle, i, length);
			receptor.sustainPivotX = Math.round(idleClip.clipW * scale * 0.5);
			receptor.sustainPivotY = Math.round(idleClip.clipH * scale * 0.5);
		}
	}

	function updateKeybinds() {
		if (!playable) {
			keybinds.resize(0);
			keybindsTwo.resize(0);
			return;
		}

		keybinds.resize(length);
		keybindsTwo.resize(length);

		for (i in 0...length) {
			var keybindArray = SaveData.state.controls.game.keybindArray;
			var bind = keybindArray[length - 1];
			if (bind == null)
				return;
			var len = bind.length;
			var keybind = bind[i];
			// trace('On index $i on length $length');
			keybinds[i] = i < len ? keybind[0] : -1;
			if (keybind.length == 2)
				keybindsTwo[i] = i < len ? keybind[1] : -1;
		}
	}

	inline function getPrevNote(index:Int):MetaNote {
		return fakeReceptorMap[index];
	}

	inline function setPrevNote(index:Int, note:MetaNote):Void {
		fakeReceptorMap[index] = note;
	}

	function applyNoteskinProperties(handle:NoteskinHandle, mania:Int) {
		if (handle == null)
			return;
		var cfgs = handle.data.configMania;
		if (cfgs == null || cfgs.length == 0)
			return;
		// A skin may not ship a config for every mania. Clamp the config lookup
		// to the nearest available one so high-mania charts don't null-deref.
		var cfgIndex = mania;
		if (cfgIndex < 0 || cfgIndex >= cfgs.length)
			cfgIndex = cfgs.length - 1;
		var cfgM = cfgs[cfgIndex];
		this.offsetX = cfgM.offsetX;
		this.offsetY = cfgM.offsetY;
		this.gap = cfgM.gap;
		this.scale = cfgM.scale;
		this.length = mania + 1;
		this.noteskinHandle = handle;
	}

	function draw(buf:Buffer<Note>) {
		for (i in 0...length) {
			buf.addElement(receptors[i].note);
		}
	}

	function press(index:Int) {
		var rec = receptors[index];
		var note = rec.note;

		// No per-frame arming pre-pass; find the hit candidate at press time.
		var noteIndex = parent.findPlayerHitNote(this, index);
		var noteToHit = noteIndex >= 0 ? File.getNote(noteIndex) : null;

		if (noteToHit != null) {
			var pf = parent.parent;

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
		var sustainReleaseCallbackCanRun = sustainToRelease != null && sustainToRelease.index == index && File.getJudgement(sustainIndex) && !hitflag
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
