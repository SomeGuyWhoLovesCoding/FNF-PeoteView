package structures.gameplay;

import lime.system.System;

#if (FV_LIME_FORK && lime_cffi)
import lime._internal.backend.native.NativeCFFI;
@:access(lime._internal.backend.native.NativeCFFI)
#end
@:publicFields
class Strumline {
	var notesToHit(default, null):Array<Null<MetaNote>>;
	var notesToHit_sprites(default, null):Array<Note>;
	var notesToHit_indexes(default, null):Array<Int64>;
	var getTimeCorrection(default, null):Array<Int64>;

	var sustainsToHold(default, null):Array<Null<MetaNote>>;
	var sustainsToHold_indexes(default, null):Array<Int64>;
	var sustainsToHold_duration(default, null):Array<Int>;
	var botHitsToCheck(default, null):Array<Bool>;
	var playerHitsToCheck(default, null):Array<Bool>;
	var fakeOverlapStorage(default, null):Array<Int>;

	var botTimers(default, null):Array<Float>;
	var sustainsActive(default, null):Array<Bool>;
	// Replaces the held bit — tracks whether a sustain has been resolved (completed or released early)
	var sustainsResolved(default, null):Array<Bool>;
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
		if (value != y) {
			for (i in 0...length) {
				buffer[i].y = value;
			}
		}
		return y = value;
	}

	function set_scale(value:Float) {
		if (value != scale) {
			for (i in 0...length) {
				buffer[i].scale = value;
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
		notesToHit.resize(value);
		notesToHit_sprites.resize(value);
		notesToHit_indexes.resize(value);
		getTimeCorrection.resize(value);
		sustainsToHold.resize(value);
		sustainsToHold_indexes.resize(value);
		sustainsToHold_duration.resize(value);
		sustainsActive.resize(value);
		sustainsResolved.resize(value);
		botHitsToCheck.resize(value);
		playerHitsToCheck.resize(value);
		fakeOverlapStorage.resize(value);
		botTimers.resize(value);
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

	public var scrollDirection:Int = -90;

	var parent(default, null):NoteSystem;

	function new(x:Int, y:Int, gap:Int, scale:Float, length:Int, parent:NoteSystem) {
		notesToHit = [];
		notesToHit_sprites = [];
		notesToHit_indexes = [];
		getTimeCorrection = [];
		sustainsToHold = [];
		sustainsToHold_duration = [];
		sustainsToHold_indexes = [];
		botHitsToCheck = [];
		playerHitsToCheck = [];
		fakeOverlapStorage = [];
		botTimers = [];
		sustainsActive = [];
		sustainsResolved = [];
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

	function press(index:Int #if FV_LIME_FORK , timestamp:Float #end) {
		var noteToHit = notesToHit[index];
		var rec = buffer[index];
		var noteIndex = notesToHit_indexes[index];

		if (noteToHit != null && !File.getJudgement(noteIndex)) {
			var pf = parent.parent;
			var type = noteToHit.type;

			var noteTypeCall:Int->Int->Bool->Void = parent.noteTypeFunctionalityPre[type];
			var noteTypeCallExists = noteTypeCall != null;

			if (noteTypeCallExists) {
				noteTypeCall(index, type, false);
			}

			if (!rec.confirmed()) {
				rec.confirm();
			}

			var sprite = notesToHit_sprites[index];
			if (sprite != null) {
				sprite.initialAlpha = 0;
				if (@:privateAccess sprite.bytePos != -1)
					NoteSystem.notesBuf.updateElement(sprite);
				notesToHit_sprites[index] = null;
			}

			var n:Int64 = noteToHit.toNumber();
			// mark as hit: missed=false, then set judgement
			(n:MetaNote).flag = false;
			File.setNote(noteIndex, n);
			File.setJudgement(noteIndex, true);

			sustainsToHold_duration[index] = noteToHit.duration;
			sustainsResolved[index] = false;

			if (noteToHit.duration > 20) {
				sustainsToHold[index] = n;
				sustainsToHold_indexes[index] = noteIndex;
			}

			var posWithLatency = MetaNote.floatToMetaNotePosition(pf.songPosition + (Main.conductor.offset * 2.0));
			var _timing = MetaNote.metaNotePositionToSongTime((noteToHit.position + File.getTimeCorrectionForIndex(noteIndex)) - posWithLatency);
			#if (FV_LIME_FORK && lime_cffi)
			var _timingCompare:Float = @:privateAccess NativeCFFI.lime_asynckey_timestamp();
			var _timingDiffSubtract = timestamp - _timingCompare;
			_timing += _timingDiffSubtract;
			//Sys.println('$_timingCompare,$timestamp');
			//trace('timing: $_timing | timestamp: $timestamp | posWithLatency: $posWithLatency | timingCompare: $_timingCompare | timingDiffSubtract: $_timingDiffSubtract');
			//Sys.println('note timing:$_timing, note index:$index');
			#end
			var timing = (_timing / parent._cachedHitbox) * 0.9;

			if (@:privateAccess pf.onNoteHit.__listeners.length != 0)
				pf.onNoteHit.dispatch(noteToHit, timing, 1);
			if (pf.field != null)
				pf.field.hitNote(noteToHit, timing, 1);
			pf.hitNote(noteToHit, timing, 1, noteIndex);

			notesToHit[index] = null;
			notesToHit_indexes[index] = noteIndex = 0;
		} else {
			if (!rec.pressed()) {
				rec.press();
			}
		}
	}

	function release(index:Int) {
		var sustainToRelease = sustainsToHold[index];
		var rec = buffer[index];
		var sustainIndex = sustainsToHold_indexes[index];

		// Sustain release fires if: note exists, correct lane, was hit, and not yet resolved
		var sustainReleaseCallbackCanRun = sustainToRelease != null
			&& sustainToRelease.index == index
			&& File.getJudgement(sustainIndex)
			&& !sustainToRelease.flag
			&& !sustainsResolved[index];

		if (sustainReleaseCallbackCanRun) {
			var pf = parent.parent;

			sustainsResolved[index] = true;

			if (@:privateAccess pf.onSustainRelease.__listeners.length != 0)
				pf.onSustainRelease.dispatch(sustainToRelease);
			if (pf.field != null)
				pf.field.releaseSustain(sustainToRelease);
			pf.releaseSustain(sustainToRelease, sustainIndex);

			sustainsToHold[index] = null;
			sustainsToHold_indexes[index] = sustainIndex = 0;
			sustainsToHold_duration[index] = 0;

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
		notesToHit_indexes.resize(0);
		getTimeCorrection.resize(0);
		sustainsToHold.resize(0);
		sustainsToHold_indexes.resize(0);
		sustainsToHold_duration.resize(0);
		botHitsToCheck.resize(0);
		playerHitsToCheck.resize(0);
		botTimers.resize(0);
		sustainsActive.resize(0);
		sustainsResolved.resize(0);
		notesToHit.resize(length);
		notesToHit_indexes.resize(length);
		getTimeCorrection.resize(length);
		sustainsToHold.resize(length);
		sustainsToHold_indexes.resize(length);
		sustainsToHold_duration.resize(length);
		botHitsToCheck.resize(length);
		playerHitsToCheck.resize(length);
		botTimers.resize(length);
		sustainsActive.resize(length);
		sustainsResolved.resize(length);
	}

	function resetAnimations() {
		for (i in 0...length) {
			var rec = buffer[i];
			rec.reset();
		}
		try {
			NoteSystem.notesBuf.update();
		} catch (e) {}
	}

	function dispose() {
		if (notesToHit != null) {
			while (notesToHit.pop() != null) {}
			while (notesToHit_indexes.pop() != null) {}
			while (getTimeCorrection.pop() != null) {}
			notesToHit = null;
			notesToHit_indexes = null;
			getTimeCorrection = null;
		}
		if (sustainsToHold != null) {
			while (sustainsToHold.pop() != null) {}
			while (sustainsToHold_indexes.pop() != null) {}
			while (sustainsToHold_duration.pop() != null) {}
			sustainsToHold = null;
			sustainsToHold_indexes = null;
			sustainsToHold_duration = null;
		}
		if (sustainsResolved != null) {
			sustainsResolved.resize(0);
			sustainsResolved = null;
		}
	}
}