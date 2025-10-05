package structures.gameplay;

/**
	The note system.
	This is the main class that handles the notes and sustains in the game.
	It is responsible for spawning, drawing, and updating the notes and sustains.
	It also handles the note hit registration and sustain inputs.
	This class is used in the PlayField class to handle the notes and sustains.
	@since Development
**/
@:publicFields
class NoteSystem {
	static var sustainProg(default, null):Program;
	static var sustainsBuf(default, null):Buffer<Sustain>;

	static var notesProg(default, null):Program;
	static var notesBuf(default, null):Buffer<Note>;

	static var STRUMLINE_X_OFFSET = 50;
	static var STRUMLINE_Y_OFFSET = 50;
	static var STRUMLINE_Y_OFFSET_DOWNSCROLL = 150;

	static function init() {
		if (notesBuf == null) {
			notesBuf = new Buffer<Note>(128, 128, false);
		}

		if (notesProg == null) {
			var tex = TextureSystem.getTexture("noteTex");

			notesProg = new Program(notesBuf);
			Note.init(notesProg, "noteTex", tex);
		}

		if (sustainsBuf == null) {
			sustainsBuf = new Buffer<Sustain>(128, 128, false);
		}

		if (sustainProg == null) {
			var tex2 = TextureSystem.getTexture("sustainTex");

			sustainProg = new Program(sustainsBuf);
			Sustain.init(sustainProg, "sustainTex", tex2);
		}
	}

	var noteSpawner(default, null):NoteSpawner;
	var notePool(default, null):NotePool;
	var strumlines(default, null):Array<Strumline>;

	var noteTypeFunctionality(default, null):Map<Int, Int->Int->Bool->Void>;

	var parent(default, null):PlayField;

