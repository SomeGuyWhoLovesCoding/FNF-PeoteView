package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseCursor;
import lime.ui.MouseWheelMode;

/**
	The playfield editor's dedicated mouse input system.
	Owns the four mouse events — mouseMove, mouseDown, mouseUp, mouseWheel —
	and the square "ghost note" graphic that snaps over the strumline lanes.

	* mouseMove  — detects which strumline / lane / time-step hitbox the
	               cursor is over and moves the ghost square there. When the
	               snapped slot already holds a note, the square turns red
	               (right-click removes); otherwise it is green (click adds).
	* mouseDown  — darkens the square temporarily while the button is held.
	               Pressing an EXISTING note enters hold-edit mode instead of
	               an add-click: the note's sustain can then be adjusted with
	               the wheel (± one snap step per notch) or by dragging the
	               cursor along the lane (the sustain end follows the cursor,
	               snapped to the grid; the note's position never moves).
	* mouseUp    — LEFT: a plain press on an empty slot (no drag beyond the
	               slop) adds a note there via `File.addNote(position, 0,
	               lane, editorMode.notetype)` — the notetype comes from the
	               editor's ALT+LEFT/RIGHT selector. A hold-edit press keeps
	               the note with whatever duration was dialed in (every wheel
	               notch / drag step was already written to the chart).
	               RIGHT: removes the note in the hovered slot.
	* mouseWheel — shifts the song position forward or backward (Ctrl = 4x);
	               while hold-editing it edits the sustain length instead.

	The song position in editor mode is frozen by design (see
	PlayFieldEditorMode / Mixer.update): it moves ONLY on explicit seeks,
	so "the song scrolls under a held cursor" can no longer happen while
	silent — the pressed-slot capture is kept for the audible case.

	This class is deliberately self-contained: the playfield editor (the
	playfieldEditorMode branch of PlayField) creates it, updates it once per
	frame, and renders its square on top of the note system render. It never
	touches the gameplay InputSystem (which is not instantiated at all in
	editor mode).
	@since Development
**/
@:publicFields
class StrumlineNoteInteraction {
	/** Pixels the mouse may drift (mouse-down → mouse-up) for a click to count. */
	static inline var CLICK_SLOP:Float = 8.0;

	/** Base seek per wheel notch, in ms (Ctrl multiplies by CTRL_SEEK_MULT). Halved from 250 — the old step felt too coarse. */
	static inline var WHEEL_SEEK_MS:Float = 125.0;

	/** Ctrl accelerates wheel seeking by this factor. */
	static inline var CTRL_SEEK_MULT:Float = 4.0;

	/** Side length of the square ghost graphic, in pixels (before strumline scale). */
	static inline var SQUARE_SIZE:Int = 40;

	/** Minimum sustain duration (ms) the editor will write — shorter is a tap. */
	static inline var MIN_SUSTAIN_MS:Float = 0.0;

	var parent(default, null):PlayField;

	// --- Event bookkeeping ---
	var isDown:Bool = false;
	var downX:Float = 0;
	var downY:Float = 0;
	var moved:Bool = false;
	/** Slot captured at press time — the click target, immune to song scroll. */
	var downOnGrid:Bool = false;
	var downLane:Int = -1;
	var downStrumline:Int = -1;
	var downTimeMs:Float = 0;
	/** Chart index of the note captured at press time; -1 = pressed an empty slot. */
	var downNoteId:Int64 = -1;

	// --- Hold-note sustain editing (LMB held on an existing note) ---
	/** True while LMB is held on a note, editing its sustain via wheel/drag. */
	var holdEditing:Bool = false;
	/** Live sustain duration (ms) while hold-editing — written to the chart on change. */
	var holdDurationMs:Float = 0;

	// --- Hover state (from mouseMove; refreshed per frame) ---
	var hoverX:Float = 0;
	var hoverY:Float = 0;
	var hoverLane:Int = -1;
	var hoverStrumline:Int = -1;
	var hoverTimeMs:Float = 0;
	var hoverOccupied:Bool = false;
	var ctrlPressed:Bool = false;

	// --- Ghost square element (plain colored square, NoteskinEditor-popup style) ---
	var square:RepeatSprite;
	var squareBuf:Buffer<RepeatSprite>;
	var squareProg:CustomProgram;

	var display(default, null):CustomDisplay;

	var eventsActive(default, null):Bool = false;

