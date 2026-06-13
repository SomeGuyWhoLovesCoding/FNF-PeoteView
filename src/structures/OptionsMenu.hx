package structures;

import structures.OptionsDisplay.OptionsCategorySelection;
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

	var categoryNav(default, null):Navigation = new Navigation();
	var optionsNav(default, null):Navigation = new Navigation();

	var categorySprites(default, null):Array<OptionsSprite> = [];

	var active:Bool = false;

	var opened(default, null):Bool;

	static var optionsDisplay(default, null):OptionsDisplay;

	var actions(default, null):ActionMap;
	
	static function init(disp:CustomDisplay) {
		display = disp;

		if (optionsBuf == null) {
			optionsBuf = new Buffer<OptionsSprite>(15);
			optionsProg = new CustomProgram(optionsBuf);

			var tex = TextureSystem.getTexture("optionsMenuSheet");
			OptionsSprite.init(optionsProg, "optionsMenuSheet", tex);
		}
	}

	function new() {
		for (i in 0...3) {
			var option = new OptionsSprite();
			option.type = CATEGORY_TEXT;
			option.changeID(i);
			option.y = option.h * i;
			categorySprites.push(option);
		}

		if (optionsDisplay == null) {
			optionsDisplay = new OptionsDisplay(this);
		}
		optionsDisplay.closed = false;
		optionsDisplay.reload(cast optionsNav.value());

		actions = [
			Controls.Action.UI_LEFT => { action: left },
			Controls.Action.UI_RIGHT => { action: right },
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_BACK => { action: back },
			Controls.Action.UI_ACCEPT => { action: enter }
		];
	}

	var alphaLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		var ratio = Math.min(deltaTime * 0.015, 1.0);
		if (ratio == 1) ratio = (1/lime.app.Application.current.window.frameRate) * 0.015; // When loading the options menu the first time it gets stuck at 1.0 for a single frame

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, ratio);

		for (i in 0...categorySprites.length) {
			var categorySprite = categorySprites[i];
			var originalLuminance = categorySprite.c.luminanceF;
			categorySprite.c.luminanceF = alphaLerp * (i != categoryNav.value() ? 0.5 : 1);
			categorySprite.c.aF = alphaLerp;
			if (originalLuminance != categorySprite.c.luminanceF) optionsBuf.updateElement(categorySprite);
		}

		optionsDisplay.update(deltaTime);
	}

	function addEvents() {
		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);
			
			Main.current.mouseDown = mousePress;
			window.onMouseWheel.add(moveCategory_mouse);
			window.onKeyDown.add(handleKeyDown);
		}, 1);
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		Main.current.mouseDown = null;
		window.onMouseWheel.remove(moveCategory_mouse);
		window.onKeyDown.remove(handleKeyDown);
	}

	function open() {
		optionsDisplay.closed = false;
		active = opened = true;
		Main.current.popupOptionsMenu();

		try {
			for (i in 0...categorySprites.length) {
				var categorySprite = categorySprites[i];
				categorySprite.c.luminanceF = alphaLerp * (i != categoryNav.value() ? 0.5 : 1);
				categorySprite.c.aF = alphaLerp;
				optionsBuf.addElement(categorySprite);
			}

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
		if (!isDown) return;
		close();
		Main.current.playCancelSound();
	}

	function getOptionCountofState() {
		var result = 0;

		switch ((categoryNav.value():OptionsCategorySelection)) {
			case CONTROLS:
				result = ControlsDisplay.controlLabels.length;
			case PREFERENCES:
				result = PreferencesDisplay.prefsStr.length;
			case GAMEPLAY:
				//result = GraphicsDisplay.graphicsStr.length;
				result = 0; // TODO
		}

		return result;
	}

	inline function isInvalidKeyState() {
		var disp = optionsDisplay.controlsDisplay;
		return optionsDisplay != null && (disp.binding && !disp.closed && !optionsDisplay.closed);
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState()) return;
		optionsNav.scroll(1);
		var optionssLen = getOptionCountofState();
		optionsNav.resetIfOver(optionssLen);
		Main.current.playScrollSound();
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState()) return;
		optionsNav.scroll(-1);
		var optionssLen = getOptionCountofState();
		optionsNav.resetIfUnder(optionssLen - 1);
		Main.current.playScrollSound();
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState()) return;
		optionsNav.setTo(0);
		categoryNav.scroll(-1);
		categoryNav.resetIfUnder(2);
		optionsDisplay.reload(cast categoryNav.value());
		Main.current.playScrollSound();
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState()) return;
		optionsNav.setTo(0);
		categoryNav.scroll(1);
		categoryNav.resetIfOver(categorySprites.length);
		optionsDisplay.reload(cast categoryNav.value());
		Main.current.playScrollSound();
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown || isInvalidKeyState()) return;
		optionsDisplay.enter();
	}

	function handleKeyDown(keyCode:KeyCode, keyModifier:KeyModifier) {
		var disp = optionsDisplay.controlsDisplay;
		if (disp != null && !disp.closed && !optionsDisplay.closed) {
			disp.onKeyDown(keyCode, keyModifier);
		}
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button == LEFT) enter(true, 0);
		if (button != RIGHT) return;
		close();
		Main.current.playScrollSound();
	}

	function moveCategory_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		categoryNav.scroll(-Math.floor(y));
		categoryNav.resetIfBoth(categorySprites.length, categorySprites.length - 1);
		optionsDisplay.reload(cast categoryNav.value());
		Main.current.playScrollSound();
	}

	function shutDown() {
		if (!optionsProg.isIn(display)) return;

		for (i in 0...categorySprites.length) {
			var categorySprite = categorySprites[i];
			categorySprite.c.aF = 0.0;
			optionsBuf.removeElement(categorySprite);
		}

		display.color = 0x00000000;
		display.removeProgram(optionsProg);

		active = false;
		Main.current.removeOptionsMenu();
	}

	function dispose() {
		close();
		shutDown();

		if (opened) {
			while (categorySprites.length != 0) {
				var categorySprite = categorySprites.pop();
				optionsBuf.removeElement(categorySprite);
				categorySprite = null;
			}
		}

		optionsDisplay.dispose();
	}
}