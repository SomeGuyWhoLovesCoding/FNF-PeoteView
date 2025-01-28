package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The playfield's pause menu.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
**/
@:publicFields
class PauseScreen {
	private static var display(default, null):CustomDisplay;
	static var pauseBuf(default, null):Buffer<PauseSprite>;
	static var pauseProg(default, null):Program;

	var pauseOptions(default, null):Array<PauseSprite> = [];
	var diffText(default, null):PauseSprite;

	var pauseOptionSelected(default, null):Int = 0;
	var opened(default, null):Bool;
	var atOptionsMenu(default, null):Bool;
	var actions:ActionMap;

	static function init(disp:CustomDisplay) {
		display = disp;

		if (pauseBuf == null) {
			pauseBuf = new Buffer<PauseSprite>(5);
			pauseProg = new Program(pauseBuf);
			pauseProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("pauseScreenSheet");
			PauseSprite.init(pauseProg, "pauseScreenSheet", tex);
		}
	}

	function new(difficulty:Difficulty) {
		var currentY = 200;
		for (i in 0...4) {
			var option = new PauseSprite();
			option.type = PAUSE_OPTION;
			option.changeID(i);
			option.x = 45;
			option.y = currentY;
			currentY += Math.floor(option.h) + 2;
			pauseOptions.push(option);
		}

		diffText = new PauseSprite();
		diffText.type = DIFF_TEXT;
		diffText.changeID(cast difficulty);
		diffText.x = Main.INITIAL_WIDTH - (diffText.w - 1);
		diffText.y = 1;

		actions = [
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_ACCEPT => { action: accept },
			Controls.Action.UI_BACK => { action: back },
		];
	}

	var alphaLerp:Float = 0.0;
	var bgAlphaLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (!opened && display.color.aF == 0) {
			shutDown();
			return;
		}

		alphaLerp = Tools.lerp(alphaLerp, (opened && !atOptionsMenu) ? 1.0 : 0.0, Math.min(deltaTime * 0.015, 1.0));
		bgAlphaLerp = Tools.lerp(bgAlphaLerp, opened ? 1.0 : 0.0, Math.min(deltaTime * 0.015, 1.0));

		display.color.aF = bgAlphaLerp * 0.5;
		display.color = display.color; // Set it by itself so it actually sets the alpha of the display's background

		for (i in 0...pauseOptions.length) {
			var pauseOption = pauseOptions[i];
			var originalC = pauseOption.c;
			if (i == pauseOptionSelected) pauseOption.c = Color.YELLOW;
			else pauseOption.c = Color.WHITE;
			pauseOption.c.aF = alphaLerp;
			if (originalC != pauseOption.c) pauseBuf.updateElement(pauseOption);
		}

		diffText.c.aF = alphaLerp;
		pauseBuf.updateElement(diffText);
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		pauseOptionSelected++;
		if (pauseOptionSelected >= pauseOptions.length) {
			pauseOptionSelected = 0;
		}
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		pauseOptionSelected--;
		if (pauseOptionSelected < 0) {
			pauseOptionSelected = pauseOptions.length - 1;
		}
	}

	function accept(isDown:Bool, param:Int) {
		if (!isDown) return;
		doIt();
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		Main.current.playField.resume();
	}

	function doIt() {
		switch (pauseOptionSelected) {
			case 0: // RESUME
				back(true, 0);
			case 1: // RESTART
				Main.switchState(GAMEPLAY);
			case 2: // OPTIONS
				Main.current.optionsMenu.open();
				atOptionsMenu = true;
				removeEvents();
			case 3: // EXIT
				Main.switchState(MAIN_MENU);
		}
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (!Main.current.fakeWindow.isMouseInsideApp()) return;
		if (button == LEFT) doIt();
		else back(true, 0);
	}

	function moveOption_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		pauseOptionSelected -= Math.floor(y);

		if (pauseOptionSelected >= pauseBuf.length - 1) {
			pauseOptionSelected = 0;
		}
		if (pauseOptionSelected < 0) {
			pauseOptionSelected = pauseBuf.length - 2;
		}
	}

	function open() {
		opened = true;

		try {
			for (i in 0...pauseOptions.length) {
				var pauseOption = pauseOptions[i];
				if (i == pauseOptionSelected) pauseOption.c = Color.YELLOW;
				else pauseOption.c = Color.WHITE;
				pauseOption.c.aF = 0.0;
				pauseBuf.addElement(pauseOptions[i]);
			}

			alphaLerp = diffText.c.aF = 0.0;
			pauseBuf.addElement(diffText);
		} catch (e) {}

		haxe.Timer.delay(addEvents, 1);

		if (!pauseProg.isIn(display)) {
			display.addProgram(pauseProg);
		}
	}

	function addEvents() {
		var window = lime.app.Application.current.window;
		Main.current.controls.bindTo(actions);
		window.onMouseDown.add(mousePress);
		window.onMouseWheel.add(moveOption_mouse);
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseDown.remove(mousePress);
		window.onMouseWheel.remove(moveOption_mouse);
	}

	function close() {
		removeEvents();

		opened = false;
	}

	function shutDown() {
		if (!pauseProg.isIn(display)) return;

		for (i in 0...pauseOptions.length) {
			var pauseOption = pauseOptions[i];
			pauseOption.c.aF = 0.0;
			pauseBuf.removeElement(pauseOption);
		}

		pauseBuf.removeElement(diffText);

		display.color = 0x00000000;
		display.removeProgram(pauseProg);
	}

	function dispose() {
		close();
		shutDown();

		if (opened) {
			while (pauseOptions.length != 0) {
				var pauseOption = pauseOptions.pop();
				pauseBuf.removeElement(pauseOption);
				pauseOption = null;
			}
			pauseBuf.removeElement(diffText);
			diffText = null;
		}
	}
}