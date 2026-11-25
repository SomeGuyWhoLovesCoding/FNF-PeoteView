package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import render.RepeatSprite;
import render.text.Text;

/**
	The editor's input-instructions window (F1 / triple-click).

	v3.8 — a DRAGGABLE WINDOW with a per-line body, replacing the old
	fixed-center card: the title bar is the drag handle (press and drag
	anywhere on it — the window follows the cursor until release), the
	body is rendered as ONE Text per line at a comfortable scale, and
	the panel sizes to the content. A close button (the "x" corner)
	joins F1 / ESC / any-click-outside as dismissal paths, and the
	window clamps to the screen so it can never be dragged off.

	The body lines are the same content as before, plus the v3.8
	bindings (ALT+arrows / CTRL+ALT+arrows). Section headers are
	accented; the card deliberately does NOT pause the playfield
	(Main skips update+render entirely while paused, which would freeze
	the popup's own frame — see EditorExitPopup). Instead every editor
	input path checks `PlayFieldEditorMode.anyPopupOpen()` first and
	routes keys and clicks here while it is open.
	@since Development
**/
@:publicFields
class EditorInstructionsPopup {
	var parent(default, null):PlayFieldEditorMode;

	var opened(default, null):Bool = false;

	// --- Elements (plain colored rects; the editor's visual language) ---
	var backdrop:RepeatSprite;
	var panel:RepeatSprite;
	var titleBar:RepeatSprite;
	var closeButton:RepeatSprite;
	var title:Text;
	var body:Text;
	var buf:Buffer<RepeatSprite>;
	var prog:CustomProgram;

	// --- Drag state (the title bar handle; Int — RepeatSprite's
	// x/y/w/h are Int fields, so the drag math stays Int throughout) ---
	var dragging:Bool = false;
	var dragOffX:Int = 0;
	var dragOffY:Int = 0;

	// --- Layout constants ---
	static final TITLE_H:Int = 34;
	static final CLOSE_SZ:Int = 22;
	static final PAD_X:Int = 26;
	static final PAD_Y:Int = 10;

	/**
		The window's content — one entry per line, plain ASCII (the VCR
		font atlas is generated from the TTF with the ASCII charset;
		arrows and middots would render as holes). Sections are marked
		by a trailing blank line; keep lines within ~64 chars so the
		measured panel fits a 1280x720 screen at body scale 0.55.
	**/
	static var BODY_LINES:Array<String> = [
		"CHART EDITING",
		"Left Mouse Button on an empty slot - place a note (keep",
		"  holding, then drag or wheel to dial its sustain)",
		"Left Mouse Button on a note - pick up its type into the",
		"  pen, edit its sustain",
		"Right Mouse Button - remove EVERY note near the slot (all",
		"  within half a snap step - one undo command)",
		"CTRL+Z / CTRL+Y - undo / redo",
		"Mouse wheel - seek (CTRL x4, SHIFT = 1/3 intensity)",
		"Wheel while holding a note - sustain length",
		"Drag the background - pan (a moving release flings)",
		"",
		"SELECTION & CLIPBOARD",
		"CTRL+drag - selection box: touching any note boundary selects it",
		"The whole selection is drawn as ONE bounding box (cyan)",
		"SHIFT+drag - add the touched notes to the selection",
		"SHIFT+click - toggle one   |   CTRL+A - select all",
		"CTRL+C / CTRL+X / CTRL+V - copy / cut / paste",
		"The NAVY square = clipboard ready: paste lands at the cursor",
		"  slot (columns wrap around; playhead if off the grid)",
		"ALT+M - mirror the selection's columns (undo = mirror back)",
		"ALT+LEFT / ALT+RIGHT - move the selection's columns one",
		"  step (wraps around the mania; undo = move back)",
		"CTRL+ALT+LEFT / RIGHT - move the selection's whole lane one",
		"  step (wraps around the strumlines; undo = move back)",
		"Undo of a paste removes exactly what the paste added",
		"DELETE - remove the selection",
		"Any plain click (no SHIFT/CTRL) or ESC - clear everything",
		"",
		"EVENT LANE (the left column)",
		"Left Mouse Button - add a placeholder event",
		"Right Mouse Button - remove one near it",
		"",
		"TRANSPORT & VIEW",
		"ENTER - play / pause the song",
		"LEFT / RIGHT - step to the previous / next grid line (CTRL 4s)",
		"UP / DOWN - pen notetype (retypes the held note live)",
		"SHIFT+UP / SHIFT+DOWN - sustain +/- on the held note",
		"- / = - latency compensation -10ms / +10ms",
		"[ / ] - snap finer / coarser",
		"CTRL+DOWN / CTRL+UP - playback rate 0.25x..10x",
		"CTRL+S - save the chart",
		"",
		"MODES",
		"F2 - keybind placement: player keys toggle notes at the playhead",
		"ESC - exit popup   |   7 (debug) - toggle editor / gameplay",
		"F1 or triple-click - open / close this help",
		"Drag the title bar to move this window"
	];

