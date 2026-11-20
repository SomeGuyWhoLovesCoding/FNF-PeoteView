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
	               same hold-duration state on that note. On the event
	               lane: adds/removes placeholder events. On background:
	               starts the pan gesture.
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

	// --- Event lane (F2): insertion column at the LEFT of the strumlines ---
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

	var display(default, null):CustomDisplay;

	var eventsActive(default, null):Bool = false;

	function new(parent:PlayField) {
		this.parent = parent;
		display = parent.display;

		// 4 elements: the ghost square, the hold-edit cyan ruler cap, the
		// red tail ruler (F4), and the event-lane icon (F2).
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
		// The exit popup owns ALL input while open.
		if (parent.editorMode != null && parent.editorMode.exitPopup != null && parent.editorMode.exitPopup.opened)
			return;

		var local = toLocal(x, y);
		hoverX = local.x;
		hoverY = local.y;

		if (isDown) {
			if (Math.abs(local.x - downX) > CLICK_SLOP || Math.abs(local.y - downY) > CLICK_SLOP)
				moved = true;
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
		if (holdEditing && downNoteId >= 0) {
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
	**/
	function updatePanFromCursor(y:Float) {
		var dy = y - panStartY;
		var scrollSpeed = parent.scrollSpeed;
		if (scrollSpeed <= 0)
			scrollSpeed = 1;

		// px → ms with the same sign convention as timeToY: upscroll Y
		// grows downward with time, downscroll flips.
		var dMs = parent.downScroll ? dy / scrollSpeed : -dy / scrollSpeed;
		parent.editorMode.seekTo(panStartPos + dMs);
	}

	// ==================================================================
	// Event lane (F2)
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

	/** Adds a PLACEHOLDER event at the snapped cursor time (F2: for now, placeholders only). */
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

	/**
		Steps the hold-edited note's duration by `steps` snap steps (UI
		UP/DOWN while in the duration-change state). Works both while the
		mouse is still held (the classic hold-edit) and after a
		press-drag-release edit is re-entered via UI keys.
	**/
	function nudgeHoldDuration(steps:Int) {
		if (!holdEditing || downNoteId < 0)
			return;
		setHoldDuration(holdDurationMs + steps * parent.editorMode.snapMs);
		updateSquareVisual();
	}

	function mouseDown(x:Float, y:Float, button:MouseButton) {
		if (parent.disposed || parent.paused)
			return;
		// The exit popup owns ALL input while open — clicks included.
		if (parent.editorMode != null && parent.editorMode.exitPopup != null && parent.editorMode.exitPopup.opened) {
			if (button == MouseButton.LEFT)
				parent.editorMode.exitPopup.click(x, y);
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
			// Pressing an EXISTING note enters hold-edit mode: the sustain
			// can now be adjusted with the wheel or by dragging. Pressing
			// an empty slot adds the note IMMEDIATELY (still holding the
			// button) and enters the SAME hold-duration state on the fresh
			// note — placing and lengthening is one continuous gesture
			// (drag down / wheel / UI up-down all work from here).
			downNoteId = downOnGrid ? findNoteAt(downLane, downStrumline, downTimeMs) : -1;
			if (downNoteId < 0 && downOnGrid) {
				// Empty slot: add the note right away and capture it for
				// hold-editing. If the add fails (or the slot got occupied
				// between press and now), this stays a plain click.
				var id = File.addNote(MetaNote.floatToMetaNotePosition(downTimeMs), 0, downLane, parent.editorMode.notetype);
				if (id >= 0) {
					downNoteId = id;
					Main.current.playScrollSound();
					parent.editorMode.onChartEdited();
				}
			}
			holdEditing = downNoteId >= 0;
			if (holdEditing) {
				// note.duration is already in ms (the chart's duration unit).
				holdDurationMs = File.getNote(downNoteId).duration;
			} else if (!downOnGrid) {
				// BACKGROUND press: no slot, no note — this gesture is a
				// PAN. Slide to shift the song position (see mouseMove);
				// a press-release without moving does nothing.
				panning = true;
				panStartPos = parent.editorMode.playing ? parent.songPosition : parent.editorMode.smoothPosition;
				panStartY = local.y;
			}
			updateSquareVisual(); // ruler while held
		}
	}

	function mouseUp(x:Float, y:Float, button:MouseButton) {
		if (parent.disposed || parent.paused)
			return;
		// The exit popup owns ALL input while open.
		if (parent.editorMode != null && parent.editorMode.exitPopup != null && parent.editorMode.exitPopup.opened)
			return;

		if (button == MouseButton.LEFT) {
			if (!isDown)
				return;
			isDown = false;

			// The add already happened at mouseDown (F5: placing a note
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
			panning = false;

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
		// The exit popup owns ALL input while open.
		if (parent.editorMode != null && parent.editorMode.exitPopup != null && parent.editorMode.exitPopup.opened)
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

		// Scrolling while the song plays PAUSES it first (the editor's own
		// stop path — audio transport stops, position freezes, the note
		// window rebuilds), then the seek below scrolls the now-silent
		// chart. Wheel = a scrub, never a live seek.
		var em = parent.editorMode;
		if (em != null && em.playing)
			em.togglePlayback();

		var seek = WHEEL_SEEK_MS * (ctrlPressed ? CTRL_SEEK_MULT : 1.0);
		em.seekTo(parent.songPosition + notches * seek);
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

				// Red = occupied (right-click removes), green = empty (click adds).
				var occupied = showHeld ? findNoteAt(lane, strumlineIdx, timeMs) >= 0 : hoverOccupied;
				square.c = occupied ? 0xFF0000FF : 0x00FF00FF;
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

		// Event lane icon (F2): a violet diamond, VERTICALLY CENTERED in
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

	function update() {
		if (parent.disposed)
			return;

		// Event markers follow the (smoothed) scroll window.
		var renderPos = parent.playfieldEditorMode && parent.editorMode != null ? parent.editorMode.smoothPosition : parent.songPosition;
		if (Math.abs(renderPos - lastMarkerRebuildPos) > parent.editorMode.snapMs) {
			lastMarkerRebuildPos = renderPos;
			rebuildEventMarkers();
		}

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
		squareBuf.addElement(square);
		squareBuf.addElement(holdTail);
		squareBuf.addElement(eventGhost);
		try {
			squareBuf.updateElement(square);
			squareBuf.updateElement(holdTail);
			squareBuf.updateElement(eventGhost);
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
			squareBuf.removeElement(holdTail);
			squareBuf.removeElement(eventGhost);
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
	}

	function dispose() {
		detach();
		square = null;
		holdTail = null;
		eventGhost = null;
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
		squareProg = null;
		eventMarkerProg = null;
	}
}
