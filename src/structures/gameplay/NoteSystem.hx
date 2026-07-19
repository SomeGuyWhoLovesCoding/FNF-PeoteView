package structures.gameplay;

import structures.gameplay.NoteVB.VirtualNote;
import structures.gameplay.NoteVB.VirtualSustain;

/**
 * This is where notes and strumlines render in accordance to the note spawner.
 * @since Development
 */
@:publicFields
class NoteSystem {
	static var sustainProg(default, null):CustomProgram;
	static var sustainsBuf(default, null):Buffer<Sustain>;

	static var notesProg(default, null):CustomProgram;
	static var notesBuf(default, null):Buffer<Note>;

	static var STRUMLINE_X_OFFSET = 50;
	static var STRUMLINE_Y_OFFSET = 50;
	static var STRUMLINE_Y_OFFSET_DOWNSCROLL = 150;

	static var SUSTAIN_TAIL = 20;
	static var SUSTAIN_TAIL_END = 25;

	static var NOTE_HOLD_THRESHOLD = 17;
	static var NOTE_HOLD_THRESHOLD_SUSTAIN = 18;

	// === Dynamic hold-threshold tuning ===
	// Absolute floor for the dynamic threshold so the confirm window is never
	// reduced to zero (which would cause the receptor to never visibly "press").
	static var NOTE_HOLD_THRESHOLD_MIN = 4;
	// Safety buffer (ms) reserved between the end of this note's hold and the
	// arrival of the next same-receptor note, so the receptor has time to
	// visually reset (return to idle) before being pressed again.
	static var NOTE_HOLD_RESET_BUFFER = 5;
	// Multiplier on `baseThreshold` used to define what counts as "far enough
	// in time" that no shortening is needed. At and beyond this gap the dynamic
	// threshold equals the base threshold.
	static var NOTE_HOLD_TIME_FAR_FACTOR = 4.0;

	static function init() {
        if (NoteskinManager.textureCache == null) {
            NoteskinManager.init();
        }

        typeToHandle = [for (_ in 0...1 << 8) NoteskinManager.get("default")];
		var handle = typeToHandle[0];

        handle.loadTexture();

		if (notesBuf == null) {
			notesBuf = new Buffer<Note>(16, 16, true);
		}

		if (notesProg == null) {
			notesProg = new CustomProgram(notesBuf);
			Note.init(notesProg);
            handle.setProgramsTexture(notesProg);
            handle.setProgramsNoteShader(notesProg);
		}

		if (sustainsBuf == null) {
			sustainsBuf = new Buffer<Sustain>(16, 16, true);
		}

		if (sustainProg == null) {
			sustainProg = new CustomProgram(sustainsBuf);
			Sustain.init(sustainProg);
            handle.setProgramsTexture(sustainProg);
            handle.setProgramsSustainShader(sustainProg);
		}
	}

	var strumlines(default, null):Array<Strumline>;
	var noteSpawner(default, null):NoteSpawner;
	var noteMovement(default, null):NoteMovementSystem;
	var notePool(default, null):NotePool;
	var virtualNoteBuffer(default, null):NoteVB;

    static var typeToHandle:Array<NoteskinHandle> = [];

	var parent(default, null):PlayField;

