package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The options submenu.
**/
@:publicFields
class OptionsMenu {
	static var display(default, null):CustomDisplay;
	static var optionsBuf(default, null):Buffer<OptionsSprite>;
	static var optionsProg(default, null):CustomProgram;

	var categoryNav(default, null):Navigation = new Navigation();
	var optionsNav(default, null):Navigation = new Navigation();
	var controlsNav(default, null):Navigation = new Navigation();

	var categorySprites(default, null):Array<OptionsSprite> = [];

	var active:Bool = false;
	var opened(default, null):Bool;
	var programsInDisplay:Bool = false;

	static var optionsDisplay(default, null):OptionsDisplay;
	var controlsText(default, null):OptionsControlsText;

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
		controlsText = new OptionsControlsText(this);

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
		onCategoryChanged();

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

	inline function isControlsCategory():Bool {
		return (categoryNav.value():OptionsCategorySelection) == CONTROLS;
	}

	function onCategoryChanged() {
		if (isControlsCategory()) {
			optionsDisplay.destroyOptions();
			controlsNav.setTo(0);
			controlsText.show();
		} else {
			controlsText.hide();
			optionsDisplay.reload(cast categoryNav.value());
		}
	}

	function update(deltaTime:Float) {
		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		var ratio = Math.min(deltaTime * 0.015, 1.0);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, ratio);

		for (i in 0...categorySprites.length) {
			var categorySprite = categorySprites[i];
			var originalLuminance = categorySprite.c.luminanceF;
			categorySprite.c.luminanceF = alphaLerp * (i != categoryNav.value() ? 0.5 : 1);
			categorySprite.c.aF = alphaLerp;
			if (originalLuminance != categorySprite.c.luminanceF) optionsBuf.updateElement(categorySprite);
		}

		if (isControlsCategory()) {
			controlsText.refresh();
		} else {
			optionsDisplay.update(deltaTime);
		}
	}

	function open() {
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

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);
			Main.current.mouseDown = mousePress;
			window.onMouseWheel.add(mouseWheel);
			#if FV_LIME_FORK
			window.onKeyDownPrecise.add(controlsKeyCapture);
			#else
			window.onKeyDown.add(controlsKeyCapture);
			#end
		}, 1);

		if (!optionsProg.isIn(display)) {
			display.addProgram(optionsProg);
			programsInDisplay = true;
		}

		if (isControlsCategory()) {
			controlsText.show();
		}
	}

	function close() {
		opened = false;

		var mm = Main.current.mainMenu;
		var pf = Main.current.playField;
		var window = lime.app.Application.current.window;

		Main.current.controls.unBind();
		Main.current.mouseDown = null;
		window.onMouseWheel.remove(mouseWheel);
		#if FV_LIME_FORK
		window.onKeyDownPrecise.remove(controlsKeyCapture);
		#else
		window.onKeyDown.remove(controlsKeyCapture);
		#end

		if (mm != null) {
			MainMenu.selectedAlpha = 1.0;
			mm.addEvents();
		} else if (pf != null) {
			pf.pauseScreen.onOptionsMenuClose();
		}
		
		// Remove programs from display but keep in memory
		if (programsInDisplay && optionsProg.isIn(display)) {
			display.removeProgram(optionsProg);
			programsInDisplay = false;
		}
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		if (isControlsCategory()) {
			controlsText.navigateBack();
			return;
		}
		close();
		Main.current.playCancelSound();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown || controlsText.waitingForKey || controlsText.inputMode) return;
		if (isControlsCategory()) {
			controlsText.navigateDown();
			return;
		}
		optionsNav.scroll(1);
		optionsNav.resetIfOver(optionsDisplay.options.length);
		Main.current.playScrollSound();
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown || controlsText.waitingForKey || controlsText.inputMode) return;
		if (isControlsCategory()) {
			controlsText.navigateUp();
			return;
		}
		optionsNav.scroll(-1);
		optionsNav.resetIfUnder(optionsDisplay.options.length - 1);
		Main.current.playScrollSound();
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown || controlsText.waitingForKey) return;
		optionsNav.setTo(0);
		categoryNav.scroll(-1);
		categoryNav.resetIfUnder(categorySprites.length - 1);
		onCategoryChanged();
		Main.current.playScrollSound();
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown || controlsText.waitingForKey) return;
		optionsNav.setTo(0);
		categoryNav.scroll(1);
		categoryNav.resetIfOver(categorySprites.length);
		onCategoryChanged();
		Main.current.playScrollSound();
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
		if (isControlsCategory()) {
			controlsText.onEnter();
			Main.current.playCancelSound();
			return;
		}
		optionsDisplay.enter();
		Main.current.playCancelSound();
	}

	function controlsKeyCapture(code:KeyCode, mod:KeyModifier
		#if FV_LIME_FORK
		, timestamp:Float
		#end
	) {
		if (!opened) return; // 🔥 MUST BE FIRST
		if (!isControlsCategory()) return;
		if (!controlsText.waitingForKey && !controlsText.inputMode) return;
		controlsText.applyKey(code);
		if (controlsText.waitingForKey) Main.current.playConfirmSound();
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button == LEFT) enter(true, 0);
		if (button != RIGHT) return;
		close();
		Main.current.playScrollSound();
	}

	function mouseWheel(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		if (controlsText.waitingForKey) return;
		if (isControlsCategory()) {
			controlsNav.scroll(-Math.floor(y));
			controlsNav.resetIfBoth(OptionsControlsText.ROW_COUNT, OptionsControlsText.ROW_COUNT - 1);
			Main.current.playScrollSound();
			return;
		}
		categoryNav.scroll(-Math.floor(y));
		categoryNav.resetIfBoth(categorySprites.length, categorySprites.length - 1);
		onCategoryChanged();
		Main.current.playScrollSound();
	}

	function shutDown() {
		// Only proceed if programs are still in display (shouldn't happen after close())
		if (!optionsProg.isIn(display)) return;

		controlsText.hide();

		for (i in 0...categorySprites.length) {
			var categorySprite = categorySprites[i];
			categorySprite.c.aF = 0.0;
			optionsBuf.removeElement(categorySprite);
		}

		display.color = 0x00000000;
		display.removeProgram(optionsProg);
		programsInDisplay = false;

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

		controlsText.hide();
		optionsDisplay.dispose();
	}
}
