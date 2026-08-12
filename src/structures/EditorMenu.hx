package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	Editor sub-menu that lets the player pick an editor to open.
	Uses multiline Text elements with scale 6 instead of sprite-based options.
	A grayish-gold markup indicator tracks the current selection via `editorIndex`.
	All buffers and programs are cached statically so re-entry is instant.
	@since 0.94
**/
@:publicFields
class EditorMenu {
	static var optionLabels:Array<String> = ['Noteskin Editor', 'Chart Editor', 'Mod Manager'];

	var display:CustomDisplay;
	var view:CustomDisplay;
	var roof:CustomDisplay;

	// ── Cached buffers & programs ─────────────────────────────────────────
	static var backgroundBuf:Buffer<Sprite>;
	static var backgroundProg:CustomProgram;

	static var optionTexts:Array<Text> = [];
	static var markupTxt:Text;

	// ── Selection state ───────────────────────────────────────────────────
	static var editorIndex:Int = 0;

	// Lerp state for smooth markup movement
	static var markupYLerp:Float = 0.0;
	static var alphaLerps:Array<Float> = [];

	var disposed:Bool = false;
	var actions:ActionMap;
	var inputCtx:InputContext;

	function new() {}

	static function preInit(display:CustomDisplay) {
		// ── Background (reuse MainMenu texture, cached) ────────────────────

		if (backgroundBuf == null) {
			backgroundBuf = new Buffer<Sprite>(1);

			if (backgroundProg == null) {
				backgroundProg = new CustomProgram(backgroundBuf);
				TextureSystem.setTexture(backgroundProg, "mainMenuBGTex", "mainMenuBGTex");

				var bg = new Sprite();
				bg.clipWidth = bg.clipSizeX = bg.w = Main.INITIAL_WIDTH;
				bg.clipHeight = bg.clipSizeY = bg.h = Main.INITIAL_HEIGHT;
				bg.c.setRGB(66, 66, 86);
				backgroundBuf.addElement(bg);
				backgroundBuf.updateElement(bg);
			}
		}

		// ── Option texts (cached, created once) ────────────────────────────

		if (optionTexts.length == 0) {
			for (i in 0...optionLabels.length) {
				var txt = new Text('editorMenuOpt$i', 0, 0, display, optionLabels[i]);
				txt.scale = 4;
				txt.multiline = true;
				txt.outlineColor = 0x000000FF;
				txt.outlineSize = 3;
				txt.x = 80;
				txt.y = optionY(i);
				optionTexts.push(txt);
			}
		}

		// ── Grayish-gold markup indicator (cached, created once) ──────────

		if (markupTxt == null) {
			markupTxt = new Text('editorMenuMarkup', 0, 0, display, '>');
			markupTxt.scale = 4;
			markupTxt.multiline = true;
			markupTxt.color = 0xB8A960FF; // grayish gold
			markupTxt.outlineColor = 0x000000FF;
			markupTxt.outlineSize = 3;
			markupTxt.x = 30;
		}

		markupYLerp = optionY(editorIndex);

		// Init alpha lerps on first call
		if (alphaLerps.length != optionLabels.length) {
			alphaLerps = [for (i in 0...optionLabels.length) 1.0];
		}

		markupTxt.y = markupYLerp;
		markupTxt.alpha = 0.0;

		// Lerp option text alpha (selected = bright, others = dimmed)
		for (i in 0...optionTexts.length) {
			var a = alphaLerps[i] = 0;
			optionTexts[i].alpha = a;
		}
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.display = display;
		this.view = view;
		this.roof = roof;

		view.scroll.x = 0;
		view.scroll.y = 0;
		view.fov = 1.0;

		// ── Add programs to displays ───────────────────────────────────────

		view.addProgram(backgroundProg);

		for (txt in optionTexts)
			txt.addProgram();
		markupTxt.addProgram();

		markupTxt.alpha = 1.0;

		haxe.Timer.delay(addEvents, 100);

		actions = [
			Controls.Action.UI_DOWN => {action: down},
			Controls.Action.UI_UP => {action: up},
			Controls.Action.UI_ACCEPT => {action: accept}
		];
	}

	// ── Layout helpers ────────────────────────────────────────────────────
	static inline var OPTION_START_Y:Float = 150;
	static inline var OPTION_SPACING:Float = 125;

	static inline function optionY(i:Int):Float {
		return OPTION_START_Y + (OPTION_SPACING * i);
	}

	// ── Update ────────────────────────────────────────────────────────────

	function update(deltaTime:Float) {
		var t = Math.min(deltaTime * 0.0115, 1);
		if (t == 1)
			t = (1 / lime.app.Application.current.window.frameRate) * 0.0115;

		// Lerp markup Y to the selected option
		var targetY = optionY(editorIndex);
		markupYLerp = Tools.lerp(markupYLerp, targetY, t);
		markupTxt.y = markupYLerp;

		// Lerp option text alpha (selected = bright, others = dimmed)
		for (i in 0...optionTexts.length) {
			var targetAlpha:Float = (i == editorIndex) ? 1.0 : 0.5;
			var a = alphaLerps[i] = Tools.lerp(alphaLerps[i], targetAlpha, t);
			//BOTTLENECK: mid per-frame Text.alpha setter loops every char of each option text + GPU-uploads 3 buffers/frame | FIX: lerp into a local value, apply only when the alpha actually changed
			optionTexts[i].alpha = a;
		}
	}

	// ── Navigation ────────────────────────────────────────────────────────

	function up(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		editorIndex--;
		if (editorIndex < 0)
			editorIndex = optionLabels.length - 1;
		Main.current.playScrollSound();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		editorIndex++;
		if (editorIndex >= optionLabels.length)
			editorIndex = 0;
		Main.current.playScrollSound();
	}

	function accept(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		switch (editorIndex) {
			case 0: // Noteskin Editor
				Main.switchState(NOTE_VIEW);
				removeEvents();
			case 1: // Chart Editor (TODO)
				Main.current.playConfirmSound();
			case 2: // Mod Manager (TODO)
				Main.current.playConfirmSound();
		}
	}

	// ── Key handler for BACKSPACE exit ────────────────────────────────────

	function handleKeyDown(key:KeyCode, modifier:KeyModifier) {
		if (disposed)
			return;

		if (key == KeyCode.BACKSPACE || key == KeyCode.ESCAPE) {
			Main.current.playCancelSound();
			Main.switchState(MAIN_MENU);
		}
	}

	// ── Event management ──────────────────────────────────────────────────

	function addEvents() {
		if (inputCtx == null) {
			inputCtx = new InputContext();
			inputCtx.keyDown = handleKeyDown;
		}
		Main.current.controls.bindTo(actions);
		Main.current.input.push(inputCtx);
	}

	function removeEvents() {
		Main.current.controls.unBind();
		Main.current.input.pop(inputCtx);
	}

	// ── Dispose ───────────────────────────────────────────────────────────

	function dispose() {
		removeEvents();

		for (txt in optionTexts)
			txt.removeProgram();
		markupTxt.removeProgram();

		view.removeProgram(backgroundProg);

		markupTxt.alpha = 0.0;

		display = null;
		view = null;
		roof = null;

		disposed = true;
	}
}
