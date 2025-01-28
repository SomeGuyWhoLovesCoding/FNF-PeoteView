package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The playfield's options menu.
**/
@:publicFields
@:access(structures.PauseScreen)
@:access(Main)
class OptionsMenu {
	private static var display(default, null):CustomDisplay;
	static var optionsBuf(default, null):Buffer<OptionsSprite>;
	static var optionsProg(default, null):Program;

	var categorySelected(default, null):Int;
	var optionSelected(default, null):Int;

	var categorySprites(default, null):Array<OptionsSprite> = [];

	var active:Bool = false;

	var opened(default, null):Bool;

	static var optionsDisplay(default, null):OptionsDisplay;

	var actions(default, null):ActionMap;
	
	static function init(disp:CustomDisplay) {
		display = disp;

		if (optionsBuf == null) {
			optionsBuf = new Buffer<OptionsSprite>(15);
			optionsProg = new Program(optionsBuf);
			optionsProg.blendEnabled = true;

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
		optionsDisplay.reload(cast optionSelected);


		actions = [
			Controls.Action.UI_LEFT => { action: left },
			Controls.Action.UI_RIGHT => { action: right },
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
		];
	}

	var alphaLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, Math.min(deltaTime * 0.015, 1.0));

		for (i in 0...categorySprites.length) {
			var categorySprite = categorySprites[i];
			var originalC = categorySprite.c;
			if (i == categorySelected) categorySprite.c = Color.WHITE;
			else categorySprite.c = Color.GREY2;
			categorySprite.c.aF = alphaLerp;
			if (originalC != categorySprite.c) optionsBuf.updateElement(categorySprite);
		}

		optionsDisplay.update(deltaTime);
	}

	function open() {
		active = opened = true;
		Main.current.popupOptionsMenu();

		try {
			for (i in 0...categorySprites.length) {
				var categorySprite = categorySprites[i];
				if (i == categorySelected) categorySprite.c = Color.WHITE;
				else categorySprite.c = Color.GREY2;
				categorySprite.c.aF = 0.0;
				optionsBuf.addElement(categorySprite);
			}

			alphaLerp = 0.0;
		} catch (e) {}

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);
			
			window.onMouseDown.add(mousePress);
			window.onMouseWheel.add(moveCategory_mouse);
		}, 200);

		if (!optionsProg.isIn(display)) {
			display.addProgram(optionsProg);
		}
	}

	function close() {
		var mm = Main.current.mainMenu;
		var pf = Main.current.playField;

		if (mm != null) {
			MainMenu.selectedAlpha = 1.0;
			mm.addEvents();
		} else if (pf != null) {
			var pauseScreen = pf.pauseScreen;
			pauseScreen.atOptionsMenu = false;
			pauseScreen.addEvents();
		}

		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseDown.remove(mousePress);
		window.onMouseWheel.remove(moveCategory_mouse);

		opened = false;
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		optionSelected++;
		if (optionSelected >= optionsDisplay.options.length) {
			optionSelected = 0;
		}
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		optionSelected--;
		if (optionSelected < 0) {
			optionSelected = optionsDisplay.options.length - 1;
		}
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown) return;
		categorySelected--;
		if (categorySelected < 0) {
			categorySelected = categorySprites.length - 1;
		}
		optionsDisplay.reload(cast categorySelected);
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown) return;
		categorySelected++;
		if (categorySelected >= categorySprites.length) {
			categorySelected = 0;
		}
		optionsDisplay.reload(cast categorySelected);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button != RIGHT || !Main.current.fakeWindow.isMouseInsideApp()) return;
		close();
	}

	function moveCategory_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		if (!Main.current.fakeWindow.isMouseInsideApp()) return;

		categorySelected -= Math.floor(y);

		if (categorySelected >= categorySprites.length) {
			categorySelected = 0;
		}
		if (categorySelected < 0) {
			categorySelected = categorySprites.length - 1;
		}

		optionsDisplay.reload(cast categorySelected);
	}

	function shutDown() {
		if (!optionsProg.isIn(display)) return;

		for (i in 0...categorySprites.length) {
			var categorySprites = categorySprites[i];
			categorySprites.c.aF = 0.0;
			optionsBuf.removeElement(categorySprites);
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