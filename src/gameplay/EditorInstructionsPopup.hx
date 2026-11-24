package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import render.RepeatSprite;
import render.text.Text;

/**
	The editor's input-instructions popup (F1 / triple-click).

	A static reference card listing the editor's real inputs — chart
	editing, transport/view, the event lane and the mode toggles — so the
	watermark hint ("Press F1 or triple click/tap...") has something to
	deliver. Rendered exactly like the exit popup: plain colored
	RepeatSprites on the playfield display (no texture sheet) plus Text
	labels, whose programs are added/removed on open/close so nothing
	draws while closed.

	The popup deliberately does NOT pause the playfield (Main skips
	update+render entirely while paused, which would freeze the popup's
	own frame — see EditorExitPopup). Instead every editor input path
	checks `PlayFieldEditorMode.anyPopupOpen()` first and routes keys and
	clicks here while it is open.
	@since Development
**/
@:publicFields
class EditorInstructionsPopup {
	var parent(default, null):PlayFieldEditorMode;

	var opened(default, null):Bool = false;

	// --- Elements (plain colored rects; the editor's visual language) ---
	var backdrop:RepeatSprite;
	var panel:RepeatSprite;
	var title:Text;
	var body:Text;
	var buf:Buffer<RepeatSprite>;
	var prog:CustomProgram;

	/**
		The card's content — one entry per line, plain ASCII (the VCR font
		atlas is generated from the TTF with the ASCII charset; arrows and
		middots would render as holes). Keep each line within ~72 chars so
		the measured panel fits a 1280x720 screen at body scale 0.6.
	**/
	static var BODY_LINES:Array<String> = [
		"CHART EDITING",
		"Left Mouse Button on an empty slot - place a note (keep",
		"  holding, then drag or wheel to dial its sustain)",
		"Left Mouse Button on a note - pick up its type into the",
		"  pen, edit its sustain",
		"Right Mouse Button - remove the note at the slot, or the",
		"  nearest one within half a snap step",
		"CTRL+Z / CTRL+Y - undo / redo",
		"Mouse wheel - seek (CTRL x4, SHIFT = 1/3 intensity)",
		"Wheel while holding a note - sustain length",
		"Drag the background - pan (a moving release flings)",
		"",
		"SELECTION & CLIPBOARD",
		"CTRL+drag - marquee select (live)   |   SHIFT+drag - add to it",
		"SHIFT+click - toggle one   |   CTRL+A - select all",
		"CTRL+C / CTRL+X / CTRL+V - copy / cut / paste at playhead",
		"DELETE - remove the selection   |   ESC or a click - clear",
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
		"F1 or triple-click - open / close this help"
	];

	function new(parent:PlayFieldEditorMode) {
		this.parent = parent;
		var display = parent.field.display;

		buf = new Buffer<RepeatSprite>(4, 2, true);
		prog = new CustomProgram(buf);

		backdrop = new RepeatSprite(0, 0, Main.INITIAL_WIDTH, Main.INITIAL_HEIGHT);
		backdrop.c = 0x000000FF;
		backdrop.c.aF = 0.6;

		title = new Text('instructionsTitle', 0, 0, display, "EDITOR INPUTS");
		title.scale = 0.9;
		title.outlineColor = 0x000000FF;
		title.outlineSize = 1;

		body = new Text('instructionsBody', 0, 0, display, BODY_LINES.join("\n"));
		body.multiline = true;
		body.scale = 0.6;
		body.outlineColor = 0x000000FF;
		body.outlineSize = 1;

		// Size the panel from the MEASURED text (font metrics differ per
		// atlas), with padding. If the card ever grows too tall for the
		// screen, the BODY is rebuilt at a smaller scale so it fits —
		// the panel clamps below then never bite.
		var padX = 34, padTop = 26, padBottom = 30;
		var maxBodyH = Main.INITIAL_HEIGHT - 20 - padTop - padBottom - title.height - 18;
		if (body.height > maxBodyH && body.height > 0) {
			var bodyScale = 0.6 * (maxBodyH / body.height);
			body = new Text('instructionsBodySmall', 0, 0, display, BODY_LINES.join("\n"));
			body.multiline = true;
			body.scale = bodyScale;
			body.outlineColor = 0x000000FF;
			body.outlineSize = 1;
		}
		var panelW = Std.int(Math.max(title.width, body.width) + padX * 2);
		var panelH = Std.int(title.height + 18 + body.height + padTop + padBottom);
		if (panelW > Main.INITIAL_WIDTH - 20)
			panelW = Main.INITIAL_WIDTH - 20;
		if (panelH > Main.INITIAL_HEIGHT - 20)
			panelH = Main.INITIAL_HEIGHT - 20;

		panel = new RepeatSprite(Std.int((Main.INITIAL_WIDTH - panelW) * 0.5), Std.int((Main.INITIAL_HEIGHT - panelH) * 0.5), panelW, panelH);
		panel.c = 0x181818FF;
		panel.c.aF = 0.92;

		title.x = panel.x + (panelW - title.width) * 0.5;
		title.y = panel.y + padTop;
		body.x = panel.x + padX;
		body.y = panel.y + padTop + title.height + 18;
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
		title.addProgram();
		body.addProgram();
		flush();
		// NOT pausing the playfield, same reasoning as the exit popup.
	}

	function close() {
		if (!opened)
			return;
		opened = false;
		try {
			buf.removeElement(backdrop);
			buf.removeElement(panel);
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
	// Input (routed from PlayFieldEditorMode.keyDown / popupClick while opened)
	// -------------------------------------------------------------------

	/** Any click dismisses the card (the "got it" gesture). */
	function click(x:Float, y:Float) {
		close();
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
			buf.update();
		} catch (e:Dynamic) {}
	}

	/** Per-frame tick (kept for parity; the card is static between inputs). */
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
	}
}