	function new(parent:PlayField) {
		this.parent = parent;
		display = parent.display;

		squareBuf = new Buffer<RepeatSprite>(2, 2, true);
		squareProg = new CustomProgram(squareBuf);
		square = new RepeatSprite(0, 0, SQUARE_SIZE, SQUARE_SIZE);
		square.c = 0x00FF00FF; // green = add (red = occupied)
		square.c.aF = 0.35;
		square.r = 45; // diamond orientation over the lane
	}

	function addEvents() {
		if (eventsActive || parent.disposed)
			return;
		eventsActive = true;
		#if !android
		var window = Application.current.window;
		window.onKeyDown.add(keyDown);
		window.onKeyUp.add(keyUp);
		window.onMouseMove.add(mouseMove);
		window.onMouseDown.add(mouseDown);
		window.onMouseUp.add(mouseUp);
		window.onMouseWheel.add(mouseWheel);
		#end
	}

	function removeEvents() {
		if (!eventsActive)
			return;
		eventsActive = false;
		#if !android
		var window = Application.current.window;
		window.onKeyDown.remove(keyDown);
		window.onKeyUp.remove(keyUp);
		window.onMouseMove.remove(mouseMove);
		window.onMouseDown.remove(mouseDown);
		window.onMouseUp.remove(mouseUp);
		window.onMouseWheel.remove(mouseWheel);
		#end
	}

	function keyDown(code:KeyCode, mod:KeyModifier) {
		if ((mod & KeyModifier.CTRL) != 0)
			ctrlPressed = true;
	}

	function keyUp(code:KeyCode, mod:KeyModifier) {
		if ((mod & KeyModifier.CTRL) == 0)
			ctrlPressed = false;
	}

	// ==================================================================
	// Coordinate mapping
	// ==================================================================

	/** Window mouse coords → display-local (playfield) coords. */
	inline function toLocal(x:Float, y:Float):{x:Float, y:Float} {
		var peoteView = Main.current.peoteView;
		return {x: display.localX(x, peoteView), y: display.localY(y, peoteView)};
	}

	inline function playheadMs():Float {
		// Editor mode always runs on its own songPosition (startedCountdown
		// is false there); the noteTime split is the latency-corrected
		// gameplay path.
		return parent.playfieldEditorMode || !parent.startedCountdown ? parent.songPosition : parent.noteTime;
	}

	/**
		Display-local Y → song time (ms). LUT-exact inverse of how notes
		actually draw: binary-searches the lane's movement LUT for the
		diff whose drawn note CENTER is at `y`, then converts diff → time.
		The old linear inverse disagreed with the LUT (and with the
		diamond square, which is centered on the drawn note) whenever the
		noteskin used a non-linear formula — the cursor's slot felt
		"sensitive"/off-center relative to the square.
		Returns the LINEAR fallback when the LUT is unavailable.
	**/
	function yToTimeMs(y:Float, receptorY:Float):Float {
		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;

		// Linear fallback (and the fast path when no LUT context yet).
		var d = y - receptorY;
		var linear = parent.downScroll ? playheadMs() - d / scrollSpeed : playheadMs() + d / scrollSpeed;

		if (lutCtx == null)
			return linear;

		// The drawn note's center Y at diff value q: the square/notes ride
		// the LUT; the center is half the drawn size below the drawn top.
		function centerYAtDiff(q:Int):Float {
			var scale = lutCtx.hasExtendedLUT ? lutCtx.lookupScale(q, lutCtxScale) * lutCtxScale : lutCtxScale;
			return lutCtxNoteY + lutCtx.lookupY(q) + (lutCtxNoteH * scale) * 0.5;
		}

		// Binary search over diff. The LUT is built from the strumline's
		// scrollDirection (-90 upscroll: sin = -1, Y falls as diff grows);
		// downscroll flips the DIFF sign, not the LUT — so centerY(q) is
		// monotonic DECREASING in q in both scroll modes.
		// (No nullable Int: cpp/hl are static platforms — track found
		// with a flag and clamp the bracket instead.)
		var lo = lutCtx.minDiff;
		var hi = lutCtx.maxDiff;
		var found = false;
		var bestQ = lo;

		while (lo <= hi) {
			var mid = (lo + hi) >> 1;
			var cy = centerYAtDiff(mid);
			if (cy > y) {
				// note center still below cursor -> need larger q (higher Y)
				lo = mid + 1;
				bestQ = mid;
			} else {
				hi = mid - 1;
				bestQ = mid;
			}
			found = true;
		}

		if (!found)
			return linear;

		// diff → time: drawNote computes d = -(t - now) * speed, negated
		// again for downscroll. Invert the same way.
		var t = playheadMs() - bestQ / scrollSpeed;
		if (parent.downScroll)
			t = playheadMs() + bestQ / scrollSpeed;
		return t;
	}

