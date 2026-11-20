package gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import render.RepeatSprite;

/**
	The playfield editor's exit popup (F8 / ESC).

	Three options, Arrow-Vortex style:
	  0 — Exit Editor Mode   → back into gameplay on the same song (the
	                           debug-key toggle path: editorModeNext flip
	                           + state restart)
	  1 — Exit to Menu       → Main.uponSongExit() (the pause menu's
	                           EXIT does exactly this)
	  2 — Exit to Title Screen → PLACEHOLDER: the same as Exit to Menu
	                           (no titlescreen state exists yet — see
	                           StateSelection)

	Rendered as plain colored RepeatSprites on the playfield display
	(no texture sheet): a dark backdrop strip and three option bars,
	the selected one bright. Mouse clicks pick options directly; UI
	up/down/accept/back work through the editor's own key hook
	(handleKey) so no Controls-mode juggling is needed.
	@since Development
**/
@:publicFields
class EditorExitPopup {
	var parent(default, null):PlayFieldEditorMode;

	var opened(default, null):Bool = false;

	/** Selected option index (0..2). */
	var nav:handler.Navigation = new handler.Navigation();

	// --- Elements (plain colored rects; the editor's visual language) ---
	var backdrop:RepeatSprite;
	var options:Array<RepeatSprite> = [];
	var optionLabels:Array<{text:String}> = [
		{text: "Exit Editor Mode"},
		{text: "Exit to Menu"},
		{text: "Exit to Title Screen (placeholder)"}
	];
	var buf:Buffer<RepeatSprite>;
	var prog:CustomProgram;

	/** Option bar geometry (display-local px). */
	static inline var BAR_W:Int = 420;
	static inline var BAR_H:Int = 46;
	static inline var BAR_GAP:Int = 10;

	function new(parent:PlayFieldEditorMode) {
		this.parent = parent;
		var display = parent.field.display;

		buf = new Buffer<RepeatSprite>(4, 2, true);
		prog = new CustomProgram(buf);

		backdrop = new RepeatSprite(0, 0, Main.INITIAL_WIDTH, Main.INITIAL_HEIGHT);
		backdrop.c = 0x000000FF;
		backdrop.c.aF = 0.6;

		var totalH = optionLabels.length * BAR_H + (optionLabels.length - 1) * BAR_GAP;
		var y0 = Std.int((Main.INITIAL_HEIGHT - totalH) * 0.5);
		for (i in 0...optionLabels.length) {
			var bar = new RepeatSprite(Std.int((Main.INITIAL_WIDTH - BAR_W) * 0.5), y0 + i * (BAR_H + BAR_GAP), BAR_W, BAR_H);
			bar.c = 0x202020FF;
			options.push(bar);
		}
		refreshColors();
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
		for (bar in options)
			buf.addElement(bar);
		refreshColors();
		flush();
		// NOTE: deliberately NOT pausing the playfield. Main skips
		// update+render entirely while paused (both modes), which would
		// freeze the popup's own frame too — the popup would never draw.
		// Instead every editor input path checks `exitPopup.opened`
		// first (PlayFieldEditorMode.keyDown routes all keys here while
		// open; StrumlineNoteInteraction's mouse handlers early-out).
	}

	function close() {
		if (!opened)
			return;
		opened = false;
		try {
			buf.removeElement(backdrop);
			for (bar in options)
				buf.removeElement(bar);
		} catch (e:Dynamic) {}
		var display = parent.field.display;
		if (prog.isIn(display))
			display.removeProgram(prog);
	}

	// -------------------------------------------------------------------
	// Input (routed from PlayFieldEditorMode.keyDown while opened)
	// -------------------------------------------------------------------

	/**
		Mouse click (routed from StrumlineNoteInteraction.mouseDown while
		opened). Window coords → display-local, then a bar hit test; a
		click outside all bars closes the popup.
	**/
	function click(x:Float, y:Float) {
		var peoteView = Main.current.peoteView;
		var display = parent.field.display;
		var lx = display.localX(x, peoteView);
		var ly = display.localY(y, peoteView);

		for (i in 0...options.length) {
			var bar = options[i];
			if (lx >= bar.x && lx <= bar.x + bar.w && ly >= bar.y && ly <= bar.y + bar.h) {
				nav.setTo(i);
				refreshColors();
				flush();
				accept();
				return;
			}
		}
		// Outside the bars: dismiss.
		close();
	}

	function handleKey(code:KeyCode, mod:KeyModifier) {
		var controls = SaveData.state.controls;
		if (code == KeyCode.ESCAPE || code == controls.ui.back) {
			close();
			return;
		}
		if (code == controls.ui.up) {
			nav.scroll(-1);
			nav.resetIfUnder(options.length - 1);
			refreshColors();
			flush();
			Main.current.playScrollSound();
			return;
		}
		if (code == controls.ui.down) {
			nav.scroll(1);
			nav.resetIfOver(options.length);
			refreshColors();
			flush();
			Main.current.playScrollSound();
			return;
		}
		if (code == controls.ui.accept) {
			accept();
			return;
		}
		if (code == controls.ui.left || code == controls.ui.right) {
			// Swallow navigation keys so the editor doesn't seek while
			// the popup is open.
			return;
		}
	}

	function accept() {
		switch (nav.value()) {
			case 0: // Exit Editor Mode — the shared editor-toggle path
				close();
				parent.field.toggleEditorMode();
			case 1: // Exit to Menu
				Main.current.playCancelSound();
				Main.uponSongExit();
			case 2: // Exit to Title Screen — placeholder, same as menu
				Main.current.playCancelSound();
				Main.uponSongExit();
		}
	}

	// -------------------------------------------------------------------
	// Visual
	// -------------------------------------------------------------------

	function refreshColors() {
		for (i in 0...options.length) {
			var bar = options[i];
			if (i == nav.value()) {
				bar.c = 0x606060FF; // bright = selected
				bar.c.aF = 0.9;
			} else {
				bar.c = 0x202020FF;
				bar.c.aF = 0.7;
			}
		}
	}

	function flush() {
		try {
			buf.updateElement(backdrop);
			for (bar in options)
				buf.updateElement(bar);
			buf.update();
		} catch (e:Dynamic) {}
	}

	/** Per-frame tick (kept for parity; the popup is static between inputs). */
	function update(deltaTime:Float) {}

	function dispose() {
		close();
		try
			buf.clear()
		catch (e:Dynamic) {}
		buf = null;
		prog = null;
		options = [];
		backdrop = null;
	}
}
