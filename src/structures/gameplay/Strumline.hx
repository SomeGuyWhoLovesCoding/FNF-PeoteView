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
	var notesToHit_sprites(default, null):Array<Note>;
	var notesToHit_indexes(default, null):Array<Int64>;
	var sustainsToHold(default, null):Array<Null<MetaNote>>;
	var sustainsToHold_indexes(default, null):Array<Int64>;
	var sustainsToHold_duration(default, null):Array<Int>;
	var botHitsToCheck(default, null):Array<Bool>;
	var playerHitsToCheck(default, null):Array<Bool>;
	var fakeOverlapStorage(default, null):Array<Int>; // This is for fake note overlapping!!! So it renders faster instead of just checking one by one without relying on an index based approach like this. Thanks - sgwl
	var botTimers(default, null):Array<Float>;
	var sustainsActive(default, null):Array<Bool>;
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
		sustainsToHold.resize(value);
		sustainsToHold_indexes.resize(value);
		sustainsToHold_duration.resize(value);
		sustainsActive.resize(value);
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

	var parent(default, null):NoteSystem;

	function new(x:Int, y:Int, gap:Int, scale:Float, length:Int, parent:NoteSystem) {
		notesToHit = [];
		notesToHit_sprites = [];
		notesToHit_indexes = [];
		sustainsToHold = [];
		sustainsToHold_duration = [];
		sustainsToHold_indexes = [];
		botHitsToCheck = [];
		playerHitsToCheck = [];
		fakeOverlapStorage = [];
		botTimers = [];
		sustainsActive = [];
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

		if (noteToHit != null && !noteToHit.missed && !noteToHit.flag) {
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
			(n:MetaNote).flag = true;
			File.setNote(notesToHit_indexes[index], n);
			sustainsToHold_duration[index] = noteToHit.duration;

			if (noteToHit.duration > 20) {
				sustainsToHold[index] = n; // `n` is modified so don't switch this to `noteToHit` since that variable was never modified
				sustainsToHold_indexes[index] = notesToHit_indexes[index];
			}

			var posWithLatency = MetaNote.floatToMetaNotePosition(pf.songPosition + (Main.conductor.offset * 2.0));
			// Now 0..1 instead of -250..250 just in case people don't know what the hitbox actually is
			// and it's flexible too considering you want different offsets for certain things yk?
			var _timing = MetaNote.metaNotePositionToSongTime(noteToHit.position - posWithLatency);
			var timing = ((_timing / parent._cachedHitbox) / pf.scrollSpeed) * 1.25;
			// this trace was there because I was constantly testing the new latency compensation system
			// specifically implemented inside the note system as I've had to even make an `onBeatHitUnoffsetted` event
			// just to 
			//Sys.println('${noteToHit.index},$_timing');

			if (@:privateAccess pf.onNoteHit.__listeners.length != 0)
				pf.onNoteHit.dispatch(noteToHit, timing, 1);
			if (pf.field != null)
				pf.field.hitNote(noteToHit, timing, 1);
			pf.hitNote(noteToHit, timing, 1);

			notesToHit[index] = null;

			notesToHit_indexes[index] = 0;
		} else {
			if (!rec.pressed()) {
				rec.press();
			}
		}
	}

	function release(index:Int) {
		var sustainToRelease = sustainsToHold[index];
		var rec = buffer[index];

		var sustainReleaseCallbackCanRun = sustainToRelease != null && sustainToRelease.index == index && (sustainToRelease.flag && !sustainToRelease.held);

		if (sustainReleaseCallbackCanRun) {
			var pf = parent.parent;

			var n:Int64 = sustainToRelease.toNumber();
			(n:MetaNote).held = true;
			File.setNote(sustainsToHold_indexes[index], n);

			if (@:privateAccess pf.onSustainRelease.__listeners.length != 0)
				pf.onSustainRelease.dispatch(sustainToRelease);
			if (pf.field != null)
				pf.field.releaseSustain(sustainToRelease);
			pf.releaseSustain(sustainToRelease);
			sustainsToHold[index] = null;
			sustainsToHold_indexes[index] = 0;
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
		sustainsToHold.resize(0);
		sustainsToHold_indexes.resize(0);
		sustainsToHold_duration.resize(0);
		botHitsToCheck.resize(0);
		playerHitsToCheck.resize(0);
		botTimers.resize(0);
		sustainsActive.resize(0);
		notesToHit.resize(length);
		notesToHit_indexes.resize(length);
		sustainsToHold.resize(length);
		sustainsToHold_indexes.resize(length);
		sustainsToHold_duration.resize(length);
		botHitsToCheck.resize(length);
		playerHitsToCheck.resize(length);
		botTimers.resize(length);
		sustainsActive.resize(length);
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
			while (notesToHit_indexes.pop() != null) {}
			notesToHit = null;
			notesToHit_indexes = null;
		}
		if (sustainsToHold != null) {
			while (sustainsToHold.pop() != null) {}
			while (sustainsToHold_indexes.pop() != null) {}
			while (sustainsToHold_duration.pop() != null) {}
			sustainsToHold = null;
			sustainsToHold_indexes = null;
			sustainsToHold_duration = null;
		}
	}
}