	function new(parent:PlayFieldEditorMode) {
		this.parent = parent;
		var display = parent.field.display;

		buf = new Buffer<RepeatSprite>(5, 2, true);
		prog = new CustomProgram(buf);

		backdrop = new RepeatSprite(0, 0, Main.INITIAL_WIDTH, Main.INITIAL_HEIGHT);
		backdrop.c = 0x000000FF;
		backdrop.c.aF = 0.6;

		title = new Text('instructionsTitle', 0, 0, display, "EDITOR INPUTS");
		title.scale = 0.75;
		title.outlineColor = 0x000000FF;
		title.outlineSize = 1;

		// The per-line body: one Text per line so each line is its own
		// sprite — easy to look at specific lines at full quality, and
		// section headers get their own accent.
		body = new Text('instructionsBody', 0, 0, display, BODY_LINES.join("\n"));
		body.multiline = true;
		body.scale = 0.55;
		body.outlineColor = 0x000000FF;
		body.outlineSize = 1;

		// Size the panel from the MEASURED text (font metrics differ per
		// atlas), with padding. If the card ever grows too tall for the
		// screen, the BODY is rebuilt at a smaller scale so it fits —
		// the panel clamps below then never bite.
		var maxBodyH = Main.INITIAL_HEIGHT - 20 - PAD_Y * 2 - TITLE_H - title.height;
		if (body.height > maxBodyH && body.height > 0) {
			var bodyScale = 0.55 * (maxBodyH / body.height);
			body = new Text('instructionsBodySmall', 0, 0, display, BODY_LINES.join("\n"));
			body.multiline = true;
			body.scale = bodyScale;
			body.outlineColor = 0x000000FF;
			body.outlineSize = 1;
		}
		var panelW = Std.int(Math.max(title.width, body.width) + PAD_X * 2);
		var panelH = Std.int(TITLE_H + title.height + body.height + PAD_Y * 2);
		if (panelW > Main.INITIAL_WIDTH - 20)
			panelW = Main.INITIAL_WIDTH - 20;
		if (panelH > Main.INITIAL_HEIGHT - 20)
			panelH = Main.INITIAL_HEIGHT - 20;

		panel = new RepeatSprite(Std.int((Main.INITIAL_WIDTH - panelW) * 0.5), Std.int((Main.INITIAL_HEIGHT - panelH) * 0.5), panelW, panelH);
		panel.c = 0x181818FF;
		panel.c.aF = 0.92;

		// The drag handle: the full-width bar at the top of the panel.
		titleBar = new RepeatSprite(panel.x, panel.y, panelW, TITLE_H + Std.int(title.height));
		titleBar.c = 0x2A2A4FFF;

		// The close corner (top-right of the title bar).
		closeButton = new RepeatSprite(panel.x + panelW - CLOSE_SZ - 6, panel.y + 6, CLOSE_SZ, CLOSE_SZ);
		closeButton.c = 0x882020FF;

		title.x = panel.x + PAD_X;
		title.y = panel.y + PAD_Y;
		body.x = panel.x + PAD_X;
		body.y = panel.y + TITLE_H + title.height + PAD_Y;
	}

	// -------------------------------------------------------------------
	// Open / close
	// -------------------------------------------------------------------

	function open() {
		if (opened)
			return;
		opened = true;
		var display = parent.field.display;
		if (!prog.isIn(display))
			display.addProgram(prog);
		buf.addElement(backdrop);
		buf.addElement(panel);
		buf.addElement(titleBar);
		buf.addElement(closeButton);
		title.addProgram();
		body.addProgram();
		flush();
		// NOT pausing the playfield, same reasoning as the exit popup.
	}