	/**
	 * Creates the note system.
	 * @param parent The parent of this class.
	**/
	function new(parent:PlayField) {
		noteTypeFunctionality = new Map<Int, Int->Int->Bool->Void>();

		this.parent = parent;

		var display = parent.display;

		display.addProgram(sustainProg);
		display.addProgram(notesProg);

		var inputSystem = parent.inputSystem;

		notePool = new NotePool(this);
		noteSpawner = new NoteSpawner(this);

		var mania = Chart.header.mania;

		strumlines = [];

		for (i in 0...2) {
			var strumline = new Strumline(STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5)),
				parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET, 
				Std.int(inputSystem.strumline[0]), inputSystem.strumline[1], mania, this);
			strumline.playable = parent.inputSystem.strumlinePlayable[i];
			strumlines.push(strumline);
		}

		setScrollSpeed(Chart.header.speed);

		update(_lastPos = MetaNote.floatToMetaNotePosition(parent.songPosition));
	}

	private var _lastPos(default, null):Int64; // for adaptive bot timer
	function update(pos:Int64) {
		notesBuf.clear();
		sustainsBuf.clear();

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			var botTimers = strumline.botTimers;
			for (j in 0...botTimers.length) {
				if (botTimers[j] > 0) {
					var decrement = pos - _lastPos;
					botTimers[j] -= MetaNote.metaNotePositionToSongTime(decrement) * 0.001;
					if (botTimers[j] <= 0 && strumline.botHitsToCheck[j]) {
						strumline.buffer[j].reset();
						botTimers[j] = 0;
						strumline.botHitsToCheck[j] = false; // reset the flag safely
					}
				}
			}
			strumline.draw(notesBuf);
		}

		if (noteSpawner != null) {
			noteSpawner.update(pos);
		}

		_lastPos = pos;
	}

	/**
	 * Again, do not fuck with this.
	 * I put lots of effort into this abomination of a function.
	 * This function was ported from the old note system.
	 * Note hitreg and sustain inputs are handled here.
	 * @param pos The song's position in note position format.
	 * @param note The meta note you want to draw the note to.
	 * @param id The index the note belongs to.
	**/
	function drawNote(pos:Int64, note:MetaNote, diff:Float, _id:Int64):Note {
		var index = note.index;
		var lane = 0;
		var duration = note.duration;
		var position = note.position;

		if (!noteTypeFunctionality.exists(note.type)) {
			lane = note.type % strumlines.length;
		} else {
			// Special note types get routed to lane 1 by convention.
			lane = 1;
		}

		var strumline = strumlines[lane];
		var rec = strumline.buffer[index];
		var id = parent.inputSystem.receptorIds[index];

		var noteSpr = notePool.newNote(id, note, _id);
		var sustainSpr = duration != 0 ? notePool.newSustain(id, note) : null;
		var sustainExists = duration != 0;

		var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));
		var isHit:Bool = note.flag;
		var isMissed:Bool = note.missed;
		var isHeld:Bool = note.held;

		if (parent.downScroll) diff = -diff;

		var noteSprX = rec.x;
		var noteSprY = rec.y + Std.int(diff);

		if (parent.downScroll) diff = -diff;

		noteSpr.x = noteSprX;
		noteSpr.y = noteSprY;
		noteSpr.scale = rec.scale;

		var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

		// --- Player side ---
		if (playable) {
			if (!isHit) {
				var noteToHit = strumline.notesToHit[index];
				var noteToHitExists = noteToHit != null;
				var hitPos = noteToHitExists ? noteToHit.position : 0;

				if ((!isMissed && diff < parent.hitbox && !noteToHitExists) ||
					(noteToHitExists && pos - hitPos > (position - hitPos) >> 1)) {
					strumline.notesToHit[index] = note;
					strumline.notesToHit_indexes[index] = _id;
				}

				if (diff < -parent.hitbox && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					var n = note;
					n.missed = isMissed = true;
					File.setNote(_id, n);

					var type = note.type;
					if (noteTypeFunctionality.exists(type)) {
						noteTypeFunctionality[type](index, type, true);
					}

					parent.onNoteMiss.dispatch(note, noteSpr.notesInOne);

					if (sustainExists && !isHeld) {
						sustainSpr.c.aF = Sustain.defaultMissAlpha;
						sustainSpr.c.luminanceF = Sustain.defaultMissAlpha;
						var n = note;
						n.held = isHeld = true;
						File.setNote(_id, n);
						parent.onSustainRelease.dispatch(note);
					}

					strumline.notesToHit[index] = null;
					strumline.notesToHit_indexes[index] = 0;

					var hud = parent.hud;
					if (SaveData.state.preferences.ratingPopup && hud != null) {
						hud.hideRatingPopup();
					}
				}
			}
		}

		// --- Opponent side ---
		else {
			// Handle opponent note hit (non-sustain)
			if (!isHit && diff < 0) {
				var n = note;
				n.flag = isHit = true;
				File.setNote(_id, n);
				//Sys.println('$_id ' + File.getNote(_id).flag);

				// Confirm the receptor
				if (!rec.confirmed()) rec.confirm();

				// Start glow timer for non-sustains
				strumline.botTimers[index] = 0.045;
				strumline.botHitsToCheck[index] = duration == 0;

				// Setup sustain visuals if needed
				if (sustainExists) {
					sustainSpr.followNote(rec);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				parent.onNoteHit.dispatch(note, 0, noteSpr.notesInOne);
			}
		}

		// --- Sustain handling ---
		if (sustainExists) {
			sustainSpr.changeID(id);
			sustainSpr.parent = noteSpr;
			sustainSpr.r = parent.downScroll ? -90 : 90;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;
			sustainSpr.length = (duration * 4) - 10;

			if (!isHit) {
				sustainSpr.w = sustainSpr.length;
				sustainSpr.followNote(noteSpr);
			} else if (sustainSpr.c.aF != 0) {
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (pos > position + (MetaNote.floatToMetaNotePosition(sustainSpr.length) - 70) && !isHeld) {
					var n = note;
					n.held = isHeld = true;
					File.setNote(_id, n);
					strumline.sustainsToHold[index] = null;
					strumline.sustainsToHold_indexes[index] = 0;
    				strumline.botHitsToCheck[index] = false; // only for short notes

					if (rec.confirmed()) {
						if (playable) rec.press();
						else rec.reset();
					}

					parent.onSustainComplete.dispatch(note);
				}
			}

			if (@:privateAccess sustainSpr.bytePos == -1)
				sustainsBuf.addElement(sustainSpr);
		}

		// --- Buffer note ---
		if (!isHit && @:privateAccess noteSpr.bytePos == -1)
			notesBuf.addElement(noteSpr);

		return noteSpr;
	}

	/**
	 * Change the scroll speed of this note system.
	**/
	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(300 / Math.min(Math.max(value, 0.0001), 1.0));
		parent.hitbox = 200 * value;
		return value;
	}

	/**
	 * Resets the strumlines of this note system.
	**/
	function resetStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims) strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

	/**
	 * Resets the strumlines of this note system.
	**/
	function resetPlayerStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			if (!strumline.playable) continue;
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims) strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

	/**
	 * Resets the notes in this note system.
	 * This is used when downscroll is enabled or when the player wants to reset the notes
	 */
	function resetNotes(songPosition:Float) {
		noteSpawner.resetNotes(songPosition);
	}

	/**
	 * Disposes the note system.
	**/
	function dispose() {
		if (strumlines != null) {
			while (strumlines.length != 0) {
				var strumline = strumlines.pop();
				strumline.dispose();
			}
	
			strumlines = null;
		}

		if (noteSpawner != null) {
			noteSpawner = null;
		}

		if (notePool != null) {
			notePool.dispose();
			notePool = null;
		}

		notesBuf.clear();
		sustainsBuf.clear();

		var display = parent.display;

		display.removeProgram(sustainProg);
		display.removeProgram(notesProg);
	}
}