	// --- LUT context for yToTimeMs (set by detectHitbox each call) ---
	var lutCtx:NoteMovementLUT = null;
	var lutCtxNoteY:Float = 0;
	var lutCtxNoteH:Float = 0;
	var lutCtxScale:Float = 1;

	/** Song time (ms) → display-local Y (inverse of yToTimeMs). */
	function timeToY(timeMs:Float, receptorY:Float):Float {
		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;
		var d = (timeMs - playheadMs()) * scrollSpeed;
		return parent.downScroll ? receptorY - d : receptorY + d;
	}

	/** Snap a song time (ms) to the editor step grid. */
	inline function snapTime(timeMs:Float):Float {
		var step = parent.editorMode.snapMs;
		if (step <= 0)
			return timeMs;
		return Math.round(timeMs / step) * step;
	}

	/**
		Detect the strumline + lane + snapped time hitbox under the cursor.
		Searches ALL strumlines by X (the editor can place notes on either
		side — the placed note's type comes from editorMode.notetype, whose
		`type % strumlineCount` picks the strumline, matching gameplay's
		mapping). Returns true when the cursor is over a receptor column.
	*/
	function detectHitbox(x:Float, y:Float):Bool {
		hoverLane = -1;
		hoverStrumline = -1;
		hoverTimeMs = 0;
		hoverOccupied = false;

		var noteSystem = parent.noteSystem;
		if (noteSystem == null)
			return false;
		var strumlines = noteSystem.strumlines;
		if (strumlines.length == 0)
			return false;

		for (si in 0...strumlines.length) {
			var strumline = strumlines[si];
			if (strumline.length == 0)
				continue;
			// Any receptor works for the Y anchor — they share the row.
			var anchor = strumline.receptors[0].note;
			for (li in 0...strumline.length) {
				var note = strumline.receptors[li].note;
				var halfW = (note.w * strumline.scale) * 0.5 + SQUARE_SIZE * 0.25;
				var cx = note.x + note.w * strumline.scale * 0.5;
				if (x >= cx - halfW && x <= cx + halfW) {
					hoverLane = li;
					hoverStrumline = si;
					// Feed yToTimeMs the LUT context of THIS lane so its
					// inverse is exact for how notes draw here (the square
					// is centered on the drawn note; the hitbox now agrees
					// with it instead of the old linear approximation).
					var luts = noteSystem.movementLUTs;
					if (luts != null && si < luts.length && li < luts[si].length) {
						lutCtx = luts[si][li];
						lutCtxNoteY = note.y;
						lutCtxNoteH = note.h;
						lutCtxScale = note.scale;
					} else {
						lutCtx = null;
					}
					hoverTimeMs = snapTime(yToTimeMs(y, anchor.y));
					hoverOccupied = findNoteAt(li, si, hoverTimeMs) >= 0;
					return true;
				}
			}
		}
		return false;
	}

	/**
		Find an existing note at the given lane/strumline/snapped time.
		Binary search by position, then walk equal positions. A note at the
		same time+lane with a DIFFERENT notetype also counts — hold-editing
		any of them is the same gesture (the type is preserved per-note on
		the duration rewrite).
	*/
	function findNoteAt(lane:Int, strumlineIdx:Int, timeMs:Float):Int64 {
		var len = File.getLength();
		if (len <= 0)
			return -1;

		var target = MetaNote.floatToMetaNotePosition(timeMs);
		var laneCount = parent.noteSystem.strumlines.length;

		var lo:Int64 = 0, hi:Int64 = len;
		while (lo < hi) {
			var mid:Int64 = (lo + hi) >> 1;
			if (File.getNote(mid).position < target)
				lo = mid + 1;
			else
				hi = mid;
		}

		var i = lo;
		while (i < len) {
			var n = File.getNote(i);
			if (n.position != target)
				break;
			if (n.index == lane && (n.type % laneCount) == strumlineIdx)
				return i;
			i++;
		}
		return -1;
	}

