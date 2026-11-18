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
	* mouseUp    — LEFT: if the press was on a grid slot, the mouse didn't
	               drag beyond the slop, and the pressed slot is empty, a note
	               is added there via `File.addNote(position, duration, index,
	               type)`. The slot is the one captured at PRESS time — the
	               song keeps scrolling under a held cursor, but the click
	               lands where the user aimed. RIGHT: removes the note in the
	               hovered slot.
	* mouseWheel — shifts the song position forward or backward; holding
	               Ctrl accelerates the seek by 4x.

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

	/** Base seek per wheel notch, in ms (Ctrl multiplies by CTRL_SEEK_MULT). */
	static inline var WHEEL_SEEK_MS:Float = 250.0;

	/** Ctrl accelerates wheel seeking by this factor. */
	static inline var CTRL_SEEK_MULT:Float = 4.0;

	/** Side length of the square ghost graphic, in pixels (before strumline scale). */
	static inline var SQUARE_SIZE:Int = 40;

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
		return parent.startedCountdown ? parent.noteTime : parent.songPosition;
	}

	/**
		Display-local Y → song time (ms). Mirrors drawNote's LUT math exactly:
		  upscroll   Sy = rec.y + (t - now) * speed
		  downscroll Sy = rec.y - (t - now) * speed
	*/
	function yToTimeMs(y:Float, receptorY:Float):Float {
		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;
		var d = y - receptorY;
		return parent.downScroll ? playheadMs() - d / scrollSpeed : playheadMs() + d / scrollSpeed;
	}

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
		var step = parent.editorSnapMs;
		if (step <= 0)
			return timeMs;
		return Math.round(timeMs / step) * step;
	}

	/**
		Detect the strumline + lane + snapped time hitbox under the cursor.
		Searches ALL strumlines by X (the editor can place notes on either
		side — type = strumline index, matching gameplay's type % count
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
		Binary search by position, then walk equal positions.
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

		detectHitbox(local.x, local.y);
		updateSquareVisual();
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
			downOnGrid = false;
			downLane = -1;
			downStrumline = -1;

			if (wasOnGrid && !moved && lane >= 0) {
				// Only add when the slot is empty ("hasn't appeared there yet").
				if (findNoteAt(lane, strumlineIdx, timeMs) < 0) {
					var id = File.addNote(MetaNote.floatToMetaNotePosition(timeMs), 0, lane, strumlineIdx);
					if (id >= 0) {
						Main.current.playScrollSound();
						parent.onChartEdited();
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
					parent.onChartEdited();
				}
			}
			updateSquareVisual();
		}
	}

	function mouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode) {
		if (parent.disposed || parent.paused)
			return;

		var notches = -Math.floor(deltaY);
		if (notches == 0)
			return;

		var seek = WHEEL_SEEK_MS * (ctrlPressed ? CTRL_SEEK_MULT : 1.0);
		parent.setTimeEditor(parent.songPosition + notches * seek);
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
			var note = strumline.receptors[lane].note;
			var anchor = strumline.receptors[0].note;
			var size = Std.int(SQUARE_SIZE * strumline.scale);
			var cx = note.x + note.w * strumline.scale * 0.5;
			var cy = timeToY(timeMs, anchor.y);

			square.w = size;
			square.h = size;
			square.x = Std.int(cx - size * 0.5);
			square.y = Std.int(cy - size * 0.5);

			// Red = occupied (right-click removes), green = empty (click adds).
			var occupied = showHeld ? findNoteAt(lane, strumlineIdx, timeMs) >= 0 : hoverOccupied;
			square.c = occupied ? 0xFF0000FF : 0x00FF00FF;
			square.c.aF = showHeld ? 0.18 : 0.35; // darkened while held
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
