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
			notesProg.discardAtAlpha(0.0);
		}

		if (sustainsBuf == null) {
			sustainsBuf = new Buffer<Sustain>(128, 128, false);
		}

		if (sustainProg == null) {
			var tex2 = TextureSystem.getTexture("sustainTex");

			sustainProg = new Program(sustainsBuf);
			Sustain.init(sustainProg, "sustainTex", tex2);
			sustainProg.discardAtAlpha(0.0);
		}
	}

	var noteSpawner(default, null):NoteSpawner;
	var notePool(default, null):NotePool;
	var strumlines(default, null):Array<Strumline>;

	var noteTypeFunctionalityPre(default, null):Map<Int, Int->Int->Bool->Void>;

	var parent(default, null):PlayField;

	/**
	 * Creates the note system.
	 * @param parent The parent of this class.
	**/
	function new(parent:PlayField) {
		noteTypeFunctionalityPre = new Map<Int, Int->Int->Bool->Void>();

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

		update(MetaNote.floatToMetaNotePosition(parent.songPosition));
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
	 * Resolves the note logic for this MetaNote.
	 * This mutates MetaNote flags (flag/missed/held), updates strumline state (notesToHit, botTimers, etc.)
	 * and dispatches events. It does NOT touch any sprite objects or GPU buffers.
	 *
	 * @param pos The calculated lane of this meta-note in the file (used for getting the current strumline).
	 * @param pos The song's position (meta-note position format).
	 * @param note The meta note to update.
	 * @param diff The computed diff (used for hit/miss checks).
	 * @param _id The index of this meta-note in the file (used for File.setNote).
	 * @param notesInOne Number of merged notes represented by this logical entry.
	 * @return The (possibly mutated) note.
	 **/
	function resolveNoteLogic(lane:Int, pos:Int64, note:MetaNote, diff:Float, _id:Int64, notesInOne:Int64):MetaNote {
		var index = note.index;
		var duration = note.duration;
		var position = note.position;

		var strumline = strumlines[lane];
		var rec = strumline.buffer[index];

		var sustainExists = duration != 0;

		// helper values
		var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));
		var isHit:Bool = note.flag;
		var isMissed:Bool = note.missed;
		var isHeld:Bool = note.held;

		var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

		// --- Player side (local player, hit registration) ---
		if (playable) {
			if (!isHit) {
				var noteToHit = strumline.notesToHit[index];
				var noteToHitExists = noteToHit != null;
				var hitPos = noteToHitExists ? noteToHit.position : 0;

				// register candidate to hit
				if ((!isMissed && diff < parent.hitbox && !noteToHitExists) ||
					(noteToHitExists && pos - hitPos > (position - hitPos) >> 1)) {
					strumline.notesToHit[index] = note;
					// store the file index that corresponds to this note so the input system can resolve it
					// we don't modify MetaNote here, but caller should pass _id if needed for input mapping
					strumline.notesToHit_indexes[index] = _id;
				}

				// miss handling (we mark missed once the note passed the hit window)
				if (diff < -parent.hitbox && !isMissed) {
					var n:Int64 = note.toNumber();
					(n:MetaNote).missed = true;
					isMissed = true;
					// if sustain, mark held and dispatch sustain release (mirror old behavior)
					if (sustainExists && !isHeld) {
						(n:MetaNote).held = true;
						isHeld = true;
						parent.onSustainRelease.dispatch(note);
					}
					File.setNote(_id, n);

					// custom note type callback
					var type = note.type;
					if (noteTypeFunctionalityPre.exists(type)) {
						noteTypeFunctionalityPre[type](index, type, true);
					}

					// dispatch miss with merged count
					parent.onNoteMiss.dispatch(note, notesInOne);

					// clear any queued to-hit state
					strumline.notesToHit[index] = null;
					strumline.notesToHit_indexes[index] = 0;
				}
			}
		}
		// --- Opponent / bot side ---
		else {
			// If opponent hasn't flagged and the note passed center, mark it hit
			if (!isHit && diff <= 0) {
				var n:Int64 = note.toNumber();
				(n:MetaNote).flag = true;
				isHit = true;
				File.setNote(_id, n);

				// Confirm the receptor for visual/sound feedback
				if (!rec.confirmed()) rec.confirm();

				// Start glow timer for non-sustains
				strumline.botTimers[index] = 0.045;
				strumline.botHitsToCheck[index] = duration == 0;

				// dispatch hit (notesInOne used by caller)
				parent.onNoteHit.dispatch(note, 0, notesInOne);
			}
		}

		// --- Sustain completion (server-side logic only; no sustain sprite touched here) ---
		if (sustainExists) {
			var sustainLengthPos = MetaNote.floatToMetaNotePosition((duration * 4) - 10); // position length used for time compare
			// if the note was hit and we've passed the sustain end threshold and it isn't held yet, mark held
			if (isHit && pos > position + (sustainLengthPos - 70) && !isHeld) {
				var n3:Int64 = note.toNumber();
				(n3:MetaNote).held = true;
				isHeld = true;
				File.setNote(_id, n3);

				// Reeset the receptor for sustain release feedback
				if (!rec.idle()) rec.reset();

				strumline.sustainsToHold[index] = null;
				strumline.sustainsToHold_indexes[index] = 0;
				strumline.botHitsToCheck[index] = false;

				parent.onSustainComplete.dispatch(note);
			}
		}

		// return mutated note
		return note;
	}

	/**
	 * Again, do not fuck with this.
	 * I put lots of effort into this abomination of a function.
	 * This function was ported from the old note system.
	 * Note hitreg and sustain inputs are handled here.
	 * This was a mixed note logic and rendering function.
	 * @param pos The song's position in note position format.
	 * @param note The meta note you want to draw the note to.
	 * @param id The index the note belongs to.
	 * @param x The horizontal position of the note.
	 * @param y The vertical position of the note.
	 * @param notesInOne The amount of notes grouped together to one.
	 * @param addedAlpha The added alpha of a note in total. Mimics what the real deal would look liked.
	**/
	function drawNote(
		pos:Int64,
		note:MetaNote,
		diff:Float,
		_id:Int64,
		x:Int,
		y:Int,
		notesInOne:Int64,
		addedAlpha:Float
	):Note {
		var index = note.index;
		var lane = 0;
		var duration = note.duration;
		var position = note.position;

		if (!noteTypeFunctionalityPre.exists(note.type)) {
			lane = note.type % strumlines.length;
		} else {
			// Special note types get routed to lane 1 by convention.
			lane = 1;
		}

		var strumline = strumlines[lane];
		var rec = strumline.buffer[index];
		var id = parent.inputSystem.receptorIds[index];

		var noteSpr = notePool.getNote(id, note, _id);
		var sustainExists = duration != 0;
		var sustainSpr = sustainExists ? notePool.getSustain(id, note) : null;

		var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));
		var isHit:Bool = note.flag;
		var isMissed:Bool = note.missed;

		// --- Note sprite visual setup ---
		noteSpr.x = x;
		noteSpr.y = y;
		noteSpr.scale = rec.scale;
		noteSpr.notesInOne = notesInOne;
		var addedAlphaI64 = notesInOne;
		if (addedAlphaI64 > 255) addedAlphaI64 = 255;
		noteSpr.addedAlpha = Tools.int64ToFloat(addedAlphaI64) + addedAlpha;

		// --- Sustain sprite visual setup ---
		if (sustainExists) {
			sustainSpr.changeID(id);
			sustainSpr.parent = noteSpr;
			sustainSpr.r = parent.downScroll ? -90 : 90;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;
			sustainSpr.length = (duration * 4) - 10;

			if (!isHit) {
				// Full sustain before hit
				sustainSpr.w = sustainSpr.length;
				sustainSpr.followNote(noteSpr);
			} else if (sustainSpr.c.aF != 0) {
				// Shorten sustain after hit
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}
			}

			if (@:privateAccess sustainSpr.bytePos == -1)
				sustainsBuf.addElement(sustainSpr);
		}

		// --- Buffer note sprite ---
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