	// ==================================================================
	// The four mouse events
	// ==================================================================

	function mouseMove(x:Float, y:Float) {
		if (parent.disposed || parent.paused)
			return;

		var local = toLocal(x, y);
		hoverX = local.x;
		hoverY = local.y;

		if (isDown) {
			if (Math.abs(local.x - downX) > CLICK_SLOP || Math.abs(local.y - downY) > CLICK_SLOP)
				moved = true;
		}

		// Hold-edit drag: while LMB is held on a note, the cursor's lane
		// position (snapped to the grid, relative to the note's fixed
		// position) directly sets the sustain length. Dragging above the
		// note (upscroll) shortens toward a tap; dragging below lengthens.
		if (holdEditing && downNoteId >= 0) {
			updateHoldFromCursor(local.y);
			return;
		}

		detectHitbox(local.x, local.y);
		updateSquareVisual();
	}

	/**
		Hold-edit helper: set the edited note's sustain so it ends at the
		cursor's current (snapped) song time. The note's own position stays
		fixed — only the duration changes.
	*/
	function updateHoldFromCursor(y:Float) {
		var strumlines = parent.noteSystem.strumlines;
		if (downStrumline < 0 || downStrumline >= strumlines.length)
			return;
		var strumline = strumlines[downStrumline];
		if (strumline.length == 0)
			return;
		var anchor = strumline.receptors[0].note;

		var cursorMs = yToTimeMs(y, anchor.y);
		var noteMs = downTimeMs;
		// Upscroll: the sustain extends DOWN the screen (later times are
		// lower); downscroll mirrors that. Either way "cursor below the
		// note head" = longer sustain — clamp to a tap when inverted.
		var endMs = snapTime(cursorMs);
		var dur = endMs - noteMs;
		if (dur < MIN_SUSTAIN_MS)
			dur = MIN_SUSTAIN_MS;
		setHoldDuration(dur);
	}

	/**
		Writes `dur` (ms) as the hold-edited note's sustain duration. The
		chart stores duration in 1 ms ticks (16-bit field, max 65535 ms),
		snapped to whole grid steps. The note is removed and re-added at
		the same position with the new duration (the chart has no in-place
		edit), which keeps its slot in the sorted order.
	*/
	function setHoldDuration(dur:Float) {
		if (downNoteId < 0)
			return;

		var step = parent.editorMode.snapMs;
		if (step > 0)
			dur = Math.round(dur / step) * step;
		if (dur < MIN_SUSTAIN_MS)
			dur = MIN_SUSTAIN_MS;
		if (dur > 65535)
			dur = 65535; // the chart's 16-bit duration field
		if (dur == holdDurationMs)
			return; // no change — don't churn the chart

		var old = File.getNote(downNoteId);
		if (old == null)
			return;
		var position = old.position;
		var index = old.index;
		var type = old.type;

		File.removeNote(downNoteId);
		downNoteId = File.addNote(position, Std.int(dur), index, type);
		if (downNoteId < 0)
			return; // write failed — stop editing

		holdDurationMs = dur;
		parent.editorMode.onChartEdited();
	}

	function mouseDown(x:Float, y:Float, button:MouseButton) {
		if (parent.disposed || parent.paused)
			return;

		var local = toLocal(x, y);
		if (button == MouseButton.LEFT) {
			isDown = true;
			moved = false;
			downX = local.x;
			downY = local.y;
			// Capture the slot NOW — the click target stays fixed even as
			// the song scrolls under a held cursor.
			downOnGrid = detectHitbox(local.x, local.y);
			downLane = hoverLane;
			downStrumline = hoverStrumline;
			downTimeMs = hoverTimeMs;
			// Pressing an EXISTING note enters hold-edit mode: the sustain
			// can now be adjusted with the wheel or by dragging. Pressing
			// an empty slot stays a plain add-click.
			downNoteId = downOnGrid ? findNoteAt(downLane, downStrumline, downTimeMs) : -1;
			holdEditing = downNoteId >= 0;
			// note.duration is already in ms (the chart's duration unit).
			holdDurationMs = downNoteId >= 0 ? File.getNote(downNoteId).duration : 0;
			updateSquareVisual(); // darken while held
		}
	}

