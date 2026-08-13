package structures.notes;

import structures.notes.NoteVB.VirtualNote;
import structures.notes.NoteVB.VirtualSustain;

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

	// === Confirm-duration tuning (human receptor timing) ===
	// Base (ms) a tap receptor holds its "confirm" pose for a single isolated
	// note — roughly how long a human key press reads on screen.
	static var TAP_CONFIRM_BASE = 90;
	// Absolute floor for the confirm window so the pose is never reduced to
	// zero (which would make the receptor appear to never press).
	static var TAP_CONFIRM_MIN = 6;
	// Base (ms) the receptor holds the press pose after a sustain ends, before
	// returning to idle.
	static var SUSTAIN_TAIL_BASE = 30;
	// Safety buffer (ms) reserved so the receptor can visibly reset (return to
	// idle) before the next same-receptor note is pressed.
	static var CONFIRM_RESET_BUFFER = 5;

	static function init() {
		if (NoteskinManager.textureCache == null) {
			NoteskinManager.init();
		}

		typeToHandle = [for (_ in 0...1 << 8) NoteskinManager.get("default")];
		// trace(typeToHandle);
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

	// Precomputed confirm window (ms) per note id. Built once per chart via
	// `buildConfirmWindows`; only depends on static chart layout, so it never
	// needs to be recomputed during playback. `null` marks "not built yet".
	var confirmWindowTable:Map<Int64, Float> = null;
	var confirmWindowTableBuiltFor:Int64 = -1;

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
				parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET, typeToHandle[i], 0, 0, mania, this);
			strumline.playable = i == 1;
			strumline.applyNoteskinProperties(typeToHandle[i], mania - 1);
			strumlines.push(strumline);
		}

		virtualNoteBuffer = new NoteVB(strumlines.length, 1 << 8);

		notePool = new NotePool(this);
		noteSpawner = new NoteSpawner(this);
		noteMovement = new NoteMovementSystem(this);

		// Add receptor notes to the buffer once — they are persistent
		// and never cleared during normal rendering.
		for (strumline in strumlines) {
			for (receptor in strumline.receptors) {
				notesBuf.addElement(receptor.note);
			}
		}

		setScrollSpeed(Chart.header.speed);

		buildConfirmWindows();

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
		// Receptors are persistent in the buffer — just update animations.
		// Pooled spawned notes are managed by notePool.beginFrame/endFrame.

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			var canMess = !strumline.playable || RenderingMode.enabled || parent.botplay;
			for (j in 0...strumline.receptors.length) {
				var receptor = strumline.receptors[j];
				var rec = receptor.note;
				if (parent.botplay)
					canMess = true;
				if (canMess) {
					receptor.updateAnimation(songPosition);
				}
			}
		}
	}

	function renderNotes(pos:Int64) {
		refreshRendering(parent.songPosition);
		notePool.beginFrame();
		noteSpawner.renderNotes(pos);
		notePool.endFrame();
		// Pooled elements had their @set("properties") fields modified in-place.
		// Flush all pending CPU→GPU changes so the new positions/alphas/etc.
		// actually take effect this frame.
		try
			notesBuf.update()
		catch (e) {}
		try
			sustainsBuf.update()
		catch (e) {}
	}

	/**
		Press-time hit candidate scan.

		The render pass only arms `receptor.noteToHit` inside `renderNotes()` (via
		`drawNote`), which runs once per frame — so a key press can observe up to a
		frame of stale arming, and a note that entered the hit window since the last
		render isn't hittable yet. This scans the currently spawned notes directly at
		press time and returns the closest unjudged note id on `strumline` lane
		`index` that is inside the hit window, or `-1` when there is none. The caller
		arms that note and hits it immediately.
	**/
	function findPlayerHitCandidate(strumline:Strumline, index:Int, posWithLatency:Int64):Int64 {
		var spawner = noteSpawner;
		if (spawner == null)
			return -1;

		var lane = strumlines.indexOf(strumline);
		if (lane < 0)
			return -1;

		var laneCount = strumlines.length;
		var offset = Main.conductor.offset;
		var window = _cachedHitbox - offset;
		var farEdge = -_cachedHitbox - offset;
		var scrollSpeed = parent.scrollSpeed;

		var bestId:Int64 = -1;
		var bestAbs:Float = Math.POSITIVE_INFINITY;
		var i = spawner.bottom;
		while (i < spawner.top) {
			var n = File.getNote(i);
			if (n.index == index && (n.type % laneCount) == lane && !File.getJudgement(i)) {
				var diff = MetaNote.metaNotePositionToSongTime(n.position - posWithLatency) * scrollSpeed;
				if (diff < window && diff >= farEdge) {
					var absDiff = Math.abs(diff);
					if (absDiff < bestAbs) {
						bestAbs = absDiff;
						bestId = i;
					}
				}
			}
			i++;
		}
		return bestId;
	}

	/**
	 * Recomputes the confirm window for every note into `confirmWindowTable`.
	 *
	 * Unlike the old per-frame forward scan, this runs exactly once per chart
	 * (charts are static during playback), and the confirm timing becomes a
	 * single O(1) table lookup at hit time.
	 *
	 * The model for taps:
	 *   - An isolated tap holds the "confirm" pose for `TAP_CONFIRM_BASE` ms,
	 *     which reads like a human key press.
	 *   - The ONLY thing that can force it shorter is the next note on the
	 *     SAME receptor (same strumline + same lane). If that note arrives
	 *     sooner, the confirm is squeezed to end `CONFIRM_RESET_BUFFER` ms
	 *     before it, so the receptor visibly returns to idle before the next
	 *     press. It is never reduced below `TAP_CONFIRM_MIN`.
	 *   - Notes on other lanes/strumlines are irrelevant to this receptor's
	 *     reset timing, so they no longer influence the window at all (the old
	 *     time/index-proximity heuristic is gone).
	 *
	 * For sustains the confirm lasts the whole `duration`, plus a short
	 * post-sustain tail (`SUSTAIN_TAIL_BASE`), clamped the same way against
	 * the next same-receptor note.
	 */
	function buildConfirmWindows() {
		var len = File.getLength();
		confirmWindowTableBuiltFor = len;

		confirmWindowTable = new Map<Int64, Float>();
		confirmWindowTable.clear();

		var laneCount = strumlines.length;
		var lastIdByReceptor = new Map<Int, Int64>();
		var lastNoteByReceptor = new Map<Int, MetaNote>();

		var i:Int64 = 0;
		while (i < len) {
			var note = File.getNote(i);
			var lane = note.type % laneCount;
			var receptorKey = lane * 256 + note.index;

			var prevId = lastIdByReceptor.get(receptorKey);
			if (prevId != null) {
				var prevNote = lastNoteByReceptor.get(receptorKey);
				var gapMs = MetaNote.metaNotePositionToSongTime(note.position - prevNote.position);
				confirmWindowTable.set(prevId, prevNote.duration != 0
					? computeConfirmWindowSustain(prevNote.duration, gapMs)
					: computeConfirmWindowTap(gapMs));
			}

			// Default for this note: no (known) successor yet → base window.
			// Overwritten above when its own successor is found later.
			confirmWindowTable.set(i, note.duration != 0
				? computeConfirmWindowSustain(note.duration, Math.POSITIVE_INFINITY)
				: TAP_CONFIRM_BASE);

			lastIdByReceptor.set(receptorKey, i);
			lastNoteByReceptor.set(receptorKey, note);
			i++;
		}
	}

	/**
	 * Tap confirm window given the ms until the next note on the same receptor.
	 * `gapMs == POSITIVE_INFINITY` means no successor — use the natural base.
	 */
	inline function computeConfirmWindowTap(gapMs:Float):Float {
		if (gapMs >= TAP_CONFIRM_BASE + CONFIRM_RESET_BUFFER)
			return TAP_CONFIRM_BASE;
		return Math.max(TAP_CONFIRM_MIN, gapMs - CONFIRM_RESET_BUFFER);
	}

	/**
	 * Sustain confirm window: full `duration` plus a post-sustain tail, clamped
	 * so the tail ends `CONFIRM_RESET_BUFFER` ms before the next same-receptor
	 * note (or uses the natural base tail when there is none).
	 */
	inline function computeConfirmWindowSustain(duration:Float, gapMs:Float):Float {
		var tail:Float;
		if (gapMs >= duration + SUSTAIN_TAIL_BASE + CONFIRM_RESET_BUFFER) {
			tail = SUSTAIN_TAIL_BASE;
		} else {
			tail = Math.max(TAP_CONFIRM_MIN, (gapMs - duration) - CONFIRM_RESET_BUFFER);
		}
		return duration + tail;
	}

	/**
	 * O(1) confirm window for a note id. Rebuilds the table lazily if the chart
	 * was remapped/edited since it was built.
	 */
	inline function getConfirmWindow(_id:Int64):Float {
		if (confirmWindowTable == null || confirmWindowTableBuiltFor != File.getLength())
			buildConfirmWindows();
		var v = confirmWindowTable.get(_id);
		return v == null ? TAP_CONFIRM_BASE : v;
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
		var handle = NoteSystem.typeToHandle[note.type];

		var noteSpr = notePool.getNote(index, note, _id);
		if (noteSpr == null)
			return noteSpr;
		var sustainSpr = duration != 0 ? notePool.getSustain(index, note, _id) : null;
		var sustainExists = duration != 0;

		var leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));

		// Judgement-gated state reads
		var judged:Bool = File.getJudgement(_id);
		var isHit:Bool = judged && !File.getHitFlag(_id); // judged + flag=false → hit
		var isMissed:Bool = judged && File.getHitFlag(_id); // judged + flag=true → missed
		var isResolved:Bool = receptor.sustainResolved;

		var noteSprX = rec.x;
		var noteSprY = rec.y;

		var d = Std.int(-diff);
		if (parent.downScroll)
			d = -d;

		noteSpr.diff = d;
		//BOTTLENECK: mid per-note per-frame Math.cos/Math.sin of lane-constant scrollDirection = thousands of trig calls/frame on dense charts | FIX: precompute cos/sin once per strumline when scrollDirection changes
		noteSpr.Sx = Math.round(noteSprX + (d * Math.cos(strumline.scrollDirection * 0.01745329)));
		noteSpr.Sy = Math.round(noteSprY + (d * Math.sin(strumline.scrollDirection * 0.01745329)));

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
						var _pos = MetaNote.metaNotePositionToSongTime(noteToHit.position - pos) * _cachedScrollSpeed; // Match diff's units
						if (receptor.noteToHit_index != noteSpr.globalIndex && Math.abs(diff) < Math.abs(_pos)) {
							receptor.noteToHit = note;
							receptor.noteToHit_index = _id;
						}
					}
				}

				if (diff < -_cachedHitbox - offset && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					File.setHitFlag(_id, true); // chosen to miss
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

				if (!rec.confirmed())
					rec.confirm();

				receptor.confirmTimer.startTime = parent.songPosition - offset; // don't do MetaNote.metaNotePositionToSongTime(position). That doesn't account for latency

				// Precomputed confirm window (compute-once): the tap/sustain model
				// and the next same-receptor note were resolved when the chart was
				// loaded. Shortening the closer the next note is in time lets the
				// receptor visually reset before the next press instead of holding
				// the confirm pose across the gap.
				var confirmWindow = getConfirmWindow(_id);
				if (sustainExists)
					receptor.confirmTimer.tailTime = receptor.confirmTimer.startTime + duration - (SUSTAIN_TAIL + SUSTAIN_TAIL_END);
				receptor.confirmTimer.endTime = receptor.confirmTimer.startTime + confirmWindow;
				// trace("started confirm" + parent.songPosition);

				receptor.sustainToHold_duration = 0;

				if (sustainExists) {
					receptor.sustainResolved = false;
					receptor.sustainToHold_duration = duration;
					sustainSpr.followNote(rec.x + receptor.sustainPivotX, rec.y + receptor.sustainPivotY, index);
					sustainSpr.w = sustainSpr.length - leftover;
					if (sustainSpr.w < 0)
						sustainSpr.w = 0;
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
			sustainSpr.followNote(noteSpr.Sx + receptor.sustainPivotX, noteSpr.Sy + receptor.sustainPivotY, index);
			sustainSpr.diff = isHit ? 0 : Std.int(diff);

			var sustainCompleted = pos > position + (MetaNote.floatToMetaNotePosition(sustainLength - SUSTAIN_TAIL_END));

			if (isResolved && !sustainCompleted && judged && playable)
				sustainSpr.alpha = Sustain.defaultMissAlpha;

			if (!isHit) {
				sustainSpr.w = sustainLength;
			} else {
				if (sustainSpr.w >= 0) {
					sustainSpr.followNote(rec.x + receptor.sustainPivotX, rec.y + receptor.sustainPivotY, index);
					sustainSpr.w = sustainLength - leftover;
					if (sustainSpr.w < 0)
						sustainSpr.w = 0;
				}

				if (sustainCompleted && !isResolved) {
					if (!movingBackward) {
						receptor.sustainResolved = true;
						isResolved = true;
					}

					if (playable && rec.confirmed())
						rec.press();

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
			noteMovement.run(this, noteSpr, sustainSpr, receptor, index, note.type, isHit);
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
			if (resetAnims)
				strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

	function resetPlayerStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			if (!strumline.playable)
				continue;
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i * 0.5));
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims)
				strumline.resetAnimations();
			strumline.resetInputs();
		}
	}

	function resetNotes(songPosition:Float) {
		noteSpawner.resetNotes(songPosition);
	}

	function dispose() {
		virtualNoteBuffer.clear();

		if (notePool != null) {
			notePool.dispose();
			notePool = null;
		}

		notesBuf.clear();
		sustainsBuf.clear();

		if (strumlines != null) {
			while (strumlines.length != 0) {
				var strumline = strumlines.pop();
				strumline.dispose();
			}
			strumlines = null;
		}

		if (noteSpawner != null)
			noteSpawner = null;

		var display = parent.display;
		display.removeProgram(sustainProg);
		display.removeProgram(notesProg);

		NoteSpawner.minBottom = 0;
		for (i in 0...256) {
			var defaultHandle = NoteskinManager.get("default");
			NoteSystem.typeToHandle[i] = defaultHandle;
		}
	}
}