	function new(parent:PlayField) {
		this.parent = parent;

		var display = parent.display;

		display.addProgram(sustainProg);
		display.addProgram(notesProg);

		strumlines = [];

		var inputSystem = parent.inputSystem;
		var mania = Chart.header.mania;

		for (i in 0...2) {
			var strumline = new Strumline(STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5)),
				parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET,
				typeToHandle[i], Std.int(inputSystem.strumline[0]), inputSystem.strumline[1], mania, this);
			strumline.playable = parent.inputSystem.strumlinePlayable[i];
			strumlines.push(strumline);
		}

		virtualNoteBuffer = new NoteVB(strumlines.length, strumlines[0].receptors.length);

		notePool = new NotePool(this);
		noteSpawner = new NoteSpawner(this);
		noteMovement = new NoteMovementSystem(this);

		setScrollSpeed(Chart.header.speed);

		update(MetaNote.floatToMetaNotePosition(parent.songPosition));
	}

	var movingBackward(default, null):Bool = false;
	private var _stableLastPos:Int64;

	function update(pos:Int64) {
		movingBackward = pos < _stableLastPos;
		_stableLastPos = pos;

		virtualNoteBuffer.clear();

		if (noteSpawner != null)
			noteSpawner.update(pos);
	}

	function onSongPositionJump(pos:Int64, pushToOffset:Float = 0) {
		_stableLastPos = pos;
		resetStrumlines();

		if (noteSpawner != null) {
			noteSpawner.resetNotes(MetaNote.metaNotePositionToSongTime(pos), pushToOffset);
		}
	}

	private function refreshRendering(songPosition:Float) {
		notesBuf.clear();
		sustainsBuf.clear();

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			var canMess = !strumline.playable || RenderingMode.enabled || parent.botplay;
			for (j in 0...strumline.receptors.length) {
				var receptor = strumline.receptors[j];
				var rec = receptor.note;
				if (parent.botplay) canMess = true;
				if (canMess) {
					receptor.updateAnimation(songPosition);
				}
			}
			strumline.draw(notesBuf);
		}
	}

	function renderNotes(pos:Int64) {
		refreshRendering(parent.songPosition);
		noteSpawner.renderNotes(pos);
	}

	/**
	 * Computes a dynamic note hold threshold based on:
	 *   1. How close the next note is in time (time proximity)
	 *   2. How close the next note's index (lane) is to the current note's index (index proximity)
	 *
	 * The base threshold is shortened when BOTH factors are high — i.e. when the
	 * next note is about to arrive soon AND it lives on a nearby lane. This lets
	 * the receptor visually reset (return to idle) before being pressed again,
	 * instead of holding the "confirm" pose across the gap.
	 *
	 * Rules:
	 *   - If there is no next note, the base threshold is returned unchanged.
	 *   - For sustain notes, the receptor is already held for `sustainDuration`
	 *     ms, so the available time for the post-sustain hold is
	 *     `timeGap - sustainDuration`. If that is non-positive (overlap/chord),
	 *     the minimum threshold is returned.
	 *   - `timeProximity` maps `availableTime` from `[0, baseThreshold * FAR_FACTOR]`
	 *     onto `[1, 0]`. Beyond that range, time proximity is 0 (no shortening).
	 *   - `indexProximity = 1 / (1 + |Δindex|)`: 1.0 same lane, 0.5 adjacent, 0.33
	 *     two-away, etc.
	 *   - The combined `proximity = timeProximity * indexProximity` interpolates
	 *     the threshold between `baseThreshold` and `NOTE_HOLD_THRESHOLD_MIN`.
	 *   - A hard cap is applied based on the next note on the SAME LANE (scanning 
	 *     forward past any interleaved notes): the threshold can never exceed
	 *     `availableTime - NOTE_HOLD_RESET_BUFFER`, guaranteeing the receptor
	 *     has time to reset before the next press.
	 *
	 * @param currentNote      The note currently being processed
	 * @param _id              Global index of `currentNote` in the `File` array
	 * @param baseThreshold    The default threshold that would be used statically
	 *                         (`NOTE_HOLD_THRESHOLD` or `NOTE_HOLD_THRESHOLD_SUSTAIN`)
	 * @param sustainDuration  Duration (ms) of the sustain, if this is a sustain
	 *                         note; otherwise 0.
	 * @return                 Dynamic threshold in ms.
	 */
	function computeDynamicHoldThreshold(currentNote:MetaNote, _id:Int64,
		baseThreshold:Float, sustainDuration:Float = 0):Float {
		var len = File.getLength();
		var nextId = _id + 1;

		// No next note — nothing to scale against, use the full base threshold.
		if (nextId >= len) return baseThreshold;

		var nextNote = File.getNote(nextId);

		// Time gap (ms) between the start of this note and the start of the next.
		var timeGapMs = MetaNote.metaNotePositionToSongTime(
			nextNote.position - currentNote.position
		);

		// For sustain notes, the receptor is held for `sustainDuration` ms first,
		// so the time available for the *post-hold* threshold is reduced.
		var availableTime = timeGapMs - sustainDuration;

		// Chords / overlapping notes — no room to hold; collapse to the minimum.
		if (availableTime <= 0) return NOTE_HOLD_THRESHOLD_MIN;

		// === Factor 1: time proximity ===
		// 1.0 = next note is right on top of us, 0.0 = next note is far away.
		var farRef = baseThreshold * NOTE_HOLD_TIME_FAR_FACTOR;
		var timeProximity:Float = Math.max(0.0, 1.0 - (availableTime / farRef));

		// === Factor 2: index proximity ===
		// 1.0 = same lane, 0.5 = adjacent lane, 0.33 = two-away, etc.
		var indexGap = Math.abs(nextNote.index - currentNote.index);
		var indexProximity:Float = 1.0 / (1.0 + indexGap);

		// Combined proximity — only shorten when both factors are non-trivial.
		var proximity = indexProximity * timeProximity;

		// Interpolate between the base threshold and the minimum.
		var dynamicThreshold = baseThreshold
			- (baseThreshold - NOTE_HOLD_THRESHOLD_MIN) * proximity;

		// === Hard cap for same-lane successors ===
		// We must scan forward to find the next note on the SAME LANE, because
		// the immediate next note might be on a different lane (e.g. in a jack
		// with interleaved notes). If we only check the immediate next note,
		// the hard cap would be skipped, causing the receptor to hold across
		// the jack and feel like a single long note.
		//
		// We only need to scan notes that arrive within the maximum possible
		// threshold window. Beyond this, the hard cap cannot possibly reduce
		// the dynamicThreshold (since it never exceeds baseThreshold).
		var maxScanGapMs = baseThreshold + sustainDuration + NOTE_HOLD_RESET_BUFFER + 1.0;
		var nextSameLaneId = nextId;
		var foundSameLane = false;
		var sameLaneTimeGap = 0.0;

		while (nextSameLaneId < len) {
			var n = File.getNote(nextSameLaneId);
			var gapMs = MetaNote.metaNotePositionToSongTime(n.position - currentNote.position);
			
			// Stop scanning if we've passed the window where the cap could matter
			if (gapMs >= maxScanGapMs) {
				break;
			}
			
			if (n.index == currentNote.index) {
				foundSameLane = true;
				sameLaneTimeGap = gapMs;
				break;
			}
			nextSameLaneId++;
		}

		if (foundSameLane) {
			var sameLaneAvailableTime = sameLaneTimeGap - sustainDuration;

			if (sameLaneAvailableTime > 0) {
				var maxThreshold = Math.max(
					NOTE_HOLD_THRESHOLD_MIN,
					sameLaneAvailableTime - NOTE_HOLD_RESET_BUFFER
				);
				if (dynamicThreshold > maxThreshold) {
					dynamicThreshold = maxThreshold;
				}
			} else {
				// Overlapping same-lane notes (shouldn't happen, but handle gracefully)
				dynamicThreshold = NOTE_HOLD_THRESHOLD_MIN;
			}
		}

		return dynamicThreshold;
	}

	function drawNote(pos:Int64, note:MetaNote, diff:Float, _id:Int64):VirtualNote {
		var index = note.index;
		var lane = 0;
		var duration = note.duration;
		var position = note.position;

		lane = note.type % strumlines.length;

		var strumline = strumlines[lane];
		var receptor = strumline.receptors[index];
		var rec = receptor.note;
		var id = parent.inputSystem.receptorIds[index];

		var noteSpr = notePool.getNote(id, note, _id);
		if (noteSpr == null) return noteSpr;
		var sustainSpr = duration != 0 ? notePool.getSustain(id, note, _id) : null;
		var sustainExists = duration != 0;

		var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));

		// Judgement-gated state reads
		var judged:Bool   = File.getJudgement(_id);
		var isHit:Bool    = judged && !File.getHitFlag(_id);   // judged + flag=false → hit
		var isMissed:Bool = judged && File.getHitFlag(_id);  // judged + flag=true → missed
		var isResolved:Bool = receptor.sustainResolved;

		var noteSprX = rec.x;
		var noteSprY = rec.y;

		var d = Std.int(-diff);
		if (parent.downScroll) d = -d;

		noteSpr.diff = d;
		noteSpr.Sx = Std.int(noteSprX + (d * Math.cos(strumline.scrollDirection * 0.01745329)));
		noteSpr.Sy = Std.int(noteSprY + (d * Math.sin(strumline.scrollDirection * 0.01745329)));

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
					var noteToHit = receptor.noteToHit;
					var noteToHitExists = noteToHit != null;

					if (!noteToHitExists) {
						receptor.noteToHit = note;
						receptor.noteToHit_index = noteSpr.globalIndex;
					} else {
						var _pos = MetaNote.metaNotePositionToSongTime(
							noteToHit.position - pos
						) * _cachedScrollSpeed;  // Match diff's units
						if (receptor.noteToHit_index != noteSpr.globalIndex && Math.abs(diff) < Math.abs(_pos)) {
							receptor.noteToHit = note;
							receptor.noteToHit_index = _id;
						}
					}
				}

				if (diff < -_cachedHitbox - offset && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					File.setHitFlag(_id, true);	   // chosen to miss
					isMissed = true;
					File.setJudgement(_id, true);

					var type = note.type;

					if (@:privateAccess parent.onNoteMiss.__listeners.length != 0)
						parent.onNoteMiss.dispatch(note, noteSpr.notesInOne);
					if (parent.field != null)
						parent.field.missNote(note, noteSpr.notesInOne);
					parent.missNote(note, noteSpr.notesInOne, _id);

					if (sustainExists && !isResolved) {
						sustainSpr.alpha = Sustain.defaultMissAlpha;
						receptor.sustainResolved = true;
						isResolved = true;
						parent.onSustainRelease.dispatch(note);
					}

					receptor.noteToHit = null;
					receptor.noteToHit_index = 0;

					var hud = parent.hud;
					if (SaveData.state.preferences.ratingPopup && hud != null) {
						hud.hideRatingPopup();
					}
				}
			}
		}

		// --- Opponent side ---
		else {
			if (!isHit && diff < 0) {
				// opponent hit: judged as hit (missed=false)
				File.setHitFlag(_id, false);
				isHit = true;
				File.setJudgement(_id, true);

				if (!rec.confirmed()) rec.confirm();

				receptor.confirmTimer.startTime = parent.songPosition - offset; // don't do MetaNote.metaNotePositionToSongTime(position). That doesn't account for latency

				// Dynamic hold threshold: scans forward for the next same-receptor note
				// and shortens the confirm window the closer that note is in time, so
				// the receptor can visually reset before the next press instead of
				// holding across the gap.
				var baseThreshold = sustainExists
					? NOTE_HOLD_THRESHOLD_SUSTAIN
					: NOTE_HOLD_THRESHOLD;
				var dynamicThreshold = computeDynamicHoldThreshold(
					note, _id, baseThreshold, sustainExists ? duration : 0
				);

				var confirmWindow = sustainExists
					? duration + dynamicThreshold
					: dynamicThreshold;
				if (sustainExists) receptor.confirmTimer.tailTime = receptor.confirmTimer.startTime + duration - (SUSTAIN_TAIL + SUSTAIN_TAIL_END);
				receptor.confirmTimer.endTime = receptor.confirmTimer.startTime + confirmWindow;
				//trace("started confirm" + parent.songPosition);

				receptor.sustainToHold_duration = 0;

				if (sustainExists) {
					receptor.sustainResolved = false;
					receptor.sustainToHold_duration = duration;
					sustainSpr.followNote(rec.x + receptor.sustainPivotX, rec.y + receptor.sustainPivotY, id);
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
		var sustainLength = duration - SUSTAIN_TAIL;
		if (sustainExists) {
			sustainSpr.ref = noteSpr;
			sustainSpr.speed = parent.scrollSpeed;
			sustainSpr.scale = rec.scale;
			sustainSpr.length = sustainLength;
			sustainSpr.followNote(noteSpr.Sx + receptor.sustainPivotX, noteSpr.Sy + receptor.sustainPivotY, id);
			sustainSpr.diff = isHit ? 0 : Std.int(diff);

			var sustainCompleted = pos > position + (MetaNote.floatToMetaNotePosition(sustainLength - SUSTAIN_TAIL_END));

			if (isResolved && !sustainCompleted && judged && playable)
				sustainSpr.alpha = Sustain.defaultMissAlpha;

			if (!isHit) {
				sustainSpr.w = sustainLength;
			} else {
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec.x + receptor.sustainPivotX, rec.y + receptor.sustainPivotY, id);
					sustainSpr.w = sustainLength - leftover;
					if (sustainSpr.w < 0) sustainSpr.w = 0;
				}

				if (sustainCompleted && !isResolved) {
					if (!movingBackward) {
						receptor.sustainResolved = true;
						isResolved = true;
					}

					if (playable && rec.confirmed()) rec.press();

					receptor.sustainToHold = null;
					receptor.sustainToHold_index = 0;

					if (@:privateAccess parent.onSustainComplete.__listeners.length != 0)
						parent.onSustainComplete.dispatch(note);
					if (parent.field != null)
						parent.field.completeSustain(note);
					parent.completeSustain(note, _id);
				}
			}

			if (diff + sustainLength - SUSTAIN_TAIL_END < 0)
				receptor.sustainActive = !isResolved;
		}

		if (noteSpr != null) {
			noteMovement.run(this, noteSpr, sustainSpr, rec, index, note.type, isHit);
			if (sustainExists)
				virtualNoteBuffer.addSustain(sustainSpr, noteSpr);
		}

		if (!isHit)
			virtualNoteBuffer.addNote(noteSpr);

		return noteSpr;
	}

	var _cachedScrollSpeed:Float = 0;
	var _cachedHitbox:Float = 200;

	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(360 / Math.min(Math.max(value, 0.0001), 1.0));
		_cachedScrollSpeed = value;
		_cachedHitbox = 200;
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