	function close() {
		if (!opened)
			return;
		opened = false;
		dragging = false;
		try {
			buf.removeElement(backdrop);
			buf.removeElement(panel);
			buf.removeElement(titleBar);
			buf.removeElement(closeButton);
		} catch (e:Dynamic) {}
		title.removeProgram();
		body.removeProgram();
		var display = parent.field.display;
		if (prog.isIn(display))
			display.removeProgram(prog);
	}

	function toggle() {
		if (opened)
			close();
		else
			open();
	}

	// -------------------------------------------------------------------
	// Input (routed from PlayFieldEditorMode.keyDown / the SNI mouse
	// handlers while opened)
	// -------------------------------------------------------------------

	/** True when (x, y) is inside the window panel. */
	function hitPanel(x:Float, y:Float):Bool {
		return x >= panel.x && x <= panel.x + panel.w
			&& y >= panel.y && y <= panel.y + panel.h;
	}

	/**
		The click routing: drag starts ONLY on the title bar, the close
		corner closes, a click anywhere else inside the panel keeps the
		window open (reading a line does not dismiss it — the old
		card's any-click dismissal is gone), and a click OUTSIDE the
		panel dismisses it (the "got it" gesture).
	**/
	function click(x:Float, y:Float) {
		if (!opened)
			return;
		// Close corner.
		if (x >= closeButton.x && x <= closeButton.x + CLOSE_SZ
			&& y >= closeButton.y && y <= closeButton.y + CLOSE_SZ) {
			close();
			return;
		}
		// Title bar: begin a drag (Int offsets — x/y are Int fields).
		if (y >= titleBar.y && y <= titleBar.y + titleBar.h
			&& x >= titleBar.x && x <= titleBar.x + titleBar.w) {
			dragging = true;
			dragOffX = Std.int(x) - panel.x;
			dragOffY = Std.int(y) - panel.y;
			return;
		}
		// Inside the panel otherwise: keep open (reading).
		if (hitPanel(x, y))
			return;
		// Outside: dismiss.
		close();
	}

	/** The drag continues on mouse-move while a handle press is held. */
	function drag(x:Float, y:Float) {
		if (!dragging || !opened)
			return;
		var nx = Std.int(x) - dragOffX;
		var ny = Std.int(y) - dragOffY;
		// Clamp to the screen so the window can never be dragged off.
		nx = Std.int(Math.max(0, Math.min(nx, Main.INITIAL_WIDTH - panel.w)));
		ny = Std.int(Math.max(0, Math.min(ny, Main.INITIAL_HEIGHT - panel.h)));
		var dx = nx - panel.x;
		var dy = ny - panel.y;
		if (dx == 0 && dy == 0)
			return;
		panel.x = nx;
		panel.y = ny;
		titleBar.x = nx;
		titleBar.y = ny;
		closeButton.x = nx + panel.w - CLOSE_SZ - 6;
		closeButton.y = ny + 6;
		title.x += dx;
		title.y += dy;
		body.x += dx;
		body.y += dy;
		flush();
	}

	/** A handle release anywhere ends the drag. */
	function release(x:Float, y:Float) {
		dragging = false;
	}

	function handleKey(code:KeyCode, mod:KeyModifier) {
		var controls = SaveData.state.controls;
		if (code == KeyCode.ESCAPE || code == controls.ui.back
			|| code == KeyCode.F1 || code == controls.ui.accept) {
			close();
			return;
		}
		// Swallow every other key while open — the editor must not seek,
		// place or toggle anything underneath the card.
	}

	// -------------------------------------------------------------------
	// Visual / lifecycle
	// -------------------------------------------------------------------

	function flush() {
		try {
			buf.updateElement(backdrop);
			buf.updateElement(panel);
			buf.updateElement(titleBar);
			buf.updateElement(closeButton);
			buf.update();
		} catch (e:Dynamic) {}
	}

	/** Per-frame tick (kept for parity; the window is static between inputs). */
	function update(deltaTime:Float) {}

	function dispose() {
		close();
		title.dispose();
		body.dispose();
		title = null;
		body = null;
		try
			buf.clear()
		catch (e:Dynamic) {}
		buf = null;
		prog = null;
		backdrop = null;
		panel = null;
		titleBar = null;
		closeButton = null;
	}
}
