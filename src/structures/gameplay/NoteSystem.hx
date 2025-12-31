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

	var strumlines(default, null):Array<Strumline>;
	var noteSpawner(default, null):NoteSpawner;
	var notePool(default, null):NotePool;
	var virtualNoteBuffers(default, null):Array<NoteVB>;

	var noteTypeFunctionalityPre(default, null):Array<Int->Int->Bool->Void>;

	var parent(default, null):PlayField;

	/**
	 * Creates the note system.
	 * @param parent The parent of this class.
	**/
	function new(parent:PlayField) {
		noteTypeFunctionalityPre = [];
		noteTypeFunctionalityPre.resize(1 << 5); // Max 5 bit value

		this.parent = parent;

		var display = parent.display;

		display.addProgram(sustainProg);
		display.addProgram(notesProg);

		var inputSystem = parent.inputSystem;

		notePool = new NotePool(this);
		noteSpawner = new NoteSpawner(this);

		var mania = Chart.header.mania;

		strumlines = [];

		for (i in 0...2) { // how many strumlines you'll use throughout the entire song, only. Not dynamic because I'm lazy to do any overcomplication and I want to keep it pretty simple.
			var strumline = new Strumline(STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5)),
				parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET,
				Std.int(inputSystem.strumline[0]), inputSystem.strumline[1], mania, this);
			strumline.playable = parent.inputSystem.strumlinePlayable[i];
			strumlines.push(strumline);
		}

		virtualNoteBuffers = [];
		for (i in 0...4) 
			virtualNoteBuffers[i] = new NoteVB(strumlines.length, strumlines[0].buffer.length);

		setScrollSpeed(Chart.header.speed);

		update(MetaNote.floatToMetaNotePosition(parent.songPosition));
	}

	/**
	 * This processes the virtual notes in real time.
	 * @param pos The song's position in the note position format.
	**/
	function update(pos:Int64) {
		if (_lastPos == 0) _lastPos = pos; // initialize safely

		// if position jumped too far (pause or seek), resync
		var delta = pos - _lastPos;
		if (delta < 0 || MetaNote.metaNotePositionToSongTime(delta) > 200)
			_lastPos = pos;

		for (virtualNoteBuffer in virtualNoteBuffers)
			virtualNoteBuffer.clear();

		if (noteSpawner != null)
			noteSpawner.update(pos);
	}

	private var _lastPos(default, null):Int64; // for adaptive bot timer

	/**
	 * Call this when pausing, seeking, or any time the song position jumps.
	 * This ensures bot timers are properly synchronized.
	**/
	function onSongPositionJump(pos:Int64) {
		_lastPos = pos;
		resetStrumlines(); // force reset them
	}

	// Modified refreshRendering to handle timer decrements more safely:
	// very shotty attempt at resetting receptors once one has an idle still sticking around after a note or sustain hit
	private function refreshRendering(pos:Int64) {
		// Clear note & sustain buffers to refresh for new window
		notesBuf.clear();
		sustainsBuf.clear();

		// Calculate time delta - clamp to prevent issues from pausing/seeking
		var delta = pos - _lastPos;
		if (delta < 0) delta = -delta;
		var timeDelta = MetaNote.metaNotePositionToSongTime(delta) * 0.001;
		//Sys.println('Strumline renderer time delta: $timeDelta');
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			var botTimers = strumline.botTimers;
			var canMess = !strumline.playable || RenderingMode.enabled || parent.botplay;
			for (j in 0...botTimers.length) {
				var rec = strumline.buffer[j];
				if (parent.botplay) canMess = true;
				if (canMess) {
					if (!strumline.sustainsActive[j]) {
						if (strumline.botTimers[j] < 0 && !strumline.sustainsActive[j]) {
							rec.reset();
							strumline.botTimers[j] = 0;
						}
						strumline.botTimers[j] -= timeDelta;
					}
				}
			}
			strumline.draw(notesBuf);
		}

		_lastPos = pos;
	}

	/**
	 * Renders the note system.
	 * @param pos The song's position in the note position format.
	**/
	function renderNotes(pos:Int64) {
		refreshRendering(pos);

		// Render notes in current window
		noteSpawner.renderNotes(pos);
	}

	/**
	 * Again, do not fuck with this.
	 * I put lots of effort into this abomination of a function.
	 * This function was ported from the old note system.
	 * Note hitreg and sustain inputs are handled here.
	 * @param pos The song's position in note position format.
	 * @param note The meta note you want to draw the note to.
	 * @param id The index the note belongs to.
	 * @returns The virtual note that was successfully drawn.
	**/
	function drawNote(pos:Int64, note:MetaNote, diff:Float, _id:Int64, THREAD_ID:Int = 0):VirtualNote {
		var index = note.index;
		var lane = 0;
		var duration = note.duration;
		var position = note.position;

		var noteTypeCall:Int->Int->Bool->Void = noteTypeFunctionalityPre[note.type];
		var noteTypeCallExists = noteTypeCall != null;

		if (!noteTypeCallExists) {
			lane = note.type % strumlines.length;
		} else {
			// Special note types get routed to lane 1 by convention.
			lane = 1;
		}

		var strumline = strumlines[lane];
		var rec = strumline.buffer[index];
		var id = parent.inputSystem.receptorIds[index];

		var noteSpr = notePool.getNote(id, note, _id);
		if (noteSpr == null) return noteSpr;
		var sustainSpr = duration != 0 ? notePool.getSustain(id, note) : null;
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
		noteSpr.ref = note;

		var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

		var latency = Main.conductor.offset;

		// --- Player side ---
		if (playable) {
			if (!isHit) {
				var noteToHit = strumline.notesToHit[index];
				var noteToHitExists = noteToHit != null;
				var diffOffsetted = diff + latency; // This is important

				if (!isMissed && diffOffsetted < _cachedHitbox) {
					var pos = MetaNote.metaNotePositionToSongTime(noteToHit.position - pos);
					if (!noteToHitExists || Math.abs(diff) < Math.abs(pos)) {
						strumline.notesToHit[index] = note;
						strumline.notesToHit_indexes[index] = _id;
					}
				}

				if (diffOffsetted < -_cachedHitbox && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					var n:Int64 = note.toNumber();
					(n:MetaNote).missed = true;
					isMissed = true;

					var type = note.type;
					if (noteTypeCallExists) {
						noteTypeCall(index, type, true);
					}

					if (@:privateAccess parent.onNoteMiss.__listeners.length != 0)
						parent.onNoteMiss.dispatch(note, noteSpr.notesInOne);
					if (parent.field != null)
						parent.field.missNote(note, noteSpr.notesInOne);
					parent.missNote(note, noteSpr.notesInOne);

					if (sustainExists && !isHeld) {
						sustainSpr.alpha = Sustain.defaultMissAlpha;
						var n:Int64 = note.toNumber();
						(n:MetaNote).held = true;
						isHeld = true;
						parent.onSustainRelease.dispatch(note);
					}

					strumline.notesToHit[index] = null;
					strumline.notesToHit_indexes[index] = 0;

					var hud = parent.hud;
					if (SaveData.state.preferences.ratingPopup && hud != null) {
						hud.hideRatingPopup();
					}

					File.setNote(_id, n);
				}
			}
		}

		// --- Opponent side ---
		else {
			// Handle opponent note hit (non-sustain)
			if (!isHit && diff < 0) {
				var n:Int64 = note.toNumber();
				(n:MetaNote).flag = isHit = true;

				// Confirm the receptor
				if (!rec.confirmed()) rec.confirm();

				// Start glow timer for non-sustains
				strumline.botTimers[index] = 0.045;

				strumline.sustainsToHold_duration[index] = 0;

				// Setup sustain visuals if needed
				if (sustainExists) {
					strumline.sustainsActive[index] = true;
					strumline.sustainsToHold_duration[index] = note.duration;
					sustainSpr.followNote(rec.x, rec.y, id);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (@:privateAccess parent.onNoteHit.__listeners.length != 0)
					parent.onNoteHit.dispatch(note, 0, noteSpr.notesInOne);
				if (parent.field != null)
					parent.field.hitNote(note, 0, noteSpr.notesInOne);
				parent.hitNote(note, 0, noteSpr.notesInOne);

				File.setNote(_id, n);
			}
		}

		// --- Sustain handling ---
		var sustainLength = (duration * 4) - 10;
		if (sustainExists) {
			sustainSpr.ref = noteSpr;
			sustainSpr.r = parent.downScroll ? -90 : 90;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;
			sustainSpr.length = sustainLength;

			if (!isHit) {
				sustainSpr.w = sustainLength;
				sustainSpr.followNote(noteSprX, noteSprY, id);
			} else if (sustainSpr.alpha != 0) {
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec.x, rec.y, id);
					sustainSpr.w = sustainLength - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (pos > position + (MetaNote.floatToMetaNotePosition(sustainLength - 12)) && !isHeld) {
					var n:Int64 = note.toNumber();
					(n:MetaNote).held = true;
					isHeld = true;

					if (playable && rec.confirmed()) rec.press();

					strumline.sustainsToHold[index] = null;
					strumline.sustainsToHold_indexes[index] = 0;

					if (@:privateAccess parent.onSustainComplete.__listeners.length != 0)
						parent.onSustainComplete.dispatch(note);
					if (parent.field != null)
						parent.field.completeSustain(note);
					parent.completeSustain(note);

					File.setNote(_id, n);
				}
			}

			// Fixes the rare receptor pause issue, finally
			if (diff + sustainLength - 12 < 0)
				strumline.sustainsActive[index] = !isHeld;

			if (noteSpr != null)
				virtualNoteBuffers[THREAD_ID].addSustain(sustainSpr, noteSpr);
		}

		// --- Buffer note ---
		if (!isHit)
			virtualNoteBuffers[THREAD_ID].addNote(noteSpr);

		return noteSpr;
	}

	// Add these cache variables at the class level
	var _cachedScrollSpeed:Float = 0;
	var _cachedHitbox:Float = 0;
	var _cachedDownScroll:Bool = false;

	// Update them when scroll speed changes
	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(360 / Math.min(Math.max(value, 0.0001), 1.0));
		parent.hitbox = 250 * value;
		_cachedScrollSpeed = value;
		_cachedHitbox = parent.hitbox;
		_cachedDownScroll = parent.downScroll;
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
		// Clear up the virtual note buffer for the funnies
		for (virtualNoteBuffer in virtualNoteBuffers)
			virtualNoteBuffer.clear();

		// Clear note & sustain buffers to refresh for new window
		notesBuf.clear();
		sustainsBuf.clear();

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

		var display = parent.display;

		display.removeProgram(sustainProg);
		display.removeProgram(notesProg);
	}
}