	function mouseUp(x:Float, y:Float, button:MouseButton) {
		if (parent.disposed || parent.paused)
			return;

		if (button == MouseButton.LEFT) {
			if (!isDown)
				return;
			isDown = false;

			var wasOnGrid = downOnGrid;
			var lane = downLane;
			var strumlineIdx = downStrumline;
			var timeMs = downTimeMs;
			var wasHoldEdit = holdEditing;
			var heldDur = holdDurationMs;
			var noteId = downNoteId;
			downOnGrid = false;
			downLane = -1;
			downStrumline = -1;
			downNoteId = -1;
			holdEditing = false;

			// A hold-edit release that never dragged and never wheeled is
			// just a click on an existing note — nothing to add, nothing to
			// remove; the (possibly wheel-adjusted) duration was already
			// written through setHoldDuration.
			if (wasHoldEdit)
				heldNoopRelease(noteId, heldDur);
			else if (wasOnGrid && !moved && lane >= 0) {
				// Only add when the slot is empty ("hasn't appeared there yet").
				if (findNoteAt(lane, strumlineIdx, timeMs) < 0) {
					var id = File.addNote(MetaNote.floatToMetaNotePosition(timeMs), 0, lane, parent.editorMode.notetype);
					if (id >= 0) {
						Main.current.playScrollSound();
						parent.editorMode.onChartEdited();
					}
				}
			}

			// Re-detect for the release position's visual state.
			var local = toLocal(x, y);
			detectHitbox(local.x, local.y);
			updateSquareVisual();
			return;
		}

		if (button == MouseButton.RIGHT) {
			var local = toLocal(x, y);
			if (detectHitbox(local.x, local.y) && hoverLane >= 0) {
				var id = findNoteAt(hoverLane, hoverStrumline, hoverTimeMs);
				if (id >= 0) {
					File.removeNote(id);
					Main.current.playScrollSound();
					parent.editorMode.onChartEdited();
				}
			}
			updateSquareVisual();
		}
	}

	/** Hold-edit release. Nothing to do beyond clearing state — the chart
	 *  already holds every wheel/drag write. Kept as a named hook so the
	 *  release path reads clearly. */
	function heldNoopRelease(noteId:Int64, finalDuration:Float) {
		// The note keeps its (possibly modified) duration. A tap-length
		// hold-edit (duration 0) stays a tap note — exactly what the user
		// dialed in.
	}

