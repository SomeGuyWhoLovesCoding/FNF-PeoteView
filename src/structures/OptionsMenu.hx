package structures;

import structures.options.OptionsDisplay.OptionsCategorySelection;
import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The options submenu.
	This is where you can change the game's settings, such as controls, preferences, and gameplay options.
	It is responsible for rendering the options menu and updating it based on the player's input.
	@since Development
**/
@:publicFields
class OptionsMenu {
	static var display(default, null):CustomDisplay;
	static var optionsBuf(default, null):Buffer<OptionsSprite>;
	static var optionsProg(default, null):CustomProgram;

	static inline var CATEGORY_COUNT = 4;
	static inline var NAV_HINT_TEXT = #if !android "Mousewheel or " + #end "CTRL+LEFT/RIGHT Navigate | UP/DOWN Navigate option | ACCEPT Toggle option (shows live preview at gameplay state)";

	var categoryNav(default, null):Navigation = new Navigation();
	var optionsNav(default, null):Navigation = new Navigation();

	var navHint(default, null):Text;

	var shiftHeld:Bool = false;

	var active:Bool = false;

	var opened(default, null):Bool;

	static var optionsDisplay(default, null):OptionsDisplay;

	var actions(default, null):ActionMap;

	static function init(disp:CustomDisplay) {
		display = disp;

		if (optionsBuf == null) {
			optionsBuf = new Buffer<OptionsSprite>(15);
			optionsProg = new CustomProgram(optionsBuf);

			display.addProgram(optionsProg);
			display.removeProgram(optionsProg);
		}
	}

	function new() {
		navHint = new Text("optionsNavHint", 0, 0, display, NAV_HINT_TEXT, "vcr");
		navHint.scale = 0.75;
		navHint.alignment = CENTER;
		navHint.color = Color.GREY3;
		navHint.alpha = 0;
		navHint.x = 12;
		navHint.y = Main.INITIAL_HEIGHT - navHint.height - 50;

		if (optionsDisplay == null) {
			optionsDisplay = new OptionsDisplay(this);
		}
		optionsDisplay.closed = false;
		optionsDisplay.reload(cast optionsNav.value());

		actions = [
			Controls.Action.UI_LEFT => {action: left},
			Controls.Action.UI_RIGHT => {action: right},
			Controls.Action.UI_UP => {action: up},
			Controls.Action.UI_DOWN => {action: down},
			Controls.Action.UI_BACK => {action: back},
			Controls.Action.UI_ACCEPT => {action: enter}
		];
	}

	var alphaLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		var ratio = Math.min(deltaTime * 0.015, 1.0);
		if (ratio == 1)
			ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015; // When loading the options menu the first time it gets stuck at 1.0 for a single frame

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, ratio);

		navHint.alpha = alphaLerp;

		optionsDisplay.update(deltaTime);
	}

	function addEvents() {
		Tools.forSync(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);

			Main.current.mouseDown = mousePress;
			window.onMouseWheel.add(moveCategory_mouse);
			window.onKeyDown.add(handleKeyDown);
			window.onKeyUp.add(handleKeyUp);
		});
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		Main.current.mouseDown = null;
		window.onMouseWheel.remove(moveCategory_mouse);
		window.onKeyDown.remove(handleKeyDown);
		window.onKeyUp.remove(handleKeyUp);
	}

	function open() {
		optionsDisplay.closed = false;
		active = opened = true;
		shiftHeld = false;
		Main.current.popupOptionsMenu();

		try {
			navHint.addProgram();
			alphaLerp = 0.0;
		} catch (e) {}

		addEvents();

		if (!optionsProg.isIn(display)) {
			display.addProgram(optionsProg);
		}
	}

	function close() {
		var mm = Main.current.mainMenu;
		var pf = Main.current.playField;

		// Make sure to cancel any active binding before closing
		if (optionsDisplay.controlsDisplay.binding) {
			optionsDisplay.controlsDisplay.cancelBinding();
		}

		removeEvents();

		optionsDisplay.closed = true;

		if (mm != null) {
			MainMenu.selectedAlpha = 1.0;
			mm.addEvents();
		} else if (pf != null) {
			var pauseScreen = pf.pauseScreen;
			pauseScreen.onOptionsMenuClose();
		}

		opened = false;
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown)
			return;
		close();
		Main.current.playCancelSound();
	}

	function getOptionCountofState() {
		var result = 0;

		switch ((categoryNav.value() : OptionsCategorySelection)) {
			case CONTROLS:
				result = ControlsDisplay.controlLabels.length;
			case PREFERENCES:
				result = PreferencesDisplay.prefsStr.length;
			case GAMEPLAY:
				result = GraphicsDisplay.graphicsStr.length;
			case PERFORMANCE:
				result = PerformanceDisplay.perfStr.length;
		}

		return result;
	}

	inline function isInvalidKeyState() {
		var disp = optionsDisplay.controlsDisplay;
		return optionsDisplay != null && (disp.binding && !disp.closed && !optionsDisplay.closed);
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState())
			return;
		optionsNav.scroll(1);
		var optionssLen = getOptionCountofState();
		optionsNav.resetIfOver(optionssLen);
		Main.current.playScrollSound();
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState())
			return;
		optionsNav.scroll(-1);
		var optionssLen = getOptionCountofState();
		optionsNav.resetIfUnder(optionssLen - 1);
		Main.current.playScrollSound();
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState())
			return;
		if (shiftHeld && (cast categoryNav.value() : OptionsCategorySelection) == GAMEPLAY)
			return;
		optionsNav.setTo(0);
		categoryNav.scroll(-1);
		categoryNav.resetIfUnder(3);
		optionsDisplay.reload(cast categoryNav.value());
		Main.current.playScrollSound();
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState())
			return;
		if (shiftHeld && (cast categoryNav.value() : OptionsCategorySelection) == GAMEPLAY)
			return;
		optionsNav.setTo(0);
		categoryNav.scroll(1);
		categoryNav.resetIfOver(CATEGORY_COUNT);
		optionsDisplay.reload(cast categoryNav.value());
		Main.current.playScrollSound();
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState())
			return;
		optionsDisplay.enter();
	}

	function handleKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (keyCode == KeyCode.LEFT_SHIFT || keyCode == KeyCode.RIGHT_SHIFT)
			shiftHeld = true;

		if (optionsDisplay.closed)
			return;

		var disp = optionsDisplay.controlsDisplay;
		if (disp != null && !disp.closed) {
			disp.onKeyDown(keyCode, keyModifier);
			return;
		}

		var gfx = optionsDisplay.graphicsDisplay;
		if (gfx != null && !gfx.closed) {
			gfx.onKeyDown(keyCode, keyModifier);
		}
	}

	function handleKeyUp(keyCode:KeyCode, keyModifier:KeyModifier) {
		if (keyCode == KeyCode.LEFT_SHIFT || keyCode == KeyCode.RIGHT_SHIFT)
			shiftHeld = false;
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button == LEFT)
			enter(true, 0);
		if (button != RIGHT)
			return;
		close();
		Main.current.playScrollSound();
	}

	function moveCategory_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		if (Math.floor(y) > 0) left(true, 0);
		else right(true, 0);
	}

	function shutDown() {
		if (!optionsProg.isIn(display))
			return;

		navHint.removeProgram();

		display.color = 0x00000000;
		display.removeProgram(optionsProg);

		active = false;
		Main.current.removeOptionsMenu();
	}

	function dispose() {
		close();
		shutDown();

		if (navHint != null) {
			navHint.dispose();
			navHint = null;
		}

		optionsDisplay.dispose();
	}
}
