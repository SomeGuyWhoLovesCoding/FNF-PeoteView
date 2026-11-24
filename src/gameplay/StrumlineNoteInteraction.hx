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
	               While LMB is held on a note, the drag sets the sustain
	               length; while held on BACKGROUND, the drag PANS the chart
	               (the song position follows the cursor's Y slide).
	* mouseDown  — on an empty slot: adds the note immediately and enters
	               the hold-duration state (press-and-hold IS the placing
	               gesture — drag/wheel/UI-keys all dial the length from
	               there; release just ends it). On an existing note: the
	               same hold-duration state on that note, AND its type is
	               picked up into the editor's pen (the next placement
	               re-uses it; UP/DOWN retype the HELD note live).
	               On the event lane: adds/removes placeholder events. On
	               background: starts the pan gesture; a TRIPLE
	               background click/tap toggles the instructions popup.
	               SELECTION (v3.3): CTRL+press starts a MARQUEE band
	               (drag = rubber-band select, live; SHIFT adds to the
	               selection instead of replacing; an unmoved CTRL press
	               clears it), and SHIFT+press on a note toggles just
	               that note in/out of the selection.
	* mouseUp    — LEFT: ends the gesture — a hold-edit keeps the note
	               with whatever duration was dialed in (every wheel
	               notch / drag step was already written to the chart),
	               a pan release with motion flings, and ANY plain
	               unmoved click (no SHIFT/CTRL) clears the whole
	               SELECTION (v3.4: a click of either button deselects —
	               click-away is no longer background-only). RIGHT: a
	               v3.4 BATCH removal — every note in the hovered slot's
	               snap catchment goes at once (findNotesNear → one undo
	               command); a plain RMB elsewhere deselects too.
	* mouseWheel — shifts the song position forward or backward (Ctrl = 4x;
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

	/**
		False until the cursor moves ≥36px from the press point while
		hold-editing (the mouse-driven sustain edit dead zone — see
		mouseMove). Wheel edits bypass it entirely.
	**/
	var holdDragArmed:Bool = false;
	/** The dead zone radius in px (squared-compared against the press point). */
	static inline var HOLD_DRAG_THRESHOLD_PX:Float = 36;

	// --- Background drag-pan (R3): hold LMB on empty background + slide = shift the song position ---
	/**
		True while LMB is held on BACKGROUND (not a lane slot, not the
		event lane) and the gesture is a pan. Vertical slide shifts the
		song position live: dragging UP moves the chart forward in time
		(downscroll-mirrored), so the notes track the cursor exactly.
	**/
	var panning:Bool = false;
	/** Playhead (ms) when the pan started — deltas apply against it. */
	var panStartPos:Float = 0;
	/** Cursor Y when the pan started — deltas apply against it. */
	var panStartY:Float = 0;

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
	/** True while SHIFT is held — scroll/pan intensity drops to 1/3. */
	var shiftPressed:Bool = false;

	// --- Background pan: intensity + Android-style fling falloff ---
	/**
		Pan intensity multiplier: 1 cursor px = this many px of chart
		travel. Tripled per request ("swiping intensity tripled") — the
		pan used to track the cursor 1:1; now one screen of drag covers
		three screens of chart.
	**/
	static inline var PAN_INTENSITY:Float = 3.0;
	/**
		Shift modifier for ALL editor scroll intensity (wheel seeks and
		background pan): 1/3 while held, per request.
	**/
	static inline var SHIFT_SCROLL_DIVISOR:Float = 3.0;
	/** Pan velocity (ms/frame at 60fps) captured at release — drives the fling. */
	var panVelocityMs:Float = 0;
	/** Last pan apply time (ms) — velocity is measured per wall-clock frame gap. */
	var panLastTimeMs:Float = 0;
	/** The pan fling's remaining travel (ms); decays per frame after release. */
	var panFlingMs:Float = 0;

	// --- Triple click/tap: opens the instructions popup (F1 alternative) ---
	/** Presses so far in the current triple-click streak. */
	var tripleClicks:Int = 0;
	/** Wall-clock ms of the last counted press. */
	var tripleLastMs:Float = 0;
	/** Window coords of the last counted press (slop check). */
	var tripleLastX:Float = 0;
	var tripleLastY:Float = 0;

	// --- Event lane: insertion column at the LEFT of the strumlines ---
	/** The event lane's element (a diamond icon, like the note ghost). */
	var eventGhost:RepeatSprite;
	/** Editor-side event list, mirrors EventSystem.EventObject's shape. */
	var editorEvents:Array<{name:String, value1:String, value2:String, time:Float}> = [];
	/** True while the cursor is over the event lane's column. */
	var hoverEventLane:Bool = false;
	/** Snapped time under the cursor while hovering the event lane. */
	var hoverEventTimeMs:Float = 0;
	/** Events loaded/saved flag — the list is lazily read from eventList.json on first use. */
	var eventsLoaded:Bool = false;
	/**
		The chart's folder (set by PlayFieldEditorMode.build from
		PlayField's private chartPath — same pass-in pattern as
		PlayFieldFrontEnd.build). The event lane's eventList.json lives
		there, next to the chart file EventSystem reads at runtime.
	**/
	var chartPath:String = "";

	/** Small markers for already-placed events along the lane (yellow diamonds). */
	var eventMarkerBuf:Buffer<RepeatSprite>;
	var eventMarkerProg:CustomProgram;
	/** Marker elements currently in the buffer (rebuilt on seek/edit). */
	var eventMarkers:Array<RepeatSprite> = [];

	/** X position (display-local) of the event lane's center — just left of the first strumline's receptors. */
	function eventLaneX():Float {
		var noteSystem = parent.noteSystem;
		if (noteSystem == null || noteSystem.strumlines.length == 0)
			return 0;
		var strumline = noteSystem.strumlines[0];
		if (strumline.length == 0 || strumline.receptors[0] == null)
			return 0;
		// Left of the leftmost receptor by ~1.5 note-widths; the lane's
		// own column width is one note.
		var note = strumline.receptors[0].note;
		var cx = note.x + note.w * strumline.scale * 0.5;
		return cx - note.w * strumline.scale * 1.5;
	}
	// --- Ghost square element (plain colored square, NoteskinEditor-popup style) ---
	var square:RepeatSprite;
	/** Red tail ruler for the hold-duration state: 2px thicker than the hold-note graphic, drawn over the (shortened) cyan ruler. */
	var holdTail:RepeatSprite;
	var squareBuf:Buffer<RepeatSprite>;
	var squareProg:CustomProgram;

	// -------------------------------------------------------------------
	// Real-time step/beat grid — alpha-gated by
	// PlayFieldEditorMode.gridAlpha (ON by default at 0.15; 0 disables:
	// no updates, no elements bound, zero cost).
	// -------------------------------------------------------------------
	/** Pooled horizontal grid lines (GRID_MAX_ROWS per strumline). */
	var gridLines:Array<RepeatSprite> = [];
	var gridBuf:Buffer<RepeatSprite>;
	var gridProg:CustomProgram;
	/** True while the grid elements are bound (alpha went non-zero). */
	var gridActive:Bool = false;
	/** Max rows drawn per strumline — covers the spawn window at sane BPMs. */
	static inline var GRID_MAX_ROWS:Int = 64;

	// -------------------------------------------------------------------
	// v3.3 Selection — marquee capture + highlight overlay. The STATE
	// (the id set, the clipboard, the history) lives in
	// PlayFieldEditorMode.edits (EditorEditSystem); this layer owns the
	// gestures, the hit-testing and the rendering.
	// -------------------------------------------------------------------
	/** True while a CTRL+LMB drag is banding the marquee rectangle. */
	var marqueeing:Bool = false;
	/** Marquee start corner (display-local, the press point). */
	var marqueeX0:Float = 0;
	var marqueeY0:Float = 0;
	/** Marquee current corner (display-local, tracks the cursor). */
	var marqueeX1:Float = 0;
	var marqueeY1:Float = 0;
	/** SHIFT held at band start — the box ADDS to the selection instead of replacing it. */
	var marqueeAdditive:Bool = false;
	/**
		The SELECTION BOX sprite (v3.4): fill + edge outline elements that
		draw the band; the class normalizes the corner pair and owns all
		five rects. Replaces the old single translucent marqueeRect — a
		dedicated element class, as requested.
	**/
	var selectionBox:SelectionBoxSprite;
	/** Pooled highlight quads over selected notes (lazily bound like the grid). */
	var selQuads:Array<RepeatSprite> = [];
	var selBuf:Buffer<RepeatSprite>;
	var selProg:CustomProgram;
	/** True while the highlight quads are bound. */
	var selActive:Bool = false;
	/** Max simultaneously highlighted notes — the view window is bounded anyway. */
	static inline var SEL_MAX:Int = 512;

	var display(default, null):CustomDisplay;

	var eventsActive(default, null):Bool = false;

	function new(parent:PlayField) {
		this.parent = parent;
		display = parent.display;

		// 4 elements: the ghost square, the hold-edit cyan ruler cap, the
		// red tail ruler, and the event-lane icon.
		squareBuf = new Buffer<RepeatSprite>(4, 2, true);
		squareProg = new CustomProgram(squareBuf);
		square = new RepeatSprite(0, 0, SQUARE_SIZE, SQUARE_SIZE);
		square.c = 0x00FF00FF; // green = add (red = occupied)
		square.c.aF = 0.35;
		square.r = 45; // diamond orientation over the lane
		holdTail = new RepeatSprite(0, 0, 0, 0);
		holdTail.c = 0xFF0000FF; // red = the sustain tail being dialed in
		holdTail.c.aF = 0.4;
		holdTail.r = 0;
		// The event lane's insertion icon: a violet diamond that hangs
		// VERTICALLY CENTERED in the lane (the insertion point marker),
		// plus small yellow diamonds marking already-placed events.
		eventGhost = new RepeatSprite(0, 0, SQUARE_SIZE, SQUARE_SIZE);
		eventGhost.c = 0x8000FFFF; // violet = event insertion
		eventGhost.c.aF = 0.35;
		eventGhost.r = 45;
		eventMarkerBuf = new Buffer<RepeatSprite>(32, 2, true);
		eventMarkerProg = new CustomProgram(eventMarkerBuf);
		// The step/beat grid pool: 64 rows x 2 strumlines, lazily bound
		// the first frame the grid alpha goes non-zero.
		gridBuf = new Buffer<RepeatSprite>(GRID_MAX_ROWS * 2, 2, true);
		gridProg = new CustomProgram(gridBuf);
		// The selection overlay: the selection box's five elements
		// (always bound, w=0 when idle) + up to SEL_MAX highlight quads
		// (lazily bound the first frame a selection exists).
		selBuf = new Buffer<RepeatSprite>(5 + SEL_MAX, 2, true);
		selProg = new CustomProgram(selBuf);
		selectionBox = new SelectionBoxSprite();
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
		if ((mod & KeyModifier.SHIFT) != 0)
			shiftPressed = true;
	}

	function keyUp(code:KeyCode, mod:KeyModifier) {
		if ((mod & KeyModifier.CTRL) == 0)
			ctrlPressed = false;
		if ((mod & KeyModifier.SHIFT) == 0)
			shiftPressed = false;
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
		// gameplay path. In editor mode the SMOOTHED render position is
		// used — that's where the notes actually draw, so hit-testing and
		// the drag-to-duration mapping agree with what's on screen during
		// the smooth-scroll glide.
		if (parent.playfieldEditorMode) {
			var em = parent.editorMode;
			if (em != null)
				return em.smoothPosition;
			return parent.songPosition;
		}
		return !parent.startedCountdown ? parent.songPosition : parent.noteTime;
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
		side — the hovered strumline is written into the note's STORED
		lane field, independently of the notetype). Returns true when the
		cursor is over a receptor column.
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
					// Occupied = a note sits at the slot OR within half a
					// snap step of it: the ghost turns red across the whole
					// area a right-click batch-removes from
					// (findNotesNear), not just the exact cell.
					hoverOccupied = findNoteNear(li, si, hoverTimeMs) >= 0;
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
		the duration rewrite). This is the EXACT-slot matcher: placement
		and LMB pickup use it, so the press always acts on precisely the
		cell the ghost shows. Batch removal uses findNotesNear instead
		(every note in the catchment); findNoteNear remains the
		hover-occupied and SHIFT-toggle matcher.
	*/
	function findNoteAt(lane:Int, strumlineIdx:Int, timeMs:Float):Int64 {
		var len = File.getLength();
		if (len <= 0)
			return -1;

		var target = MetaNote.floatToMetaNotePosition(timeMs);

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
			if (n.index == lane && NoteSystem.clampLane(n.lane, parent.noteSystem.strumlines.length) == strumlineIdx)
				return i;
			i++;
		}
		return -1;
	}

	/**
		Removal targeting. A binary search captures the note RANGE around
		the snapped time — half a snap step to each side (the same
		catchment the event lane uses) — and the captured range is then
		FILTERED down to the lane index + strumline actually selected,
		keeping whichever remaining note lies NEAREST the snap. So: a note
		exactly on the slot (distance 0) always wins, and an off-grid note
		(a loaded chart, a hold-tail release) is still removable by
		clicking the cell it straddles. Everything the filter rejects —
		other lanes, other strumlines, notes beyond half a step — is
		ignored. Placement/pickup stays EXACT (findNoteAt); this
		looseness is for removal only.
	**/
	function findNoteNear(lane:Int, strumlineIdx:Int, timeMs:Float):Int64 {
		var len = File.getLength();
		if (len <= 0)
			return -1;

		var target = MetaNote.floatToMetaNotePosition(timeMs);
		var tol = MetaNote.floatToMetaNotePosition(parent.editorMode.snapMs * 0.5);
		var loPos = target - tol;
		var hiPos = target + tol;

		// Binary search to the first note inside the captured range...
		var lo:Int64 = 0, hi:Int64 = len;
		while (lo < hi) {
			var mid:Int64 = (lo + hi) >> 1;
			if (File.getNote(mid).position < loPos)
				lo = mid + 1;
			else
				hi = mid;
		}

		// ...then walk it, filter out what was not meant to be selected
		// (other lanes / strumlines / beyond the catchment), and keep the
		// note closest to the snap (ties go to the earliest).
		var best:Int64 = -1;
		var bestDist:Int64 = 0;
		var i = lo;
		while (i < len) {
			var n = File.getNote(i);
			if (n.position > hiPos)
				break;
			if (n.index == lane && NoteSystem.clampLane(n.lane, parent.noteSystem.strumlines.length) == strumlineIdx) {
				var d = n.position > target ? n.position - target : target - n.position;
				if (best < 0 || d < bestDist) {
					best = i;
					bestDist = d;
				}
			}
			i++;
		}
		return best;
	}

	/**
		v3.4 batch removal targeting: the SAME catchment walk as
		findNoteNear, but it keeps EVERY matching note in the snap
		neighborhood (the whole captured range on this lane index +
		strumline), not just the nearest one. Right-click now removes the
		entire cluster around the snapped time in one gesture; the ids
		feed edits.removeNotesByIds, so it is ONE undo command.
	**/
	function findNotesNear(lane:Int, strumlineIdx:Int, timeMs:Float):Array<Int64> {
		var len = File.getLength();
		if (len <= 0)
			return [];

		var target = MetaNote.floatToMetaNotePosition(timeMs);
		var tol = MetaNote.floatToMetaNotePosition(parent.editorMode.snapMs * 0.5);
		var loPos = target - tol;
		var hiPos = target + tol;

		// Binary search to the first note inside the captured range,
		// then walk it collecting every lane/strumline match.
		var lo:Int64 = 0, hi:Int64 = len;
		while (lo < hi) {
			var mid:Int64 = (lo + hi) >> 1;
			if (File.getNote(mid).position < loPos)
				lo = mid + 1;
			else
				hi = mid;
		}

		var ids:Array<Int64> = [];
		var i = lo;
		while (i < len) {
			var n = File.getNote(i);
			if (n.position > hiPos)
				break;
			if (n.index == lane && NoteSystem.clampLane(n.lane, parent.noteSystem.strumlines.length) == strumlineIdx)
				ids.push(i);
			i++;
		}
		return ids;
	}

	// ==================================================================
	// v3.3 Selection — marquee capture + highlight rendering
	// ==================================================================

	/**
		Live selection-box capture (v3.4), run on every mouse move past the
		slop while banding. Every note the box TOUCHES is selected: a note
		is captured when its drawn rectangle INTERSECTS the box's
		rect — edge contact counts, so notes straddling the box's edge are
		in (touching = intersecting, not just centers-inside). The box's Y
		span maps to a time span PER STRUMLINE (the lane-0 movement LUT +
		receptor anchor — the same inverse the ghost square uses), its X
		span to the lane columns. The candidate walk is a binary search
		into the global tick envelope, so the cost is bounded by the notes
		actually inside the band's time span — not the chart.
	**/
	function recomputeMarqueeSelection() {
		var em = parent.editorMode;
		var noteSystem = parent.noteSystem;
		if (em == null || em.edits == null || noteSystem == null)
			return;
		var strumlines = noteSystem.strumlines;
		if (strumlines.length == 0)
			return;

		var minX = Math.min(marqueeX0, marqueeX1);
		var maxX = Math.max(marqueeX0, marqueeX1);
		var minY = Math.min(marqueeY0, marqueeY1);
		var maxY = Math.max(marqueeY0, marqueeY1);
		if (maxX - minX < 1 || maxY - minY < 1)
			return;

		// Per-strumline time spans (as tick positions), plus the global
		// envelope for the binary search below.
		var siLo:Array<Int64> = [];
		var siHi:Array<Int64> = [];
		var globalLo:Int64 = 0;
		var globalHi:Int64 = 0;
		var haveSpan:Bool = false;
		var luts = noteSystem.movementLUTs;
		for (si in 0...strumlines.length) {
			var strumline = strumlines[si];
			if (strumline.length == 0 || strumline.receptors[0] == null) {
				siLo.push(0);
				siHi.push(-1); // empty span — nothing can match
				continue;
			}
			var note = strumline.receptors[0].note;
			// yToTimeMs reads the lutCtx globals — feed it THIS
			// strumline's lane-0 context so the inverse matches how
			// notes draw here.
			if (luts != null && si < luts.length && luts[si].length > 0) {
				lutCtx = luts[si][0];
				lutCtxNoteY = note.y;
				lutCtxNoteH = note.h;
				lutCtxScale = note.scale;
			} else {
				lutCtx = null;
			}
			var t0 = yToTimeMs(minY, note.y);
			var t1 = yToTimeMs(maxY, note.y);
			if (t0 > t1) {
				var tmp = t0;
				t0 = t1;
				t1 = tmp;
			}
			var lo = MetaNote.floatToMetaNotePosition(t0);
			var hi = MetaNote.floatToMetaNotePosition(t1);
			siLo.push(lo);
			siHi.push(hi);
			if (!haveSpan) {
				globalLo = lo;
				globalHi = hi;
				haveSpan = true;
			} else {
				if (lo < globalLo)
					globalLo = lo;
				if (hi > globalHi)
					globalHi = hi;
			}
		}
		if (!haveSpan)
			return; // no strumline contributed a span

		// Binary search into the global tick envelope, then walk and
		// filter: right strumline time span + the note's drawn rectangle
		// TOUCHING the box's rect (AABB intersect — edge contact counts).
		var len = File.getLength();
		var loIdx:Int64 = 0, hiIdx:Int64 = len;
		while (loIdx < hiIdx) {
			var mid:Int64 = (loIdx + hiIdx) >> 1;
			if (File.getNote(mid).position < globalLo)
				loIdx = mid + 1;
			else
				hiIdx = mid;
		}

		var ids:Array<Int64> = [];
		var i = loIdx;
		while (i < len) {
			var n = File.getNote(i);
			if (n.position > globalHi)
				break;
			var si = NoteSystem.clampLane(n.lane, strumlines.length);
			if (n.position >= siLo[si] && n.position <= siHi[si]) {
				var strumline = strumlines[si];
				if (n.index >= 0 && n.index < strumline.length && strumline.receptors[n.index] != null) {
					var note = strumline.receptors[n.index].note;
					// The note's drawn X extent — half a note width each
					// side of the column center.
					var halfW = note.w * strumline.scale * 0.5;
					var cx = note.x + halfW;
					// TOUCHES: the note's [cx-halfW, cx+halfW] intersects
					// the box's [minX, maxX] (inclusive — edge contact
					// selects the note).
					if (cx + halfW >= minX && cx - halfW <= maxX)
						ids.push(i);
				}
			}
			i++;
		}

		if (marqueeAdditive)
			em.edits.addIdsToSelection(ids);
		else
			em.edits.selectIds(ids);
	}

	/**
		Per-frame selection rendering: the selection box sprite (while
		banding) + one translucent cyan quad per VISIBLE selected note.
		The walk binary-searches into the visible position window, so a
		select-all on a huge chart still costs only the notes on screen.
	**/
	function updateSelectionVisual() {
		var em = parent.editorMode;
		if (em == null || em.edits == null) {
			if (selectionBox != null && selectionBox.boxActive())
				selectionBox.hideBox();
			if (selBuf != null) {
				try {
					if (selectionBox != null)
						selectionBox.updateIn(selBuf);
					selBuf.update();
				} catch (e:Dynamic) {}
			}
			return;
		}
		var edits = em.edits;
		var noteSystem = parent.noteSystem;

		// The selection box itself (fill + edge outline).
		if (marqueeing) {
			selectionBox.setBox(marqueeX0, marqueeY0, marqueeX1, marqueeY1);
		} else if (selectionBox.boxActive()) {
			selectionBox.hideBox();
		}

		if (noteSystem == null || !edits.hasSelection()) {
			if (selActive)
				hideSelQuads();
			try {
				selectionBox.updateIn(selBuf);
				selBuf.update();
			} catch (e:Dynamic) {}
			return;
		}

		// Lazily bind the highlight pool the first frame a selection
		// exists (same pattern as the grid).
		if (!selActive) {
			while (selQuads.length < SEL_MAX) {
				var q = new RepeatSprite(0, 0, 0, 0);
				q.c = 0x00FFFFFF; // cyan
				q.c.aF = 0;
				q.c.luminanceF = 0;
				selQuads.push(q);
				selBuf.addElement(q);
			}
			selActive = true;
		}

		var strumlines = noteSystem.strumlines;
		var renderPos = playheadMs();
		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;

		// The visible window: the spawn distance ahead of the playhead
		// plus the despawn tail (a little slack past the notes).
		var winLo = MetaNote.floatToMetaNotePosition(renderPos - 500);
		var winHi = MetaNote.floatToMetaNotePosition(renderPos + 1500);
		var len = File.getLength();
		var loIdx:Int64 = 0, hiIdx:Int64 = len;
		while (loIdx < hiIdx) {
			var mid:Int64 = (loIdx + hiIdx) >> 1;
			if (File.getNote(mid).position < winLo)
				loIdx = mid + 1;
			else
				hiIdx = mid;
		}

		var qi = 0;
		var i = loIdx;
		while (i < len && qi < SEL_MAX) {
			var n = File.getNote(i);
			if (n.position > winHi)
				break;
			if (edits.isSelected(i)) {
				var si = NoteSystem.clampLane(n.lane, strumlines.length);
				var strumline = strumlines[si];
				if (strumline != null && n.index >= 0 && n.index < strumline.length && strumline.receptors[n.index] != null) {
					var note = strumline.receptors[n.index].note;
					// Column center — the same cx the hitboxes use.
					var size = note.w * strumline.scale;
					var cx = note.x + size * 0.5;
					// Drawn center Y — drawNote's exact math (the
					// strumline's lane-0 LUT + this lane's receptor
					// anchor), the same as the ghost square.
					var timeMs = MetaNote.metaNotePositionToSongTime(n.position);
					var d = -(timeMs - renderPos) * scrollSpeed;
					if (parent.downScroll)
						d = -d;
					var lut = strumline.receptors[0] != null && noteSystem.movementLUTs != null && si < noteSystem.movementLUTs.length && noteSystem.movementLUTs[si].length > 0 ? noteSystem.movementLUTs[si][0] : null;
					var scale = lut != null && lut.hasExtendedLUT ? lut.lookupScale(Std.int(d), note.scale) * note.scale : note.scale;
					var cy = note.y + (lut != null ? lut.lookupY(Std.int(d)) : Std.int(d)) + note.h * scale * 0.5;

					var q = selQuads[qi++];
					q.x = Std.int(cx - size * 0.575);
					q.y = Std.int(cy - size * 0.575);
					q.w = Std.int(size * 1.15);
					q.h = Std.int(size * 1.15);
					q.r = 0;
					q.c.setFloatRGB(0, 1, 1);
					q.c.aF = 0.30;
					q.c.luminanceF = 0.10;
				}
			}
			i++;
		}
		for (k in qi...selQuads.length) {
			selQuads[k].w = 0;
			selQuads[k].h = 0;
		}

		try {
			for (q in selQuads)
				selBuf.updateElement(q);
			selectionBox.updateIn(selBuf);
			selBuf.update();
		} catch (e:Dynamic) {}
	}

	/** Unbinds every highlight quad (selection emptied / teardown). */
	function hideSelQuads() {
		if (!selActive)
			return;
		selActive = false;
		for (q in selQuads) {
			try
				selBuf.removeElement(q)
			catch (e:Dynamic) {}
		}
		selQuads.resize(0);
		try
			selBuf.update()
		catch (e:Dynamic) {}
	}

	// ==================================================================
	// The four mouse events
	// ==================================================================

	function mouseMove(x:Float, y:Float) {
		if (parent.disposed || parent.paused)
			return;
		// The exit popup owns ALL input while open.
		if (parent.editorMode != null && parent.editorMode.anyPopupOpen())
			return;

		var local = toLocal(x, y);
		hoverX = local.x;
		hoverY = local.y;

		if (isDown) {
			if (Math.abs(local.x - downX) > CLICK_SLOP || Math.abs(local.y - downY) > CLICK_SLOP)
				moved = true;
		}

		// MARQUEE: the drag bands the rectangle and the selection is
		// recomputed LIVE on every move past the slop (the band replaced
		// the selection at press time unless SHIFT was held — additive).
		if (marqueeing && isDown) {
			marqueeX1 = local.x;
			marqueeY1 = local.y;
			if (moved)
				recomputeMarqueeSelection();
			return;
		}

		// Background PAN (R3): LMB held on background + slide shifts the
		// song position. Dragging UP pulls the chart up = later times
		// come into view (upscroll); downscroll mirrors. The chart tracks
		// the cursor 1:1 through the shared px→ms mapping, and the seek
		// path reuses the editor's clamp + smooth-scroll machinery.
		if (panning && isDown) {
			updatePanFromCursor(local.y);
			return;
		}

		// Hold-edit drag: while LMB is held on a note, the cursor's lane
		// position (snapped to the grid, relative to the note's fixed
		// position) directly sets the sustain length. Dragging above the
		// note (upscroll) shortens toward a tap; dragging below lengthens.
		// A 36px DEAD ZONE applies first: placing a note immediately
		// enters this state, and without the threshold the tiniest
		// cursor wobble during the click would snap the fresh note's
		// duration toward zero ("it just zeroed out"). Only real drags
		// (36px or more from the press point) start editing the length;
		// the wheel stays immediate.
		if (holdEditing && downNoteId >= 0) {
			if (!holdDragArmed) {
				var dx = local.x - downX;
				var dy = local.y - downY;
				if (dx * dx + dy * dy >= HOLD_DRAG_THRESHOLD_PX * HOLD_DRAG_THRESHOLD_PX)
					holdDragArmed = true;
			}
			if (holdDragArmed)
				updateHoldFromCursor(local.y);
			return;
		}

		detectEventLane(local.x, local.y);
		if (!hoverEventLane)
			detectHitbox(local.x, local.y);
		updateSquareVisual();
	}

	/**
		Pan helper: apply the cursor's Y delta (from the press point) to
		the song position. Upscroll: dragging up (negative dy) moves the
		playhead FORWARD in time — the notes slide up with the cursor.
		Downscroll mirrors the axis, so the chart still tracks the
		cursor. Clamped by seekTo (0..length-1s), silent or playing.

		INTENSITY: tripled (PAN_INTENSITY) — 1 cursor px = 3 chart px.
		SHIFT while panning drops it to 1/3, the same fine-scroll
		multiplier the wheel uses. Velocity is tracked every call so
		mouseUp can hand the motion off to a decaying fling
		(updatePanFling — Android-style slow falloff).
	**/
	function updatePanFromCursor(y:Float) {
		// A pan step while the transport plays (ENTER was hit mid-drag)
		// stops it — the drag owns the position from here on.
		haltPlaybackForScroll();

		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;

		var intensity = PAN_INTENSITY;
		if (shiftPressed)
			intensity /= SHIFT_SCROLL_DIVISOR;

		// px → ms with the same sign convention as timeToY: upscroll Y
		// grows downward with time, downscroll flips.
		var dMs = (parent.downScroll ? 1 : -1) * (y - panStartY) * intensity / scrollSpeed;
		parent.editorMode.seekTo(panStartPos + dMs);

		// Velocity (ms per real ms) for the release fling: diff against
		// the last move's position/time; a fresh grab resets the
		// reference so a held-then-moved cursor doesn't fling at its
		// full drag speed.
		var nowMs = haxe.Timer.stamp() * 1000;
		var dtMs = nowMs - panLastTimeMs;
		if (dtMs > 0 && panLastTimeMs > 0)
			panVelocityMs = (dMs - panLastDms) / dtMs;
		panLastTimeMs = nowMs;
		panLastDms = dMs;
	}

	/** Last pan delta (ms from the press point) — velocity reference. */
	var panLastDms:Float = 0;

	/**
		Release handoff: a moving pan (recent velocity) becomes a FLING.
		The remaining travel is velocity-scaled; update() steps it down
		with an Android-style slow exponential falloff (the list keeps
		gliding, gently losing speed, then settles — never a hard stop).
	**/
	function startPanFling() {
		if (Math.abs(panVelocityMs) < 0.02) {
			panFlingMs = 0;
			return;
		}
		// Total fling travel ≈ 600ms of continued motion at release
		// velocity (the decay curve then eats most of it early — the
		// classic OverScroller feel).
		panFlingMs = panVelocityMs * 600;
	}

	/**
		Kills any running pan fling immediately. Called when playback
		RESUMES (ENTER): the transport takes the position over from the
		glide, and a live fling would keep seeking under the audible
		clock for another second after the song already started — the
		chart visibly fights the audio.
	**/
	function cancelPanFling() {
		panFlingMs = 0;
		panVelocityMs = 0;
	}

	/**
		Per-frame fling step (called from update()). Applies a
		frame-rate-normalized fraction of the remaining travel and decays
		the rest — the same shape Android's overscroller uses (fast at
		first, long gentle tail, snap below epsilon).
	**/
	function updatePanFling(deltaTime:Float) {
		if (panning || Math.abs(panFlingMs) < 0.5)
			return;
		// Defensive: a fling step under a playing transport stops it
		// (resume normally kills the fling first — PlayFieldEditorMode
		// calls cancelPanFling on ENTER — so this only guards a path
		// where the two somehow coexist).
		haltPlaybackForScroll();
		// 0.94/frame (60fps-normalized): ~6% consumed per frame, a ~1.2s
		// glide to rest — the same curve as the freeplay menu's fling
		// (FLING_DECAY_PER_FRAME), so the two lists feel identical.
		var consume = 1 - Math.pow(0.94, deltaTime / (1000 / 60));
		var step = panFlingMs * consume;
		panFlingMs -= step;
		parent.editorMode.seekTo(parent.editorMode.smoothPosition + step);
		if (Math.abs(panFlingMs) < 0.5)
			panFlingMs = 0;
	}

	// ==================================================================
	// Event lane
	// ==================================================================

	/**
		Detect the event insertion lane under the cursor: a column the
		width of one note, to the LEFT of the leftmost strumline's
		receptors. Sets hoverEventLane + the snapped time under the
		cursor. When true, the note hitbox detection is skipped (the
		lanes don't overlap).
	**/
	function detectEventLane(x:Float, y:Float):Bool {
		hoverEventLane = false;
		hoverEventTimeMs = 0;

		var noteSystem = parent.noteSystem;
		if (noteSystem == null || noteSystem.strumlines.length == 0) {
			return false;
		}
		var strumline = noteSystem.strumlines[0];
		if (strumline.length == 0 || strumline.receptors[0] == null)
			return false;
		var note = strumline.receptors[0].note;
		var laneW = note.w * strumline.scale;
		var cx = eventLaneX();
		if (x < cx - laneW * 0.5 || x > cx + laneW * 0.5)
			return false;

		// Same time mapping as the note lanes, anchored on the shared
		// receptor row.
		var anchor = strumline.receptors[0].note;
		hoverEventTimeMs = snapTime(yToTimeMs(y, anchor.y));
		hoverEventLane = true;
		return true;
	}

	/** Lazy-load the song's events from eventList.json (the same file EventSystem reads). */
	function loadEvents() {
		if (eventsLoaded)
			return;
		eventsLoaded = true;
		editorEvents = [];
		var eventsPath = '${chartPath}/eventList.json';
		if (!sys.FileSystem.exists(eventsPath))
			return;
		try {
			var raw = haxe.Json.parse(sys.io.File.getContent(eventsPath));
			if (raw.events == null)
				return;
			for (ev in (raw.events:Array<Dynamic>)) {
				editorEvents.push({
					name: Std.string(ev.evName),
					value1: ev.value1 != null ? Std.string(ev.value1) : "",
					value2: ev.value2 != null ? Std.string(ev.value2) : "",
					time: Std.parseFloat(Std.string(ev.evTime))
				});
			}
		} catch (e:Dynamic) {
			// Corrupt event json — start from empty rather than crash.
			editorEvents = [];
		}
	}

	/** Write the editor's event list back to eventList.json (sorted by time). */
	function saveEvents() {
		editorEvents.sort(function(a, b) {
			if (a.time < b.time)
				return -1;
			if (a.time > b.time)
				return 1;
			return 0;
		});
		var out = {events: [for (ev in editorEvents) {evName: ev.name, value1: ev.value1, value2: ev.value2, evTime: ev.time}]};
		try {
			sys.io.File.saveContent('${chartPath}/eventList.json', haxe.Json.stringify(out, "\t"));
		} catch (e:Dynamic) {
			// Unwritable chart folder — the edit stays in memory.
		}
	}

	/** Adds a PLACEHOLDER event at the snapped cursor time (placeholders only, for now). */
	function addEventAt(timeMs:Float) {
		loadEvents();
		editorEvents.push({name: "Placeholder", value1: "", value2: "", time: timeMs});
		editorEvents.sort(function(a, b) {
			if (a.time < b.time)
				return -1;
			if (a.time > b.time)
				return 1;
			return 0;
		});
		saveEvents();
		Main.current.playScrollSound();
		rebuildEventMarkers();
	}

	/** Removes any event within half a snap step of the snapped cursor time. */
	function removeEventNear(timeMs:Float) {
		loadEvents();
		var halfStep = parent.editorMode.snapMs * 0.5;
		var found = false;
		var i = editorEvents.length - 1;
		while (i >= 0) {
			if (Math.abs(editorEvents[i].time - timeMs) <= halfStep) {
				editorEvents.splice(i, 1);
				found = true;
			}
			i--;
		}
		if (found) {
			saveEvents();
			Main.current.playScrollSound();
			rebuildEventMarkers();
		}
	}

	/**
		Rebuild the event markers around the current playhead: one small
		yellow diamond per event within the visible time span, riding the
		lane at the event's Y (same mapping as notes).
	**/
	function rebuildEventMarkers() {
		if (eventMarkerBuf == null)
			return;
		loadEvents();

		// Out with the old.
		for (m in eventMarkers) {
			try
				eventMarkerBuf.removeElement(m)
			catch (e) {}
		}
		eventMarkers = [];

		var noteSystem = parent.noteSystem;
		if (noteSystem == null || noteSystem.strumlines.length == 0)
			return;
		var strumline = noteSystem.strumlines[0];
		if (strumline.length == 0 || strumline.receptors[0] == null)
			return;
		var anchor = strumline.receptors[0].note;
		var cx = eventLaneX();
		var scale = strumline.scale;
		var size = Std.int(SQUARE_SIZE * 0.5 * scale);
		var capacity = eventMarkerBuf.length;

		for (ev in editorEvents) {
			if (eventMarkers.length >= capacity)
				break;
			// Only the ones on screen (± one screen of travel).
			var y = timeToY(ev.time, anchor.y);
			if (y < -100 || y > Main.INITIAL_HEIGHT + 100)
				continue;
			var m = new RepeatSprite(0, 0, size, size);
			m.x = Std.int(cx - size * 0.5);
			m.y = Std.int(y - size * 0.5);
			m.c = 0xFFE600FF; // yellow = placed event
			m.c.aF = 0.6;
			m.r = 45;
			eventMarkers.push(m);
			try
				eventMarkerBuf.addElement(m)
			catch (e) {}
		}
		try
			eventMarkerBuf.update()
		catch (e) {}
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
		chart stores duration in 1 ms ticks (24-bit field, max
		16,777,215 ms ≈ 4.66 h), snapped to whole grid steps. The note is
		removed and re-added at the same position with the new duration
		(the chart has no in-place edit), which keeps its slot in the
		sorted order.
	*/
	function setHoldDuration(dur:Float) {
		if (downNoteId < 0)
			return;

		var step = parent.editorMode.snapMs;
		if (step > 0)
			dur = Math.round(dur / step) * step;
		if (dur < MIN_SUSTAIN_MS)
			dur = MIN_SUSTAIN_MS;
		if (dur > 16777215)
			dur = 16777215; // the chart's 24-bit duration field
		if (dur == holdDurationMs)
			return; // no change — don't churn the chart

		var old = File.getNote(downNoteId);
		if (old == null)
			return;
		var position = old.position;
		var index = old.index;
		var type = old.type;
		var lane = old.lane; // the stored lane rides along unchanged

		// One recorded replace: remove + re-add as a single undo entry.
		downNoteId = parent.editorMode.edits.replaceNote(downNoteId, position, Std.int(dur), index, type, lane);
		if (downNoteId < 0)
			return; // write failed — stop editing

		holdDurationMs = dur;
		parent.editorMode.onChartEdited();
	}

	/**
		Steps the hold-edited note's duration by `steps` snap steps (UI
		SHIFT+UP / SHIFT+DOWN while in the duration-change state). Works
		both while the mouse is still held (the classic hold-edit) and
		after a press-drag-release edit is re-entered via UI keys.
	**/
	function nudgeHoldDuration(steps:Int) {
		if (!holdEditing || downNoteId < 0)
			return;
		setHoldDuration(holdDurationMs + steps * parent.editorMode.snapMs);
		updateSquareVisual();
	}

	/**
		UP/DOWN while a note is held (hold-edit state): retype that
		note to the pen's new type. The note KEEPS its stored lane — the
		v2 format stores the strumline on the note, so a retype can never
		move it to the other strumline. With no held note it is a no-op
		that just returns the pen unchanged.
	**/
	function retypeHeldNote(penType:Int):Int {
		if (!holdEditing || downNoteId < 0)
			return penType;

		var old = File.getNote(downNoteId);
		if (old == null)
			return penType;

		if (penType != old.type) {
			var position = old.position;
			var duration = old.duration;
			var index = old.index;
			var lane = old.lane; // unchanged — retyping never moves sides
			// One recorded replace: remove + re-add as a single undo entry.
			downNoteId = parent.editorMode.edits.replaceNote(downNoteId, position, duration, index, penType, lane);
			if (downNoteId < 0)
				return penType; // write failed — pen unchanged, stop editing
			Main.current.playScrollSound();
			parent.editorMode.onChartEdited();
		}
		return penType;
	}

	function mouseDown(x:Float, y:Float, button:MouseButton) {
		if (parent.disposed || parent.paused)
			return;

		var em = parent.editorMode;

		// Triple click/tap opens the instructions popup (the watermark's
		// "Press F1 or triple click/tap..."): three LEFT presses within
		// the click slop and a 900ms window. Counted only on the
		// BACKGROUND (no lane slot, no event lane) so the gesture can
		// never place, remove or edit notes — press 1-2 of the streak
		// would otherwise already write to the chart before press 3
		// completes the triple. Background presses are pure pan starts;
		// an unmoved release is a no-op, so a background triple is
		// completely inert. Not counted while a popup is open (an open
		// popup consumes the clicks itself).
		var localTri = toLocal(x, y);
		var onBackground = !detectEventLane(localTri.x, localTri.y) && !detectHitbox(localTri.x, localTri.y);
		if (button == MouseButton.LEFT && em != null && !em.anyPopupOpen() && onBackground) {
			var nowMs = haxe.Timer.stamp() * 1000;
			var withinSlop = Math.abs(x - tripleLastX) <= 64 && Math.abs(y - tripleLastY) <= 64;
			if (nowMs - tripleLastMs <= 250 && withinSlop) {
				tripleClicks++;
				if (tripleClicks >= 3) {
					tripleClicks = 0;
					tripleLastMs = 0;
					if (em.instructionsPopup != null)
						em.instructionsPopup.toggle();
					return;
				}
			} else {
				tripleClicks = 1;
			}
			tripleLastMs = nowMs;
			tripleLastX = x;
			tripleLastY = y;
		} else if (button == MouseButton.LEFT) {
			// A press on a lane/event lane (or while a popup is open)
			// breaks the streak — a background triple must be three pure
			// background presses in a row.
			tripleClicks = 0;
		}

		// The exit popup owns ALL input while open — clicks included.
		if (em != null && em.exitPopup != null && em.exitPopup.opened) {
			if (button == MouseButton.LEFT)
				em.exitPopup.click(x, y);
			tripleClicks = 0; // the popup consumed this gesture
			return;
		}
		// The instructions card dismisses on any click.
		if (em != null && em.instructionsPopup != null && em.instructionsPopup.opened) {
			if (button == MouseButton.LEFT)
				em.instructionsPopup.click(x, y);
			tripleClicks = 0; // the card consumed this gesture — no close/re-open dance
			return;
		}

		var local = toLocal(x, y);

		// Event lane: LMB adds a placeholder event at the snapped cursor
		// time; RMB removes one near it. Handled before the note lane
		// logic — the lanes never overlap.
		if (detectEventLane(local.x, local.y)) {
			if (button == MouseButton.LEFT)
				addEventAt(hoverEventTimeMs);
			else if (button == MouseButton.RIGHT)
				removeEventNear(hoverEventTimeMs);
			return;
		}

		if (button == MouseButton.LEFT && ctrlPressed && em != null && em.edits != null) {
			// CTRL+press = MARQUEE — the selection gesture owns this
			// press entirely (no placement, no hold-edit, no pan). The
			// band REPLACES the selection unless SHIFT is also held
			// (additive banding); a press-release without moving clears
			// it instead. Like a pan grab, a marquee while the transport
			// plays stops it — the band is drawn on a frozen chart.
			isDown = true;
			moved = false;
			marqueeing = true;
			marqueeAdditive = shiftPressed;
			downX = local.x;
			downY = local.y;
			marqueeX0 = local.x;
			marqueeY0 = local.y;
			marqueeX1 = local.x;
			marqueeY1 = local.y;
			if (!marqueeAdditive)
				em.edits.clearSelection();
			haltPlaybackForScroll();
			return;
		}

		if (button == MouseButton.LEFT) {
			isDown = true;
			moved = false;
			downX = local.x;
			downY = local.y;
			panning = false;
			// Capture the slot NOW — the click target stays fixed even as
			// the song scrolls under a held cursor.
			downOnGrid = detectHitbox(local.x, local.y);
			downLane = hoverLane;
			downStrumline = hoverStrumline;
			downTimeMs = hoverTimeMs;
			// SHIFT+press on a slot: toggle that note into/out of the
			// SELECTION instead of placing/hold-editing — the press is a
			// selection verb. Same catchment as removal (findNoteNear),
			// so off-grid notes are toggleable too. SHIFT on an empty
			// slot falls through to a normal placement.
			if (shiftPressed && downOnGrid && em != null && em.edits != null) {
				var id = findNoteNear(downLane, downStrumline, downTimeMs);
				if (id >= 0) {
					em.edits.toggleSelected(id);
					em.updateReadout();
					return;
				}
			}
			// Pressing an EXISTING note enters hold-edit mode: the sustain
			// can now be adjusted with the wheel or by dragging. Pressing
			// an empty slot adds the note IMMEDIATELY (still holding the
			// button) and enters the SAME hold-duration state on the fresh
			// note — placing and lengthening is one continuous gesture
			// (drag down / wheel / UI up-down all work from here).
			downNoteId = downOnGrid ? findNoteAt(downLane, downStrumline, downTimeMs) : -1;
			var pressedExisting = downNoteId >= 0;
			if (downNoteId < 0 && downOnGrid) {
				// Empty slot: add the note right away and capture it for
				// hold-editing. The NOTETYPE comes from the pen as-is —
				// the v2 note stores the lane (the hovered strumline)
				// independently of the type, so the ghost's type no
				// longer needs coercing to a side. editorAdd records the
				// undo entry.
				var id = parent.editorMode.edits.editorAdd(MetaNote.floatToMetaNotePosition(downTimeMs), 0, downLane, parent.editorMode.notetype, downStrumline);
				if (id >= 0) {
					downNoteId = id;
					Main.current.playScrollSound();
					parent.editorMode.onChartEdited();
				}
			}
			if (pressedExisting) {
				// Pen pickup: pressing an EXISTING note makes its type the
				// editor-global pen type — the next placement (mouse or
				// keybind) re-uses exactly what you just grabbed, and
				// UP/DOWN retype THIS note because it is the held
				// one. (A freshly placed note does NOT do this — its type
				// was just coerced by the placement, and re-writing the
				// pen would fight the user's chosen pen type.)
				var picked = File.getNote(downNoteId).type;
				if (picked != parent.editorMode.notetype) {
					parent.editorMode.notetype = picked;
					parent.editorMode.updateReadout();
				}
			}
			holdEditing = downNoteId >= 0;
			// The drag dead zone starts UNarmed at every press; only
			// sustained 36px+ movement arms the mouse-driven duration
			// edit (wheel/UI-key edits are always live).
			holdDragArmed = false;
			if (holdEditing) {
				// note.duration is already in ms (the chart's duration unit).
				holdDurationMs = File.getNote(downNoteId).duration;
			} else if (!downOnGrid) {
				// BACKGROUND press: no slot, no note — this gesture is a
				// PAN. A grab while the transport is playing STOPS it
				// first (any scroll gesture pauses playback); the pan
				// then drags the frozen chart. A press-release without
				// moving does nothing. A grab also kills any running
				// fling and resets the velocity tracker.
				haltPlaybackForScroll();
				panning = true;
				panFlingMs = 0;
				panVelocityMs = 0;
				panLastTimeMs = 0;
				panLastDms = 0;
				panStartPos = parent.editorMode.smoothPosition;
				panStartY = local.y;
			}
			updateSquareVisual(); // ruler while held
		}
	}

	function mouseUp(x:Float, y:Float, button:MouseButton) {
		if (parent.disposed || parent.paused)
			return;
		// The exit popup owns ALL input while open.
		if (parent.editorMode != null && parent.editorMode.anyPopupOpen())
			return;

		if (button == MouseButton.LEFT) {
			if (!isDown)
				return;
			isDown = false;

			// Marquee release: a real band keeps its live-captured set;
			// an unmoved CTRL+press (no band) clears the selection.
			if (marqueeing) {
				marqueeing = false;
				if (parent.editorMode != null && parent.editorMode.edits != null) {
					if (!moved)
						parent.editorMode.edits.clearSelection();
					parent.editorMode.updateReadout();
				}
				var localM = toLocal(x, y);
				detectHitbox(localM.x, localM.y);
				updateSquareVisual();
				return;
			}

			// The add already happened at mouseDown (placing a note
			// with the button held goes straight into the duration
			// state), and every wheel/drag/UI-key write went straight
			// to the chart through setHoldDuration. The release just
			// ends the gesture — nothing further to write. A click on
			// an occupied slot that never dragged is likewise already
			// final.
			var wasHoldEdit = holdEditing;
			var noteId = downNoteId;
			downOnGrid = false;
			downLane = -1;
			downStrumline = -1;
			downNoteId = -1;
			holdEditing = false;
			holdDragArmed = false;
			var wasPan = panning;
			if (panning)
				startPanFling(); // moving release → Android-style glide
			panning = false;
			// A plain click on empty background (a pan that never moved)
			// DESELECTS — click-away, the standard layer-peeling rule.
			// A real pan/fling keeps the selection alive.
			if (wasPan && !moved && parent.editorMode != null && parent.editorMode.edits != null)
				parent.editorMode.edits.clearSelection();
			// v3.4: ANY plain click of the button (no SHIFT, no CTRL —
			// not a toggle, not a box band, not part of a hold-edit drag)
			// clears the whole selection: a click on a note, on an empty
			// slot, on the background — a selection that survives plain
			// editing gestures reads as a stuck highlight. Placements,
			// pickups, duration drags and pans-with-motion all pass
			// through here too, so the guard is on the MODIFIERS only.
			if (!shiftPressed && !ctrlPressed && !moved
				&& parent.editorMode != null && parent.editorMode.edits != null
				&& parent.editorMode.edits.hasSelection())
				parent.editorMode.edits.clearSelection();

			if (wasHoldEdit)
				heldNoopRelease(noteId, holdDurationMs);

			// Re-detect for the release position's visual state.
			var local = toLocal(x, y);
			detectHitbox(local.x, local.y);
			updateSquareVisual();
			return;
		}

		if (button == MouseButton.RIGHT) {
			// The event lane eats RMB first (remove event near cursor).
			var local = toLocal(x, y);
			if (detectEventLane(local.x, local.y)) {
				removeEventNear(hoverEventTimeMs);
				return;
			}
			if (detectHitbox(local.x, local.y) && hoverLane >= 0) {
				// v3.4 batch removal: the SAME snap catchment walk as the
				// single-note removal, but EVERY note in the neighborhood
				// goes — one gesture, one undo command
				// (edits.removeNotesByIds). The selection is cleared by
				// the per-removal remaps as the ids leave the chart.
				var ids = findNotesNear(hoverLane, hoverStrumline, hoverTimeMs);
				if (ids.length > 0 && parent.editorMode.edits.removeNotesByIds(ids) != 0) {
					Main.current.playScrollSound();
					parent.editorMode.onChartEdited();
				}
			} else if (parent.editorMode != null && parent.editorMode.edits != null
				&& !shiftPressed && !ctrlPressed
				&& parent.editorMode.edits.hasSelection()) {
				// A plain RMB on non-slot ground: not a removal gesture —
				// it clears the whole selection (v3.4: a click of EITHER
				// button, no SHIFT/CTRL, deselects everything).
				parent.editorMode.edits.clearSelection();
				parent.editorMode.updateReadout();
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
		// The exit popup owns ALL input while open.
		if (parent.editorMode != null && parent.editorMode.anyPopupOpen())
			return;

		// Any scroll while the editor transport is PLAYING stops it
		// first — the same stop path ENTER uses — and the notch then
		// scrubs the newly-frozen chart. Scrolling is always a scrub of
		// a silent chart; it never fights the audible clock.
		haltPlaybackForScroll();

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
		// SHIFT = fine scroll: the intensity drops to 1/3 (applies on
		// top of the Ctrl multiplier, so shift+ctrl still jumps far,
		// just softly).
		if (shiftPressed)
			seek /= SHIFT_SCROLL_DIVISOR;
		// A wheel notch interrupts any running pan fling — the two
		// scroll modes never fight over the position.
		panFlingMs = 0;
		parent.editorMode.seekTo(parent.songPosition + notches * seek);
	}

	/**
		Any scroll gesture — wheel notch, background pan grab, fling
		glide — arriving while the editor transport is PLAYING stops the
		transport (the editor's own stop path: audio stops, position
		freezes at what was heard, the note window rebuilds). The gesture
		then continues on the frozen chart. ENTER stays the one
		deliberate playback toggle; a scroll mid-playback reads as "hold
		on, let me look", not as a dead input.
	**/
	function haltPlaybackForScroll() {
		var em = parent.editorMode;
		if (em != null && em.playing)
			em.togglePlayback();
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

			// Hold-editing: the graphic matches the user's reference —
			// the NOTE HEAD IS LEFT COMPLETELY BARE (its normal arrow
			// sprite, no cap), and a narrow solid RED BAR extends from
			// the head's visual center along the lane for the whole
			// dialed duration. Reference proportions: the bar is ~44%
			// of the note head's width, square-edged, horizontally
			// centered on the lane. The bar is hidden when the duration
			// is zero (a tap).
			if (holdEditing && isDown) {
				// No ghost square over the head while editing — the bare
				// note plus the red bar is the whole graphic.
				square.w = 0;
				square.h = 0;

				var stretch = holdDurationMs * parent.scrollSpeed;
				var barY = cy + (parent.downScroll ? -stretch : stretch);
				var barW = Std.int(Math.max(drawW * 0.44, 4)); // ~44% of the note head's width
				var y0 = Std.int(Math.min(cy, barY));
				var y1 = Std.int(Math.max(cy, barY));

				holdTail.w = barW;
				holdTail.h = Std.int(Math.max(y1 - y0, 0));
				holdTail.x = Std.int(cx - barW * 0.5);
				holdTail.y = y0;
				holdTail.c = 0xFF0000FF; // reference-style red, half-transparent
				holdTail.c.aF = 0.4;
			} else {
				// Not hold-editing: no bar.
				holdTail.w = 0;
				holdTail.h = 0;

				// Square centered exactly on the note's visual center.
				square.w = size;
				square.h = size;
				square.x = Std.int(cx - size * 0.5);
				square.y = Std.int(cy - size * 0.5);
				square.r = 45; // diamond orientation over the lane

				// Red = a right-click removes from here (a note sits at
				// the slot or within half a snap step of it), green =
				// clean add. Under the v2 format the hovered strumline
				// goes into the note's STORED lane, so the pen's notetype
				// always rides along unchanged — no more violet coercion
				// square.
				var occupied = showHeld ? findNoteNear(lane, strumlineIdx, timeMs) >= 0 : hoverOccupied;
				if (occupied) {
					square.c = 0xFF0000FF; // red = a note is already there
				} else {
					square.c = 0x00FF00FF; // green = clean add
				}
				square.c.aF = showHeld ? 0.18 : 0.35; // darkened while held
			}
		}

		if (squareBuf != null) {
			try {
				squareBuf.updateElement(square);
				squareBuf.updateElement(holdTail);
				squareBuf.update();
			} catch (e) {}
		}

		// Event lane icon: a violet diamond, VERTICALLY CENTERED in
		// the event column, always visible while the editor runs — the
		// "insertion point" affordance. Brightens when hovered.
		if (eventGhost != null && parent.noteSystem != null && parent.noteSystem.strumlines.length > 0) {
			var strumline = parent.noteSystem.strumlines[0];
			if (strumline.length > 0 && strumline.receptors[0] != null) {
				var scale = strumline.scale;
				var size = Std.int(SQUARE_SIZE * scale);
				eventGhost.w = size;
				eventGhost.h = size;
				eventGhost.x = Std.int(eventLaneX() - size * 0.5);
				eventGhost.y = Std.int((Main.INITIAL_HEIGHT - size) * 0.5); // vertical center
				eventGhost.c = hoverEventLane ? 0xB880FFFF : 0x8000FFFF;
				eventGhost.c.aF = hoverEventLane ? 0.6 : 0.35;
				if (squareBuf != null) {
					try {
						squareBuf.updateElement(eventGhost);
					} catch (e) {}
				}
			}
		}
	}

	// ==================================================================
	// Real-time step/beat grid
	// ==================================================================

	/**
		Per-frame grid refresh. Gated by the editor's gridAlpha (ON by
		default): at 0 the grid is fully DISABLED — this early-outs after
		one boolean check, no rows update, no elements stay bound. At any
		other alpha the rows update in real time: every step of the conductor's
		grid (16ths at the current bpm) inside the visible window becomes a
		horizontal line spanning the strumline's FULL width (first
		receptor's x .. last receptor's x + its drawn width), positioned by
		song position through the exact scroll-speed math notes use (the
		movement LUT), with beat rows drawn brighter and a touch thicker
		than plain step rows.
	**/
	function updateGridVisual() {
		var em = parent.editorMode;
		var alpha = em != null ? em.gridAlpha : 0;
		if (alpha <= 0) {
			if (gridActive)
				hideGrid();
			return;
		}

		var conductor = Main.conductor;
		var noteSystem = parent.noteSystem;
		if (conductor == null || noteSystem == null || noteSystem.strumlines.length == 0) {
			if (gridActive)
				hideGrid();
			return;
		}

		if (!gridActive) {
			// First frame ON: pool and bind the line elements.
			var wanted = GRID_MAX_ROWS * noteSystem.strumlines.length;
			while (gridLines.length < wanted) {
				var line = new RepeatSprite(0, 0, 0, 0);
				line.c.setFloatRGB(0.4, 0.55, 1.0);
				line.c.aF = 0;
				line.c.luminanceF = 0;
				gridLines.push(line);
				gridBuf.addElement(line);
			}
			gridActive = true;
		}

		// Rows for the note window: the spawn distance ahead of the
		// playhead plus the despawn tail behind it (a little slack each
		// way so the grid extends past the notes).
		var renderPos = playheadMs();
		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;

		var s0 = Math.floor(conductor.stepAt(renderPos - 400));
		var s1 = Math.ceil(conductor.stepAt(renderPos + 1400));
		if (s1 - s0 > GRID_MAX_ROWS)
			s1 = s0 + GRID_MAX_ROWS;

		for (si in 0...noteSystem.strumlines.length) {
			var strumline = noteSystem.strumlines[si];
			if (strumline.length == 0)
				continue;
			var first = strumline.receptors[0];
			var last = strumline.receptors[strumline.length - 1];
			if (first == null || last == null || first.note == null || last.note == null)
				continue;

			// The strumline's full width: first receptor's x through the
			// last receptor's x plus its drawn width.
			var x0 = Std.int(first.note.x);
			var fullW = Std.int((last.note.x + last.note.w * strumline.scale) - x0);

			// The row's Y rides the same movement LUT the notes use
			// (column 0 as the reference), so custom noteskin formulas
			// move the grid with the notes instead of drifting past them.
			var lut = noteSystem.movementLUTs[si][0];
			var baseY = first.note.y;

			for (k in 0...GRID_MAX_ROWS) {
				var line = gridLines[si * GRID_MAX_ROWS + k];
				var stepIdx = s0 + k;
				if (k >= s1 - s0) {
					line.w = 0; // outside the window — draw nothing
					continue;
				}

				var timeMs = conductor.stepTime(stepIdx);
				// drawNote's exact diff convention: -(time - now) * speed,
				// negated again for downscroll.
				var d = -(timeMs - renderPos) * scrollSpeed;
				if (parent.downScroll)
					d = -d;
				var y = lut != null ? baseY + lut.lookupY(Std.int(d)) : baseY + Std.int(d);

				// Beat rows: the beat coordinate at this row's time lands
				// on an integer. Brighter and a touch thicker than steps.
				var beatCoord = conductor.beatAt(timeMs);
				var isBeat = Math.abs(beatCoord - Math.round(beatCoord)) < 0.05;

				line.x = x0;
				line.y = Std.int(y);
				line.w = fullW;
				line.h = isBeat ? 3 : 2;
				if (isBeat) {
					line.c.setFloatRGB(1, 1, 1);
					line.c.aF = alpha;
					line.c.luminanceF = alpha;
				} else {
					line.c.setFloatRGB(0.4, 0.55, 1.0);
					line.c.aF = alpha * 0.45;
					line.c.luminanceF = alpha * 0.45;
				}
			}
		}

		try {
			for (line in gridLines)
				gridBuf.updateElement(line);
			gridBuf.update();
		} catch (e) {}
	}

	/** Unbinds every grid line element (alpha returned to 0 / teardown). */
	function hideGrid() {
		if (!gridActive)
			return;
		gridActive = false;
		for (line in gridLines) {
			try
				gridBuf.removeElement(line)
			catch (e) {}
		}
		gridLines.resize(0);
		try
			gridBuf.update()
		catch (e) {}
	}

	// ==================================================================
	// Frame update + attach/detach (called by the PlayField editor branch)
	// ==================================================================

	/**
		Per-frame refresh: the square must track the playhead even with a
		still cursor — notes scroll under it, changing slot occupancy.
		The event markers are rebuilt when the playhead moved more than
		one snap step since the last rebuild (they ride the lane at
		fixed times, so scrolling the window needs new markers).
	*/
	var lastMarkerRebuildPos:Float = -1e9;

	function update(deltaTime:Float = 16.6) {
		if (parent.disposed)
			return;

		// Pan fling: continue the released gesture with the Android-style
		// slow falloff (no-op while grabbing or with no remaining travel).
		updatePanFling(deltaTime);

		// Event markers follow the (smoothed) scroll window.
		var renderPos = parent.playfieldEditorMode && parent.editorMode != null ? parent.editorMode.smoothPosition : parent.songPosition;
		if (Math.abs(renderPos - lastMarkerRebuildPos) > parent.editorMode.snapMs) {
			lastMarkerRebuildPos = renderPos;
			rebuildEventMarkers();
		}

		// The step/beat grid updates in real time (alpha-gated — a
		// gridAlpha of 0 skips it entirely), even while hold-editing.
		updateGridVisual();

		// The selection highlights follow the scroll window (and the
		// marquee rectangle follows the cursor) — also while hold-editing.
		updateSelectionVisual();

		// While hold-editing, skip hitbox re-detection — the edited note's
		// slot is frozen at press time and the ruler square below reads
		// downTimeMs/holdDurationMs directly. Otherwise keep detecting so
		// occupancy colors track the (seekable) playhead.
		if (holdEditing) {
			updateSquareVisual();
			return;
		}
		if (hoverLane >= 0 || hoverEventLane || (isDown && downOnGrid))
			detectHitbox(hoverX, hoverY);
		updateSquareVisual();
	}

	/** Add the square's program AFTER notesProg so it renders on top; bind events. */
	function attach() {
		// The grid program goes in BEFORE the square's so the interaction
		// markers stay visible above the grid lines. The selection
		// overlay sits between them: above the grid, below the ghost.
		if (!gridProg.isIn(display))
			display.addProgram(gridProg);
		if (!selProg.isIn(display))
			display.addProgram(selProg);
		if (!squareProg.isIn(display))
			display.addProgram(squareProg);
		if (!eventMarkerProg.isIn(display))
			display.addProgram(eventMarkerProg);
		// Start HIDDEN: a fresh editor must not show any ghost/bar until
		// the cursor actually hovers a lane or an edit begins. The
		// elements' constructor sizes (SQUARE_SIZE at 0,0) would otherwise
		// render for the frames before the first updateSquareVisual().
		square.w = 0;
		square.h = 0;
		holdTail.w = 0;
		holdTail.h = 0;
		selectionBox.hideBox();
		squareBuf.addElement(square);
		squareBuf.addElement(holdTail);
		squareBuf.addElement(eventGhost);
		selectionBox.addToBuffer(selBuf);
		try {
			squareBuf.updateElement(square);
			squareBuf.updateElement(holdTail);
			squareBuf.updateElement(eventGhost);
			squareBuf.update();
			selectionBox.updateIn(selBuf);
			selBuf.update();
		} catch (e) {}
		addEvents();
		var window = Application.current.window;
		if (window != null)
			window.cursor = MouseCursor.ARROW;
	}

	function detach() {
		removeEvents();
		hideGrid();
		hideSelQuads();
		try {
			squareBuf.removeElement(square);
			squareBuf.removeElement(holdTail);
			squareBuf.removeElement(eventGhost);
			selectionBox.removeFromBuffer(selBuf);
		} catch (e) {}
		for (m in eventMarkers) {
			try
				eventMarkerBuf.removeElement(m)
			catch (e) {}
		}
		eventMarkers = [];
		if (squareProg.isIn(display))
			display.removeProgram(squareProg);
		if (eventMarkerProg.isIn(display))
			display.removeProgram(eventMarkerProg);
		if (selProg.isIn(display))
			display.removeProgram(selProg);
		if (gridProg.isIn(display))
			display.removeProgram(gridProg);
	}

	function dispose() {
		detach();
		square = null;
		holdTail = null;
		eventGhost = null;
		selectionBox = null;
		if (squareBuf != null) {
			try
				squareBuf.clear()
			catch (e) {}
			squareBuf = null;
		}
		if (eventMarkerBuf != null) {
			try
				eventMarkerBuf.clear()
			catch (e) {}
			eventMarkerBuf = null;
		}
		if (gridBuf != null) {
			try
				gridBuf.clear()
			catch (e) {}
			gridBuf = null;
		}
		if (selBuf != null) {
			try
				selBuf.clear()
			catch (e) {}
			selBuf = null;
		}
		squareProg = null;
		eventMarkerProg = null;
		gridProg = null;
		selProg = null;
	}
}