	function mouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode) {
		if (parent.disposed || parent.paused)
			return;

		var notches = -Math.floor(deltaY);
		if (notches == 0)
			return;

		// While hold-editing, the wheel edits the sustain length instead of
		// seeking: each notch adds/removes one snap step of duration.
		if (holdEditing && downNoteId >= 0) {
			setHoldDuration(holdDurationMs + notches * parent.editorMode.snapMs);
			return;
		}

		var seek = WHEEL_SEEK_MS * (ctrlPressed ? CTRL_SEEK_MULT : 1.0);
		parent.editorMode.seekTo(parent.songPosition + notches * seek);
	}

	// ==================================================================
	// Ghost square visual
	// ==================================================================

	function updateSquareVisual() {
		if (square == null || parent.noteSystem == null)
			return;

		// While the button is held, the square stays glued to the pressed
		// slot (darkened); otherwise it follows the cursor's slot.
		var showHeld = isDown && downOnGrid && downLane >= 0;
		var lane = showHeld ? downLane : hoverLane;
		var strumlineIdx = showHeld ? downStrumline : hoverStrumline;
		var timeMs = showHeld ? downTimeMs : hoverTimeMs;

		if (lane < 0 || strumlineIdx < 0) {
			square.w = 0;
			square.h = 0;
		} else {
			var strumlines = parent.noteSystem.strumlines;
			if (strumlineIdx >= strumlines.length)
				return;
			var strumline = strumlines[strumlineIdx];
			if (lane >= strumline.length)
				return;
			var receptor = strumline.receptors[lane];
			var note = receptor.note;
			var size = Std.int(SQUARE_SIZE * strumline.scale);

			// The center of the note as it actually DRAWS, via the exact
			// same path drawNote uses: receptor origin + movement-LUT
			// offset at this diff (the LUT can be non-linear for fancy
			// noteskins — the old linear timeToY drifted off the note),
			// plus half the drawn size (a drawn note's y is its TOP, so
			// the true visual center sits half the sprite below it).
			// The square element is pivot-centered (px/py = w/2, h/2), so
			// placing x/y AT the note center puts the diamond's center
			// exactly on the note's center.
			var noteSystem = parent.noteSystem;
			var lut = noteSystem.movementLUTs[strumlineIdx][lane];
			if (lut == null)
				return;
			var scrollSpeed = parent.scrollSpeed;
			if (scrollSpeed <= 0)
				scrollSpeed = 1;
			// drawNote's exact diff convention: -(time - now) * speed,
			// negated again for downscroll.
			var d = -(timeMs - playheadMs()) * scrollSpeed;
			if (parent.downScroll)
				d = -d;
			var diff = Std.int(d);
			var drawX = note.x + lut.lookupX(diff);
			var drawY = note.y + lut.lookupY(diff);
			var drawScale = lut.hasExtendedLUT ? lut.lookupScale(diff, note.scale) * note.scale : note.scale;
			var drawW = note.w * drawScale;
			var drawH = note.h * drawScale;
			var cx = drawX + drawW * 0.5;
			var cy = drawY + drawH * 0.5;

			// Hold-editing: the square stretches along the lane to cover the
			// note head PLUS its live sustain length — a direct visual ruler
			// of the duration being dialed in (wheel notches / drag). The
			// head anchor is the note's real drawn top (LUT path); the tail
			// stretches from it at scroll speed, matching how the sustain
			// sprite itself follows and stretches from the head note.
			if (holdEditing && isDown) {
				var stretch = holdDurationMs * parent.scrollSpeed;
				var tailY = drawY + (parent.downScroll ? -stretch : stretch);
				var y0 = Std.int(Math.min(drawY, tailY));
				var y1 = Std.int(Math.max(drawY, tailY));
				var pad = size * 0.5;

				square.w = Std.int(size * 0.6);
				square.h = Std.int(Math.max(y1 - y0 + pad * 2, size));
				square.x = Std.int(cx - square.w * 0.5);
				square.y = y0 - Std.int(pad);
				square.c = 0x0080FFFF; // cyan = hold-edit (duration editing)
				square.c.aF = 0.25;
				square.r = 0; // axis-aligned ruler
			} else {
				// Square centered exactly on the note's visual center.
				square.w = size;
				square.h = size;
				square.x = Std.int(cx - size * 0.5);
				square.y = Std.int(cy - size * 0.5);
				square.r = 45; // diamond orientation over the lane

				// Red = occupied (right-click removes), green = empty (click adds).
				var occupied = showHeld ? findNoteAt(lane, strumlineIdx, timeMs) >= 0 : hoverOccupied;
				square.c = occupied ? 0xFF0000FF : 0x00FF00FF;
				square.c.aF = showHeld ? 0.18 : 0.35; // darkened while held
			}
		}

		if (squareBuf != null) {
			try {
				squareBuf.updateElement(square);
				squareBuf.update();
			} catch (e) {}
		}
	}

	// ==================================================================
	// Frame update + attach/detach (called by the PlayField editor branch)
	// ==================================================================

	/**
		Per-frame refresh: the square must track the playhead even with a
		still cursor — notes scroll under it, changing slot occupancy.
	*/
	function update() {
		if (parent.disposed)
			return;
		// While hold-editing, skip hitbox re-detection — the edited note's
		// slot is frozen at press time and the ruler square below reads
		// downTimeMs/holdDurationMs directly. Otherwise keep detecting so
		// occupancy colors track the (seekable) playhead.
		if (holdEditing) {
			updateSquareVisual();
			return;
		}
		if (hoverLane >= 0 || (isDown && downOnGrid))
			detectHitbox(hoverX, hoverY);
		updateSquareVisual();
	}

	/** Add the square's program AFTER notesProg so it renders on top; bind events. */
	function attach() {
		if (!squareProg.isIn(display))
			display.addProgram(squareProg);
		squareBuf.addElement(square);
		try {
			squareBuf.updateElement(square);
			squareBuf.update();
		} catch (e) {}
		addEvents();
		var window = Application.current.window;
		if (window != null)
			window.cursor = MouseCursor.ARROW;
	}

	function detach() {
		removeEvents();
		try {
			squareBuf.removeElement(square);
		} catch (e) {}
		if (squareProg.isIn(display))
			display.removeProgram(squareProg);
	}

	function dispose() {
		detach();
		square = null;
		if (squareBuf != null) {
			try
				squareBuf.clear()
			catch (e) {}
			squareBuf = null;
		}
		squareProg = null;
	}
}
