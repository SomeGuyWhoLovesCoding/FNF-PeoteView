package overlay;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The playfield's pause menu.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
	It is used to pause the game and display options such as resuming, restarting, changing options, and exiting to the main menu.
	It is responsible for rendering the pause menu and updating it based on the player's input.
	@since Development
**/
@:publicFields
class PauseScreen {
	var disposed(default, null):Bool = false;

	private static var display(default, null):CustomDisplay;
	static var pauseBuf(default, null):Buffer<StoryModeSprite>;
	static var pauseProg(default, null):CustomProgram;

	var pauseOptions(default, null):Array<StoryModeSprite> = [];
	var diffText(default, null):StoryModeSprite;

	var pauseNav(default, null):Navigation = new Navigation();
	var opened(default, null):Bool;
	var atOptionsMenu(default, null):Bool;
	var actions:ActionMap;

	static function init(disp:CustomDisplay) {
		display = disp;

		if (pauseBuf == null) {
			pauseBuf = new Buffer<StoryModeSprite>(5);
			pauseProg = new CustomProgram(pauseBuf);

			var tex = TextureSystem.getTexture("storyModeSheet");
			StoryModeSprite.init(pauseProg, "storyModeSheet", tex);
		}
	}

	function new(difficulty:Difficulty) {
		var currentY = 200;
		for (i in 0...4) {
			var option = new StoryModeSprite();
			option.type = PAUSE_OPTION;
			option.changeID(i);
			option.x = 45;
			option.y = currentY;
			currentY += Math.floor(option.h) + 2;
			pauseOptions.push(option);
		}

		diffText = new StoryModeSprite();
		diffText.type = DIFF_TEXT;
		diffText.changeID(cast difficulty);
		diffText.x = Main.INITIAL_WIDTH - (diffText.w - 1);
		diffText.y = 1;

		actions = [
			Controls.Action.UI_UP => {action: up},
			Controls.Action.UI_DOWN => {action: down},
			Controls.Action.UI_ACCEPT => {action: accept},
			Controls.Action.UI_BACK => {action: back}
		];
	}

	var alphaLerp:Float = 0.0;
	var bgAlphaLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (display == null)
			return;

		if (!opened && display.color.aF == 0) {
			shutDown();
			return;
		}

		var ratio = Math.min(deltaTime * 0.015, 1.0);
		if (ratio == 1)
			ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, (opened && !atOptionsMenu) ? 1.0 : 0.0, ratio);
		bgAlphaLerp = Tools.lerp(bgAlphaLerp, opened ? 1.0 : 0.0, ratio);

		var c = display.color;
		c.aF = bgAlphaLerp * 0.5;
		display.color = c;

		for (i in 0...pauseOptions.length) {
			var pauseOption = pauseOptions[i];
			var originalC = pauseOption.c;
			pauseOption.c.aF = alphaLerp;
			pauseOption.c.luminanceF = alphaLerp * (i == pauseNav.value() ? 1.0 : 0.6);
			if (originalC != pauseOption.c) {
				if (@:privateAccess pauseOption.bytePos != -1) {
					pauseBuf.updateElement(pauseOption);
				}
			}
		}

		diffText.c.aF = alphaLerp;
		diffText.c.luminanceF = alphaLerp;
		if (@:privateAccess diffText.bytePos != -1) {
			pauseBuf.updateElement(diffText);
		}
	}

	function down(isDown:Bool, param:Int) {
		pauseNav.scroll(1);
		pauseNav.resetIfOver(pauseOptions.length);
		Main.current.playScrollSound();
	}

	function up(isDown:Bool, param:Int) {
		pauseNav.scroll(-1);
		pauseNav.resetIfUnder(pauseOptions.length - 1);
		Main.current.playScrollSound();
	}

	function accept(isDown:Bool, param:Int) {
		doIt();
	}

	function back(isDown:Bool, param:Int) {
		if (Main.current.playField != null)
			Main.current.playField.resume();
		else
			removeEvents();
	}

	function doIt() {
		switch (pauseNav.value()) {
			case 0: // RESUME
				back(true, 0);
			case 1: // RESTART
				Main.switchState(GAMEPLAY);
			case 2: // OPTIONS
				Main.current.playScrollSound();
				Main.current.optionsMenu.open();
				atOptionsMenu = true;
				removeEvents();
			case 3: // EXIT
				Main.current.playCancelSound();
				Main.uponSongExit();
		}
	}

	function mouseDown(x:Float, y:Float, button:MouseButton) {
		var peoteView = Main.current.peoteView;
		x = display.localX(x, peoteView);
		y = display.localY(y, peoteView);
		switch (button) {
			case LEFT:
				for (i in 0...pauseOptions.length) {
					var option = pauseOptions[i];
					if (x >= option.x && x <= option.x + option.w && y >= option.y && y <= option.y + option.h) {
						pauseNav.setTo(i);
						doIt();
						return;
					}
				}
			case RIGHT:
				back(true, 0);
			default:
		}
	}

	function moveOption_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		var peoteView = Main.current.peoteView;
		pauseNav.scroll(-Math.floor(y));
		pauseNav.resetIfBoth(pauseBuf.length - 1, pauseBuf.length - 2);
		Main.current.playScrollSound();
	}

	function open() {
		opened = true;

		try {
			for (i in 0...pauseOptions.length) {
				var pauseOption = pauseOptions[i];
				if (i == pauseNav.value())
					pauseOption.c = Color.GREY3;
				else
					pauseOption.c = Color.WHITE;
				pauseOption.c.aF = 0.0;
				pauseOption.c.luminanceF = 0.0;
				pauseBuf.addElement(pauseOptions[i]);
			}

			alphaLerp = 0.0;
			diffText.c.aF = 0.0;
			diffText.c.luminanceF = 0.0;
			pauseBuf.addElement(diffText);
		} catch (e) {}

		Tools.forSync(addEvents);

		if (!pauseProg.isIn(display)) {
			display.addProgram(pauseProg);
		}
	}

	var eventsActive(default, null):Bool = false;

	function addEvents() {
		if (eventsActive)
			return;
		eventsActive = true;
		var window = lime.app.Application.current.window;
		Main.current.controls.setMode(ControlsMode.PAUSE, actions);
		window.onMouseDown.add(mouseDown);
		window.onMouseWheel.add(moveOption_mouse);
	}

	function removeEvents() {
		if (!eventsActive)
			return;
		eventsActive = false;
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseDown.remove(mouseDown);
		window.onMouseWheel.remove(moveOption_mouse);
	}

	inline function onOptionsMenuClose() {
		atOptionsMenu = false;
		Tools.forSync(addEvents);
	}

	function close() {
		opened = false;
		removeEvents();
	}

	function shutDown() {
		if (!pauseProg.isIn(display))
			return;

		try {
			for (i in 0...pauseOptions.length) {
				var pauseOption = pauseOptions[i];
				pauseOption.c.aF = 0.0;
				pauseOption.c.luminanceF = 0.0;
				pauseBuf.removeElement(pauseOption);
			}

			pauseBuf.removeElement(diffText);
		} catch (e) {}

		display.color = 0x00000000;
		display.removeProgram(pauseProg);
	}

	function dispose() {
		close();
		shutDown();

		if (opened) {
			try {
				while (pauseOptions.length != 0) {
					var pauseOption = pauseOptions.pop();
					pauseBuf.removeElement(pauseOption);
					pauseOption = null;
				}
				pauseBuf.removeElement(diffText);
				diffText = null;
			} catch (e) {}
		}

		disposed = true;
	}
}
