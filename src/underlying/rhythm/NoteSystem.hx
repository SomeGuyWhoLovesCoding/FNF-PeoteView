package underlying.rhythm;

import underlying.rhythm.NoteVB.VirtualNote;
import underlying.rhythm.NoteVB.VirtualSustain;
import underlying.data.chart.File;
import underlying.rhythm.NoteMovementLUT;
import cpp.Pointer;
import cpp.RawPointer;

/**
 * This is where notes and strumlines render in accordance to the note spawner.
 * v3.9.0: the render state lives in the chart extern's GTFR arenas (packed
 * words, grow-only). drawNote computes and BINDS; the render walk reads the
 * packed words straight off the raw pointer and pushes them into the parked
 * render pool.
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

	// ==================================================================
	// Lane (strumline) resolution.
	//
	// The v2 note format stores the strumline ON every note (the 6-bit
	// lane field) — placement writes it (the hovered strumline, or the
	// transpiler from the source chart's side) and every draw/judge/
	// spawn/editor site reads it back. The type→strumline routing
	// table that used to sit here is GONE: the notetype is now purely
	// a skin/behavior id (typeToHandle), freely adjustable without
	// affecting which strumline a note belongs to.
	// ==================================================================

	/**
		Clamps a STORED lane (the v2 note format's 6-bit strumline field)
		into the available strumlines. The lane on a note is already a
		strumline id; this only guards against a stale lane written when
		more strumlines existed.
	**/
	static function clampLane(lane:Int, strumlineCount:Int):Int {
		if (lane < 0)
			return 0;
		if (strumlineCount <= 1)
			return 0;
		if (lane >= strumlineCount)
			return strumlineCount - 1;
		return lane;
	}

	static function init() {
		if (NoteskinManager.textureCache == null) {
			NoteskinManager.init();
		}

		typeToHandle = [for (_ in 0...1 << 8) NoteskinManager.get("default")];
		// trace(typeToHandle);
		var handle = typeToHandle[0];

		handle.loadTexture();

		if (notesBuf == null) {
			notesBuf = new Buffer<Note>(256, 256);
		}

		if (notesProg == null) {
			notesProg = new CustomProgram(notesBuf);
			Note.init(notesProg);
			handle.setProgramsTexture(notesProg);
			handle.setProgramsNoteShader(notesProg);
		}

		if (sustainsBuf == null) {
			sustainsBuf = new Buffer<Sustain>(256, 256);
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
	var renderPool(default, null):RenderPool;

	/** Per-lane movement LUTs: movementLUTs[strumline][receptor_index] */
	var movementLUTs(default, null):Array<Array<NoteMovementLUT>>;

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

		// v3.7: the count is the Main.STRUMLINE_COUNT global, NOT a
		// hardcoded 2 — the editor's paste lane-wrap reads the same
		// global, so a different strumline setup is a one-line change in
		// Main. The X layout divides the screen width by the count
		// (i / count), which for the default 2 is exactly the old
		// i * 0.5 spacing; the LAST strumline stays the player's.
		var strumlineCount = Main.STRUMLINE_COUNT;
		for (i in 0...strumlineCount) {
			var strumline = new Strumline(STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i / strumlineCount)),
				parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET, typeToHandle[i], 0, 0, mania, this);
			strumline.playable = i == strumlineCount - 1;
			strumline.applyNoteskinProperties(typeToHandle[i], mania - 1);
			strumlines.push(strumline);
		}

		// v3.9.0: the per-(lane,index) virtual-note buffer is GONE — the
		// render state lives in the chart extern's GTFR arenas (packed
		// words read off the raw pointer in renderNotes below).

		// Build movement LUTs — one per (strumline, receptor lane).
		// Replaces per-note Math.cos/Math.sin with precomputed offset lookups.
		// If a NoteMovementInterp formula is active, the full formula output
		// (position, scale, sustainRot, scrollMultiplier) is baked in.
		movementLUTs = [];
		rebuildMovementLUTs();

		renderPool = new RenderPool(this);
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

		update(MetaNote.floatToMetaNotePosition(parent.songPosition));
	}

	var movingBackward(default, null):Bool = false;
	private var _stableLastPos:Int64;

	function update(pos:Int64) {
		movingBackward = pos < _stableLastPos;
		_stableLastPos = pos;

		if (noteSpawner != null)
			noteSpawner.update(pos);
	}

	function onSongPositionJump(pos:Int64, pushToOffset:Float = 0) {
		_stableLastPos = pos;
		resetStrumlines();

		if (noteSpawner != null) {
			// false: resetStrumlines() above already ran this edit's reset —
			// the spawner must not repeat it (LUT rebuild + GPU flush x2).
			noteSpawner.resetNotes(MetaNote.metaNotePositionToSongTime(pos), pushToOffset, false);
		}
	}

	/**
	 * A chart MUTATION (editor add/remove/replace/undo/paste), as opposed
	 * to a position jump: the playhead does NOT move and nothing about the
	 * strumlines changed. The edit's only render-side effect is that the
	 * store re-sorted, which invalidated the window's global indexes —
	 * so only the window is re-derived here (binary search, O(log n)).
	 *
	 * Everything a real jump pays for is provably redundant here:
	 *   - resetStrumlines() — rebuilds movement LUTs (per lane x 4097
	 *     entries) from scrollDirection/speed/formula inputs that the
	 *     edit did not touch;
	 *   - notePool.reset() — notesBuf.clear() + receptor re-add, then a
	 *     next-frame re-acquire and CPU→GPU re-upload of every visible
	 *     note, when the pool already reconciles itself each frame via
	 *     beginFrame/endFrame;
	 *   - per-strumline notesBuf.update() flushes and per-receptor
	 *     ReceptorTimer allocations during that reset.
	 *
	 * The render pool self-heals exactly like the frozen seek path
	 * (PlayFieldEditorMode.seekTo, frozen branch): notes slide in and
	 * out of the window with no teardown at all.
	 */
	function onChartMutated(pos:Int64) {
		_stableLastPos = pos;

		// v3.9.0: the old window's arena bindings are recycled by the
		// spawner's light reset (the GTFR recycle-only sweep — every
		// binding of the old window drops in one exactly-once pass, then
		// the next update()'s processNotes rebinds from the iteration
		// itself). No render-side teardown happens here at all: no
		// notesBuf clear, no receptor re-add, no GPU flush — stale
		// bindings cannot survive the edit's frame by construction.
		if (noteSpawner != null)
			noteSpawner.resetNotes(MetaNote.metaNotePositionToSongTime(pos), 0, false, true);
	}

	private function refreshRendering(noteTime:Float) {
		// Receptors are persistent in the buffer — just update animations.
		// Pooled spawned notes are managed by renderPool.beginFrame/endFrame.

		// Editor mode: receptors never animate at all — nothing ever hits
		// a note there, so no confirm/press/reset timers ever get set.
		var editorRender = parent.playfieldEditorMode;

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			var canMess = !strumline.playable || RenderingMode.enabled || parent.botplay;
			for (j in 0...strumline.receptors.length) {
				var receptor = strumline.receptors[j];
				var rec = receptor.note;
				if (parent.botplay)
					canMess = true;
				if (canMess && !editorRender) {
					receptor.updateAnimation(noteTime);
				}
			}
		}
	}

	function renderNotes(pos:Int64) {
		// Editor mode always uses its own songPosition (startedCountdown is
		// false there); the latency split below is the vanilla gameplay path.
		var t = parent.playfieldEditorMode ? parent.songPosition : (parent.startedCountdown ? parent.noteTime : parent.songPosition);
		refreshRendering(t);
		// The frame boundary for the column chains: the last GTFR sweep
		// (processNotes, this frame) threaded them; the next sweep will
		// re-thread. One call, no scan.
		File.GTFR_FRAME_BEGIN();
		renderPool.beginFrame();
		renderVirtualNotes(pos);
		renderPool.endFrame();
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

	// The frame's raw arena pointers (one fromRaw per frame each; at()
	// reads are zero-FFI). Fields declared here so the walk helpers share.
	var _noteArena:Pointer<Int64>;
	var _sustainArena:Pointer<Int64>;

	// The draw pass's scratch pair — exactly one per NoteSystem,
	// allocated once, reused for EVERY note of every frame (the old
	// NotePool handed out one VirtualNote per chart note; the values
	// now flow into the GTFR arena at the end of drawNote, so the
	// scratch never carries state between notes except what the head
	// below resets).
	var drawScratchNote:VirtualNote = new VirtualNote(0, 0, 0);
	var drawScratchSustain:VirtualSustain = new VirtualSustain(-9999, -9999, 0, 0);

	// ==================================================================
	// RENDER BLOCK + AMBIENT NOTE OCCLUSION (v3.9.0 — the GTFR arena walk)
	//
	// Note behavior (processNotes) and rendering are decoupled: the
	// behavior pass counts and judges EVERY note on its own timing, and
	// the ambient occlusion — the overlap folding that merges notes
	// rendering on the same pixel row into one sprite — lives HERE, in
	// this render block, purely visually. The walk reads the chart
	// extern's packed arena straight off the RAW POINTER (zero FFI per
	// field: one Pointer.fromRaw per frame, then at() reads), sorts by
	// (lane, index) column and row, and consecutive packed slots of one
	// column on the same linear scroll row with the same type and
	// duration fold into the first one's sprite: the head accumulates
	// their alpha as occlusion shading and every folded note skips its
	// own pooled element — the sprite-count win the AO look was built
	// for. Gameplay is untouched by the folding: each folded note still
	// judges, hits, misses and counts on its own timing, so combo
	// counting stays 100% accurate.
	//
	// Packed slot layout (10 words; the chart note's own two words are
	// embedded verbatim at w4/w5 — the compression idiom):
	//   w0: diff(32) | Sx(16) | notesInOne(8) | sustainExists | judged
	//       | hitFlag | lane(3)     w1: globalIndex (-1 = free)
	//   w2: initialAlphaF(32) | addedAlphaF(32)
	//   w3: scaleF(32) | Sy(32)    w4: chart first8   w5: chart last4
	// ==================================================================
	function renderVirtualNotes(pos:Int64) {
		var downScroll = parent.downScroll;
		var scrollSpeed = _cachedScrollSpeed;

		// The frame's raw pointers (one fromRaw per frame, zero FFI per
		// field read). The walk reads packed words straight off them.
		_noteArena = Pointer.fromRaw(File.GTFR_NOTE_DATA());
		_sustainArena = Pointer.fromRaw(File.GTFR_SUSTAIN_DATA());

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			var maxReceptor = strumline.receptors.length;
			for (j in 0...maxReceptor) {
				var receptor = strumline.receptors[j];
				var strumReceptor = receptor.note;

				// Lane-constant values hoisted from inner loop
				var mania = strumline.length;
				var baseScrollDir = strumReceptor.scrollDirection;
				if (downScroll)
					baseScrollDir += 180;

				// AO group state for this column's walk (chain order is
				// bind order = chart order, so consecutive chain slots are
				// consecutive notes of the column — the fold's chain).
				var headActive = false;
				var headNote:Note = null;
				var headRow:Float = 0;
				var headType = -1;
				var headDuration = -1;
				var noteToHitIdx = receptor.noteToHit_index;
				var hitSprite:Note = null;

				var slot = File.GTFR_COLUMN_HEAD(i, j);
				while (slot >= 0) {
					var sw = slot * 10;
					var w0 = _noteArena.at(sw);
					var w1 = _noteArena.at(sw + 1);
					var w2 = _noteArena.at(sw + 2);
					var w3 = _noteArena.at(sw + 3);
					var w4 = _noteArena.at(sw + 4);
					var w5 = _noteArena.at(sw + 5);

					var gidx = w1;
					var chartPos = w4 & 0x0000FFFFFFFFFFFF;
					var chartLast4 = w5.low;
					var noteType = (chartLast4 >>> 18) & 0xFF;
					var duration = ((w4.high) & 0xFFFF) | ((chartLast4 & 0xFF) << 16);
					var sustainExists = ((w0.low >>> 25) & 1) != 0;

					var row = Math.floor(MetaNote.metaNotePositionToSongTime(chartPos - pos) * scrollSpeed);

					// === AMBIENT OCCLUSION (render-side folding) ===
					if (headActive
						&& row == headRow
						&& noteType == headType
						&& duration == headDuration) {
						// Fold into the head sprite: accumulate the
						// occlusion shading and skip this note's own
						// pooled element entirely.
						if (headNote != null)
							headNote.addedAlpha = Math.min(headNote.addedAlpha + Float.int32ToFloat(w2.low), 256);
						// A folded note can still be the receptor's
						// noteToHit (the earliest un-judged note) — its
						// visual IS the head sprite.
						if (noteToHitIdx == gidx)
							hitSprite = headNote;
					} else {
						headActive = true;
						headRow = row;
						headType = noteType;
						headDuration = duration;

						var handle = typeToHandle[noteType];
						var note = renderPool.acquireNote();

						if (note.handle != handle || note.texUnit != handle.texUnit || note.texSlot != handle.texSlot)
							note.setHandle(handle);
						note.x = (w0.low >>> 16) & 0xFFFF;
						note.y = w3.high;
						note.scale = Float.int32ToFloat(w3.low);
						note.initialAlpha = Float.int32ToFloat(w2.low);
						note.addedAlpha = Float.int32ToFloat(w2.high);

						note.mania_for_clipruntimehelper = mania;
						note.diff = -w0.low;
						note.scrollDirection = baseScrollDir;

						note.changeID(j);
						note.toNote();

						headNote = note;
						if (noteToHitIdx == gidx)
							hitSprite = note;

						// === SUSTAIN (the note slot's word9 links its
						// sustain slot — one acquire, no lookup) ===
						if (sustainExists) {
							var sSlot = Int64.toInt(_noteArena.at(sw + 9));
							if (sSlot >= 0 && _sustainArena != null) {
								var ssw = sSlot * 6;
								var sw0 = _sustainArena.at(ssw);
								var sw1 = _sustainArena.at(ssw + 1);
								var sw2 = _sustainArena.at(ssw + 2);
								var sw3 = _sustainArena.at(ssw + 3);
								var sustain = renderPool.acquireSustain();
								var sHandle = typeToHandle[noteType];
								if (sustain.handle != sHandle || sustain.texUnit != sHandle.texUnit || sustain.texSlot != sHandle.texSlot)
									sustain.setHandle(sHandle);
								sustain.x = (sw0.low >>> 16) & 0xFFFF;
								sustain.y = (sw0.low >>> 48) & 0xFFFF;
								sustain.w = sw1.low;
								sustain.speed = Float.int32ToFloat(sw2.high);
								sustain.scale = Float.int32ToFloat(sw3.low);
								sustain.mania_for_clipruntimehelper = mania;
								sustain.length = sw1.high;
								sustain.c.aF = Float.int32ToFloat(sw2.low);
								sustain.c.luminanceF = Float.int32ToFloat(sw2.low);
								sustain.diff = -sw0.low;
								sustain.scrollDirection = baseScrollDir;
								sustain.changeID(j);
							}
						}
					}

					slot = File.GTFR_SLOT_NEXT(slot);
				}
				receptor.noteToHit_sprite = hitSprite;
			}
		}
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
	function computeDynamicHoldThreshold(currentNote:MetaNote, _id:Int64, baseThreshold:Float, sustainDuration:Float = 0):Float {
		var len = File.getLength();
		var nextId = _id + 1;

		// No next note — nothing to scale against, use the full base threshold.
		if (nextId >= len)
			return baseThreshold;

		var nextNote = File.getNote(nextId);

		// Time gap (ms) between the start of this note and the start of the next.
		var timeGapMs = MetaNote.metaNotePositionToSongTime(nextNote.position - currentNote.position);

		// For sustain notes, the receptor is held for `sustainDuration` ms first,
		// so the time available for the *post-hold* threshold is reduced.
		var availableTime = timeGapMs - sustainDuration;

		// Chords / overlapping notes — no room to hold; collapse to the minimum.
		if (availableTime <= 0)
			return NOTE_HOLD_THRESHOLD_MIN;

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
		var dynamicThreshold = baseThreshold - (baseThreshold - NOTE_HOLD_THRESHOLD_MIN) * proximity;

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
				var maxThreshold = Math.max(NOTE_HOLD_THRESHOLD_MIN, sameLaneAvailableTime - NOTE_HOLD_RESET_BUFFER);
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

	function findPlayerHitNote(strumline:Strumline, index:Int):Int64 {
		var spawner = noteSpawner;
		if (spawner == null)
			return -1;

		var lane = strumlines.indexOf(strumline);
		if (lane < 0)
			return -1;

		var laneCount = strumlines.length;
		var hitbox = _cachedHitbox;
		// pos is already latency-corrected noteTime as Int64 from PlayField.update()
		var posWithLatency = MetaNote.floatToMetaNotePosition(parent.songPosition);
		// Precompute the hit window in tick units once, so the expansion needs
		// only cheap Int64 compares - no per-note Int64/float conversions.
		// (diff == (position - playhead) / TICKS_PER_MS, so
		// |diff| <= hitbox <=> late <= position <= early.)
		var halfTicks = MetaNote.floatToMetaNotePosition(hitbox);
		var late = Int64.sub(posWithLatency, halfTicks);
		var early = Int64.add(posWithLatency, halfTicks);

		// Binary search the first index whose note position is >= `target`.
		// Notes are position-sorted, so this is a safe monotonic search.
		inline function lowerBoundPos(lo:Int64, hi:Int64, target:Int64):Int64 {
			var l = lo;
			var h = hi;
			while (l < h) {
				var mid:Int64 = Int64.add(l, Int64.div(Int64.sub(h, l), 2));
				if (File.getNote(mid).position < target)
					l = Int64.add(mid, 1);
				else
					h = mid;
			}
			return l;
		}

		// Anchor on the first note at or after the playhead.
		var p = lowerBoundPos(spawner.bottom, spawner.top, posWithLatency);
		// If every note is in the past, anchor the backward scan on the last one.
		var bi = p;
		if (bi >= spawner.top)
			bi = Int64.sub(spawner.top, 1);

		var bestId:Int64 = -1;
		var found = false;

		inline function consider(i:Int64) {
			var n = File.getNote(i);
			// Window guard: a loop only breaks on its near side, so check the
			// far side here (at most the anchor note can be far-future).
			if (n.position < late || n.position > early)
				return;
			if (n.index == index && clampLane(n.lane, laneCount) == lane && !File.getJudgement(i)) {
				// Among hittable notes keep the earliest (smallest position) so a
				// jack progresses in order; once `found`, only a smaller index can
				// replace it.
				if (!found || i < bestId) {
					found = true;
					bestId = i;
				}
			}
		}

		// Backward: notes at or just before the playhead (already somewhat late).
		var i = bi;
		while (i >= spawner.bottom) {
			if (File.getNote(i).position < late)
				break;
			consider(i);
			i = Int64.sub(i, 1);
		}

		// Forward: upcoming notes within the hit window.
		i = Int64.add(p, 1);
		while (i < spawner.top) {
			if (File.getNote(i).position > early)
				break;
			consider(i);
			i = Int64.add(i, 1);
		}

		return bestId;
	}

	function drawNote(pos:Int64, note:MetaNote, diff:Float, _id:Int64):VirtualNote {
		var index = note.index;
		var duration = note.duration;
		var position = note.position;

		// The lane is STORED on the note (v2 format) — no more deriving
		// it from the notetype routing table at every draw.
		var lane = clampLane(note.lane, strumlines.length);

		var strumline = strumlines[lane];
		var receptor = strumline.receptors[index];
		var rec = receptor.note;

		// The scratch pair (one pair per NoteSystem, reused every note
		// of every frame — see NoteVB.hx's v3.9.0 comment): the behavior
		// pass fills them below, and the GTFR binds at the end pack the
		// values into the chart extern's arena. No pool, no per-note
		// allocation, no boxing.
		var noteSpr = drawScratchNote;
		var sustainSpr = duration != 0 ? drawScratchSustain : null;
		var sustainExists = duration != 0;
		// Per-note scratch reset (the state the old pool's getNote/getSustain
		// used to hand back fresh — the scratch is otherwise shared).
		noteSpr.initialAlpha = Note.defaultAlpha;
		noteSpr.addedAlpha = 0;
		noteSpr.scale = 1;
		noteSpr.diff = 0;
		noteSpr.Sx = 0;
		noteSpr.Sy = 0;
		noteSpr.globalIndex = _id;
		if (sustainSpr != null) {
			sustainSpr.alpha = Sustain.defaultAlpha;
			sustainSpr.speed = 1;
			sustainSpr.scale = 1;
			sustainSpr.r = 0;
			sustainSpr.diff = 0;
			sustainSpr.w = 0;
			sustainSpr.length = 0;
			sustainSpr.ref = noteSpr;
		}

		// === PLAYFIELD EDITOR: pure render, zero gameplay ===
		// In playfieldEditorMode notes never hit, never miss, never judge:
		// no File.setJudgement/setHitFlag writes, no onNoteHit/onNoteMiss/
		// onSustainComplete dispatches, no receptor confirm dance — the
		// notes are ONLY drawn, and sustains are drawn whole (no clipping,
		// no resolve, no completion). The editor owns songPosition, and
		// the chart is never mutated by the renderer — the only writes to
		// it come from the editor input.
		if (parent.playfieldEditorMode) {
			var d = Std.int(-diff);
			if (parent.downScroll)
				d = -d;
			noteSpr.diff = d;
			noteSpr.globalIndex = _id;

			var lut = movementLUTs[lane][index];
			noteSpr.Sx = rec.x + lut.lookupX(noteSpr.diff);
			noteSpr.Sy = rec.y + lut.lookupY(noteSpr.diff);
			noteSpr.scale = lut.hasExtendedLUT ? lut.lookupScale(noteSpr.diff, rec.scale) * rec.scale : rec.scale;

			if (sustainSpr != null) {
				sustainSpr.ref = noteSpr;
				sustainSpr.speed = parent.scrollSpeed;
				sustainSpr.scale = rec.scale;
				sustainSpr.length = duration - SUSTAIN_TAIL;
				sustainSpr.w = duration - SUSTAIN_TAIL;
				sustainSpr.followNote(noteSpr.Sx + receptor.sustainPivotX, noteSpr.Sy + receptor.sustainPivotY, index);
				sustainSpr.diff = Std.int(diff);
				if (lut.hasExtendedLUT) {
					sustainSpr.r = lut.lookupSustainRot(d);
					var scrollMul = lut.lookupScrollMul(d);
					if (scrollMul != 1.0) {
						noteSpr.diff = Math.round(d * scrollMul);
						sustainSpr.w = Math.round(sustainSpr.w * scrollMul);
					}
				} else {
					noteMovement.run(this, noteSpr, sustainSpr, receptor, index, note.type, false);
				}
				File.GTFR_BIND_SUSTAIN(_id, sustainSpr.diff, sustainSpr.Sx, sustainSpr.Sy,
					sustainSpr.w, sustainSpr.length, sustainSpr.alpha, sustainSpr.speed,
					sustainSpr.scale, sustainSpr.r);
			} else if (!lut.hasExtendedLUT) {
				noteMovement.run(this, noteSpr, null, receptor, index, note.type, false);
			}

			File.GTFR_BIND_NOTE(_id, noteSpr.diff, noteSpr.Sx, noteSpr.Sy,
				noteSpr.initialAlpha, noteSpr.addedAlpha, noteSpr.scale, 1,
				sustainExists, false, false, lane);
			return noteSpr;
		}

		// Deferred: leftover is only needed for sustain notes.
		// Avoids MetaNote.metaNotePositionToSongTime() per-note for the majority case.
		var leftover:Int = 0;
		if (sustainExists)
			leftover = Std.int(MetaNote.metaNotePositionToSongTime(pos - position));

		// Judgement-gated state reads — the flat per-note bit, which lives
		// in the note's OWN shard: an in-RAM array allocated freshly zeroed
		// when the shard opens and destroyed when it closes (no manual
		// zero-out passes; a re-opened shard is automatically un-judged).
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
		// LUT lookup: precomputed offsets replace per-note Math.cos/Math.sin
		// With 2000 notes this eliminates 4000 trig calls/frame → 4000 L1-cache reads
		// When interp is baked in (hasExtendedLUT), scale/sustainRot/scrollMul are
		// applied inline here too — fully replacing the noteMovement.run() call.
		var lut = movementLUTs[lane][index];
		noteSpr.Sx = noteSprX + lut.lookupX(d);
		noteSpr.Sy = noteSprY + lut.lookupY(d);

		// Scale: when interp is baked, lookupScale returns a relative multiplier
		// (matching the Lua path: returnValue.scale * receptor.note.scale).
		// When no interp, lookupScale falls through to rec.scale directly.
		var lutExtended = lut.hasExtendedLUT;
		noteSpr.scale = lutExtended ? lut.lookupScale(d, rec.scale) * rec.scale : rec.scale;

		// Inline extended LUT: sustainRot + scrollMultiplier.
		// This eliminates the redundant noteMovement.run() call below when
		// the LUT already encodes the full formula output.
		if (lutExtended && sustainExists && sustainSpr != null) {
			sustainSpr.r = lut.lookupSustainRot(d);
			var scrollMul = lut.lookupScrollMul(d);
			if (scrollMul != 1.0) {
				noteSpr.diff = Math.round(d * scrollMul);
				sustainSpr.w = Math.round(sustainSpr.w * scrollMul);
			}
		}

		noteSpr.globalIndex = _id;

		var playable = strumline.playable && !(parent.botplay || RenderingMode.enabled);

		// --- Player side ---
		if (playable) {
			if (!isHit) {
				if (isMissed)
					noteSpr.initialAlpha = Note.defaultMissAlpha;

				if (!isMissed && diff < _cachedHitbox) {
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

				if (diff < -_cachedHitbox && !isMissed) {
					noteSpr.initialAlpha = Note.defaultMissAlpha;
					File.setHitFlag(_id, true); // chosen to miss
					isMissed = true;
					// Judged on the note's own flat shard bit — one note,
					// one judgement, one combo entry: every note of the
					// chart counts on its own timing.
					File.setJudgement(_id, true);

					var type = note.type;

					if (@:privateAccess parent.onNoteMiss.__listeners.length != 0)
						parent.onNoteMiss.dispatch(note);
					if (parent.field != null)
						parent.field.missNote(note);
					parent.missNote(note, _id);

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
				// Judged on the note's own flat shard bit — one note, one
				// judgement, one combo entry. This is the botplay path too
				// (botplay routes the player strumline through the opponent
				// branch): every note of a dense spam burst hits and counts
				// on its own timing, 100% accurate, while the RENDER block
				// folds their pixels into one visual note.
				File.setJudgement(_id, true);

				if (!rec.confirmed())
					rec.confirm();

				receptor.confirmTimer.startTime = parent.startedCountdown ? parent.noteTime : parent.songPosition; // Use noteTime directly — already latency-corrected by PlayField

				// Dynamic hold threshold: scans forward for the next same-receptor note
				// and shortens the confirm window the closer that note is in time, so
				// the receptor can visually reset before the next press instead of
				// holding across the gap.
				var baseThreshold = sustainExists ? NOTE_HOLD_THRESHOLD_SUSTAIN : NOTE_HOLD_THRESHOLD;
				var dynamicThreshold = computeDynamicHoldThreshold(note, _id, baseThreshold, sustainExists ? duration : 0);

				var confirmWindow = sustainExists ? duration + dynamicThreshold : dynamicThreshold;
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
					parent.onNoteHit.dispatch(note, 0);
				if (parent.field != null)
					parent.field.hitNote(note, 0);
				parent.hitNote(note, 0, _id);

				// Tiny sustains never register an ending in the sustain pass
				// below (see the 80ms gate), so finish them right here: after
				// the note-hit callbacks, fire the sustain-finish callbacks.
				if (sustainExists && duration <= 80) {
					receptor.sustainResolved = true;
					isResolved = true;
					if (@:privateAccess parent.onSustainComplete.__listeners.length != 0)
						parent.onSustainComplete.dispatch(note);
					if (parent.field != null)
						parent.field.completeSustain(note);
					parent.completeSustain(note, _id);
				}
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

			// Sustains of 80ms or less never register as ending: the completion
			// pass below would otherwise flip the receptor from its confirm
			// animation to the press animation the moment such a tiny sustain
			// finishes (the key is usually still held), which reads as a
			// ghost press. Only real sustains get an ending at all.
			var sustainCompleted = duration > 80 && pos > position + (MetaNote.floatToMetaNotePosition(sustainLength - SUSTAIN_TAIL_END));

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

		// When the LUT has extended data (interp baked in), scale/sustainRot/
		// scrollMul were already applied inline above — skip the redundant
		// noteMovement.run() call. This saves ~2000 method calls + array
		// traversals + followNote() calls per frame for 2000 notes.
		if (!lutExtended)
			noteMovement.run(this, noteSpr, sustainSpr, receptor, index, note.type, isHit);

		// The GTFR binds: the note always, the sustain when one exists.
		// The packed words carry this to the render walk (and the sustain
		// slot links off the note slot's word9).
		File.GTFR_BIND_NOTE(_id, noteSpr.diff, noteSpr.Sx, noteSpr.Sy,
			noteSpr.initialAlpha, noteSpr.addedAlpha, noteSpr.scale, 1,
			sustainExists, judged, isHit, lane);
		if (sustainExists && sustainSpr != null)
			File.GTFR_BIND_SUSTAIN(_id, sustainSpr.diff, sustainSpr.Sx, sustainSpr.Sy,
				sustainSpr.w, sustainSpr.length, sustainSpr.alpha, sustainSpr.speed,
				sustainSpr.scale, sustainSpr.r);

		return noteSpr;
	}

	var _cachedScrollSpeed:Float = 0;
	var _cachedHitbox:Float = 160;

	function setScrollSpeed(value:Float) {
		noteSpawner.spawnDist = MetaNote.floatToMetaNotePosition(1600 / value);
		noteSpawner.despawnDist = MetaNote.floatToMetaNotePosition(360 / Math.min(Math.max(value, 0.0001), 1.0));
		_cachedScrollSpeed = value;
		rebuildMovementLUTs();
		return value;
	}

	function resetStrumlines(resetAnims:Bool = true) {
		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			strumline.x = STRUMLINE_X_OFFSET + Std.int(Main.INITIAL_WIDTH * (i / strumlines.length)); // v3.7: same /count layout as the creation loop (Main.STRUMLINE_COUNT)
			strumline.y = parent.downScroll ? Main.INITIAL_HEIGHT - STRUMLINE_Y_OFFSET_DOWNSCROLL : STRUMLINE_Y_OFFSET;
			if (resetAnims)
				strumline.resetAnimations();
			strumline.resetInputs();
		}
		rebuildMovementLUTs();
	}

	/**
	 * Rebuild all movement LUTs.  Call when:
	 *   - scrollDirection changes (noteskin swap)
	 *   - strumlines are reconfigured (resize, reposition)
	 *   - scrollSpeed changes (if interp is active, results depend on it)
	 *   - A custom noteFormula is set or cleared
	 *
	 * When noteMovement.hasInterp is true, builds per-lane LUTs using
	 * buildWithInterp(), baking the full formula output (position, scale,
	 * sustainRot, scrollMultiplier) into the LUT at every quantized diff.
	 * This eliminates both the per-note trig calls AND the VM dispatch.
	 *
	 * When no interp is active, builds per-lane LUTs using build() for
	 * standard linear scroll, eliminating only the trig calls.
	 */
	function rebuildMovementLUTs() {
		if (movementLUTs == null)
			movementLUTs = [];

		var hasInterp = noteMovement != null && noteMovement.hasInterp;
		var interp = hasInterp ? noteMovement.interp : null;
		var scrollSpeed = parent.scrollSpeed;

		for (sl in 0...strumlines.length) {
			var strumline = strumlines[sl];
			var mania = strumline.length; // number of receptors/lanes

			// Ensure the inner array exists and is the right size
			if (sl >= movementLUTs.length)
				movementLUTs.push([]);
			var laneArr = movementLUTs[sl];
			if (laneArr == null) {
				laneArr = [];
				movementLUTs[sl] = laneArr;
			}

			for (ri in 0...mania) {
				var receptor = strumline.receptors[ri];
				var rec = receptor.note;

				if (hasInterp && interp != null) {
					// Bake the full noteFormula into the LUT
					if (ri < laneArr.length && laneArr[ri] != null) {
						laneArr[ri].buildWithInterp(interp, strumline.scrollDirection, scrollSpeed, rec.x, rec.y, rec.scale, ri, sl);
					} else {
						var lut = new NoteMovementLUT();
						lut.buildWithInterp(interp, strumline.scrollDirection, scrollSpeed, rec.x, rec.y, rec.scale, ri, sl);
						laneArr.push(lut);
					}
				} else {
					// Linear scroll LUT (no formula)
					if (ri < laneArr.length && laneArr[ri] != null) {
						laneArr[ri].build(strumline.scrollDirection);
					} else {
						var lut = new NoteMovementLUT();
						lut.build(strumline.scrollDirection);
						laneArr.push(lut);
					}
				}
			}

			// Trim excess per-lane LUTs if mania shrank
			while (laneArr.length > mania) {
				var old = laneArr.pop();
				if (old != null)
					old.dispose();
			}
		}

		// Trim excess strumline arrays
		while (movementLUTs.length > strumlines.length) {
			var oldArr = movementLUTs.pop();
			if (oldArr != null) {
				for (old in oldArr) {
					if (old != null)
						old.dispose();
				}
			}
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
		if (renderPool != null) {
			renderPool.dispose();
			renderPool = null;
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

		if (movementLUTs != null) {
			for (laneArr in movementLUTs) {
				if (laneArr != null) {
					for (lut in laneArr) {
						if (lut != null)
							lut.dispose();
					}
				}
			}
			movementLUTs = null;
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
