package structures.gameplay;

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

	function new(parent:PlayField) {
		noteTypeFunctionalityPre = [];
		noteTypeFunctionalityPre.resize(1 << 7);

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

		virtualNoteBuffer = new NoteVB(strumlines.length, strumlines[0].buffer.length);

		setScrollSpeed(Chart.header.speed);

		update(MetaNote.floatToMetaNotePosition(parent.songPosition));
	}

	var movingBackward(default, null):Bool = false;
	private var _stableLastPos:Int64;

	function update(pos:Int64) {
		if (_lastPos == 0) { _lastPos = pos; _stableLastPos = pos; }

		movingBackward = pos < _stableLastPos;
		_stableLastPos = pos;

		var delta = pos - _lastPos;
		if (delta < 0 || MetaNote.metaNotePositionToSongTime(delta) > 200)
			_lastPos = pos;

		virtualNoteBuffer.clear();

		if (noteSpawner != null)
			noteSpawner.update(pos);
	}

	private var _lastPos(default, null):Int64;

	function onSongPositionJump(pos:Int64, pushToOffset:Float = 0) {
		_lastPos = pos;
		_stableLastPos = pos;
		resetStrumlines();

		if (noteSpawner != null) {
			noteSpawner.resetNotes(MetaNote.metaNotePositionToSongTime(pos), pushToOffset);
		}
	}

	private function refreshRendering(pos:Int64) {
		notesBuf.clear();
		sustainsBuf.clear();

		var delta = pos - _lastPos;
		if (delta < 0) delta = -delta;
		var timeDelta = MetaNote.metaNotePositionToSongTime(delta) * 0.001;

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

	function renderNotes(pos:Int64) {
		refreshRendering(pos);
		noteSpawner.renderNotes(pos);
	}

	function drawNote(pos:Int64, note:MetaNote, diff:Float, _id:Int64):VirtualNote {
		var index = note.index;
		var lane = 0;
		var duration = note.duration;
		var timeCorrection = File.getTimeCorrectionForIndex(_id);
		var position = note.position + timeCorrection;

		var noteTypeCall:Int->Int->Bool->Void = noteTypeFunctionalityPre[note.type];
		var noteTypeCallExists = noteTypeCall != null;

		if (!noteTypeCallExists) {
			lane = note.type % strumlines.length;
		} else {
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

		// Judgement-gated state reads
		var judged:Bool   = File.getJudgement(_id);
		var isHit:Bool    = judged && !note.flag;   // judged + flag=false → hit
		//if (_id == 1) Sys.println('NOTE 1 IS HIT? $isHit; but is note.flag hit (false)? ${note.flag}. Is it judged? $judged');
		var isMissed:Bool = judged && note.flag;  // judged + flag=true → missed
		// sustain resolution is tracked externally in strumline
		var isResolved:Bool = strumline.sustainsResolved[index];

		var noteSprX = rec.x;
		var noteSprY = rec.y;

		noteSpr.diff = Std.int(diff);
		noteSpr.Sx = noteSprX;
		noteSpr.Sy = noteSprY;
		noteSpr.scale = rec.scale;
		noteSpr.globalIndex = _id;

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

					if (!noteToHitExists) {
						strumline.notesToHit[index] = note;
						strumline.notesToHit_indexes[index] = noteSpr.globalIndex;
						strumline.getTimeCorrection[index] = timeCorrection;
					} else {
						var _pos = MetaNote.metaNotePositionToSongTime(
							(noteToHit.position + strumline.getTimeCorrection[index]) - pos
						) * _cachedScrollSpeed;  // Match diff's units
						if (strumline.notesToHit_indexes[index] != noteSpr.globalIndex && Math.abs(diff) < Math.abs(_pos)) {
							strumline.notesToHit[index] = note;
							strumline.notesToHit_indexes[index] = _id;
							strumline.getTimeCorrection[index] = timeCorrection;
						}
					}
				}

				if (diff < -_cachedHitbox - offset && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					var n:Int64 = note.toNumber();
					(n:MetaNote).flag = true;           // chosen to miss
					isMissed = true;
					File.setJudgement(_id, true);

					var type = note.type;
					if (noteTypeCallExists) {
						noteTypeCall(index, type, true);
					}

					if (@:privateAccess parent.onNoteMiss.__listeners.length != 0)
						parent.onNoteMiss.dispatch(note, noteSpr.notesInOne);
					if (parent.field != null)
						parent.field.missNote(note, noteSpr.notesInOne);
					parent.missNote(note, noteSpr.notesInOne, _id);

					if (sustainExists && !isResolved) {
						sustainSpr.alpha = Sustain.defaultMissAlpha;
						strumline.sustainsResolved[index] = true;
						isResolved = true;
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
			if (!isHit && diff < 0) {
				var n:Int64 = note.toNumber();
				// opponent hit: judged as hit (missed=false)
				(n:MetaNote).flag = false;
				// Re-read immediately so sustain/visual logic below uses correct state
				isHit = true;
				File.setJudgement(_id, true);

				if (!rec.confirmed()) rec.confirm();

				strumline.botTimers[index] = 0.045;
				strumline.sustainsToHold_duration[index] = 0;

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

				File.setNote(_id, n);
			}
		}

		// --- Sustain handling ---
		var sustainLength = (duration >> 1) - 20;
		if (sustainExists) {
			sustainSpr.ref = noteSpr;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;
			sustainSpr.length = sustainLength;
			sustainSpr.followNote(rec.x, rec.y, id);
			sustainSpr.diff = isHit ? 0 : Std.int(diff);

			var sustainCompleted = pos > position + (MetaNote.floatToMetaNotePosition(sustainLength - 25));

			if (isResolved && !sustainCompleted)
				sustainSpr.alpha = Sustain.defaultMissAlpha;

			if (!isHit) {
				sustainSpr.w = sustainLength;
			} else if (sustainSpr.alpha != 0) {
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec.x, rec.y, id);
					sustainSpr.w = (sustainLength) - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (sustainCompleted && !isResolved) {
					if (!movingBackward) {
						strumline.sustainsResolved[index] = true;
						isResolved = true;
					}

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

			if (diff + (sustainLength >> 1) - 25 < 0)
				strumline.sustainsActive[index] = !isResolved;

			if (noteSpr != null)
				virtualNoteBuffer.addSustain(sustainSpr, noteSpr);
		}

		if (!isHit)
			virtualNoteBuffer.addNote(noteSpr);

		//if (_id == 0 && playable) Sys.println('SET JUDGEMENT for $_id, readback: ${File.getJudgement(_id)}');

		return noteSpr;
	}

	var _cachedScrollSpeed:Float = 0;
	var _cachedHitbox:Float = 200;
	var _cachedDownScroll:Bool = false;

	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(360 / Math.min(Math.max(value, 0.0001), 1.0));
		_cachedScrollSpeed = value;
		_cachedHitbox = 200;
		_cachedDownScroll = parent.downScroll;
		return value;
	}

	function resetStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims) strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

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

	function resetNotes(songPosition:Float) {
		noteSpawner.resetNotes(songPosition);
	}

	function dispose() {
		virtualNoteBuffer.clear();
		notesBuf.clear();
		sustainsBuf.clear();

		if (strumlines != null) {
			while (strumlines.length != 0) {
				var strumline = strumlines.pop();
				strumline.dispose();
			}
			strumlines = null;
		}

		if (noteSpawner != null) noteSpawner = null;

		if (notePool != null) {
			notePool.dispose();
			notePool = null;
		}

		var display = parent.display;
		display.removeProgram(sustainProg);
		display.removeProgram(notesProg);

		NoteSpawner.minBottom = 0;
	}
}