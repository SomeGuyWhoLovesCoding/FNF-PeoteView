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
	static var sustainProg(default, null):CustomProgram;
	static var sustainsBuf(default, null):Buffer<Sustain>;

	static var notesProg(default, null):CustomProgram;
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

			notesProg = new CustomProgram(notesBuf);
			Note.init(notesProg, "noteTex", tex);
		}

		if (sustainsBuf == null) {
			sustainsBuf = new Buffer<Sustain>(128, 128, false);
		}

		if (sustainProg == null) {
			var tex2 = TextureSystem.getTexture("sustainTex");

			sustainProg = new CustomProgram(sustainsBuf);
			Sustain.init(sustainProg, "sustainTex", tex2);
		}
	}

	var strumlines(default, null):Array<Strumline>;
	var noteSpawner(default, null):NoteSpawner;
	var notePool(default, null):NotePool;
	var virtualNoteBuffer(default, null):NoteVB;

	var noteTypeFunctionalityPre(default, null):Array<Int->Int->Bool->Void>;

	var parent(default, null):PlayField;

	/**
	 * Creates the note system.
	 * @param parent The parent of this class.
	**/
	function new(parent:PlayField) {
		noteTypeFunctionalityPre = [];
		noteTypeFunctionalityPre.resize(1 << 7); // Max 7 bit value (128 possible entries)

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

		virtualNoteBuffer = new NoteVB(strumlines.length, strumlines[0].buffer.length);

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

		virtualNoteBuffer.clear();

		if (noteSpawner != null)
			noteSpawner.update(pos);

		//trace('Note pool length: ${notePool.inactiveVirtualNotes.length}, Sustain pool length:  ${notePool.inactiveVirtualSusses.length}');
	}

	private var _lastPos(default, null):Int64; // for adaptive bot timer

	/**
	 * Call this when pausing, seeking, or any time the song position jumps.
	 * This ensures bot timers are properly synchronized.
	**/
	function onSongPositionJump(pos:Int64) {
		_lastPos = pos;
		resetStrumlines(); // force reset them

		if (noteSpawner != null) {
			noteSpawner.resetNotes(MetaNote.metaNotePositionToSongTime(pos));
		}
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

	#if hl
	private var _csvFile:sys.io.FileOutput = null;
	private var _csvFrame:Int = 0;
	#end

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
	function drawNote(pos:Int64, note:MetaNote, diff:Float, _id:Int64):VirtualNote {
		var index = note.index;
		var lane = 0;
		var duration = note.duration;
		//if (_id <= 6) trace(duration);
		var timeCorrection = File.getTimeCorrectionForIndex(_id);
		//if (_id == 2) trace(_id, 'Position ${note.position} Time correction ${timeCorrection} Diff ${diff}');
		var position = note.position + timeCorrection;

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
		var sustainSpr = duration != 0 ? notePool.getSustain(id, note, _id) : null;
		var sustainExists = duration != 0;

		var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));
		var isHit:Bool = File.isNoteHit(_id);
		var isMissed:Bool = File.isNoteMissed(_id);
		var isHeld:Bool = File.isNoteHeld(_id);

		var noteSprX = rec.x;
		var noteSprY = rec.y;

		noteSpr.diff = Std.int(diff);
		noteSpr.Sx = noteSprX;
		noteSpr.Sy = noteSprY;
		noteSpr.scale = rec.scale;
		noteSpr.ref = note;

		var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

		var offset = Main.conductor.offset;

		// --- Player side ---
		if (playable) {
			if (!isHit) {
				if (isMissed)
					noteSpr.initialAlpha = Note.defaultMissAlpha;

				if (!isMissed && diff < _cachedHitbox - offset) {
					var noteToHit = strumline.notesToHit[index];
					var noteToHitExists = noteToHit != null;

					var _pos = MetaNote.metaNotePositionToSongTime((noteToHit.position + strumline.getTimeCorrection[index]) - pos);
					if (!noteToHitExists || Math.abs(diff) < Math.abs(_pos)) {
						strumline.notesToHit[index] = note;
						strumline.notesToHit_indexes[index] = _id;
						strumline.getTimeCorrection[index] = timeCorrection;
					}
				}

				if (diff < -_cachedHitbox - offset && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					var n:Int64 = note.toNumber();
					File.setNoteMissed(_id, isMissed = true);

					var type = note.type;
					if (noteTypeCallExists) {
						noteTypeCall(index, type, true);
					}

					if (@:privateAccess parent.onNoteMiss.__listeners.length != 0)
						parent.onNoteMiss.dispatch(note, noteSpr.notesInOne);
					if (parent.field != null)
						parent.field.missNote(note, noteSpr.notesInOne);
					parent.missNote(note, noteSpr.notesInOne, _id);

					if (sustainExists && !isHeld) {
						sustainSpr.alpha = Sustain.defaultMissAlpha;
						File.setNoteHeld(_id, isHeld = true);
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
				var n:Int64 = note.toNumber();
				File.setNoteHit(_id, isHit = true);

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
				parent.hitNote(note, 0, noteSpr.notesInOne, _id);
			}
		}

		// --- Sustain handling ---
		var sustainLength = duration - 20;
		if (sustainExists) {
			sustainSpr.ref = noteSpr;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;
			sustainSpr.length = sustainLength;
			sustainSpr.followNote(rec.x, rec.y, id);
			sustainSpr.diff = isHit ? 0 : Std.int(diff);

			if (isHeld || isMissed)
				sustainSpr.alpha = Sustain.defaultMissAlpha;

			if (!isHit) {
				sustainSpr.w = sustainLength;
			} else if (sustainSpr.alpha != 0) {
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec.x, rec.y, id);
					sustainSpr.w = sustainLength - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (pos > position + (MetaNote.floatToMetaNotePosition(sustainLength - 45)) && !isHeld) {
					var n:Int64 = note.toNumber();
					File.setNoteHeld(_id, isHeld = true);

					if (playable && rec.confirmed()) rec.press();

					strumline.sustainsToHold[index] = null;
					strumline.sustainsToHold_indexes[index] = 0;

					if (@:privateAccess parent.onSustainComplete.__listeners.length != 0)
						parent.onSustainComplete.dispatch(note);
					if (parent.field != null)
						parent.field.completeSustain(note);
					parent.completeSustain(note, _id);
				}
			}

			// Fixes the rare receptor pause issue, finally
			if (diff + sustainLength - 45 < 0)
				strumline.sustainsActive[index] = !isHeld;

			if (noteSpr != null)
				virtualNoteBuffer.addSustain(sustainSpr, noteSpr);
		}

		// --- Buffer note ---
		if (!isHit)
			virtualNoteBuffer.addNote(noteSpr);

		return noteSpr;
	}

	// Add these cache variables at the class level
	var _cachedScrollSpeed:Float = 0;
	var _cachedHitbox:Float = 200;
	var _cachedDownScroll:Bool = false;

	// Update them when scroll speed changes
	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(360 / Math.min(Math.max(value, 0.0001), 1.0));
		_cachedScrollSpeed = value;
		_cachedHitbox = 200;
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
		#if hl
		if (_csvFile != null) { _csvFile.close(); _csvFile = null; }
		#end

		// Clear up the virtual note buffer for the funnies
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