package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The first state of the game.
	This is the main menu where the player can select options such as story mode, freeplay, awards, credits, options, and exit.
	It is responsible for rendering the main menu and updating it based on the player's input.
	@since Development
**/
@:publicFields
class MainMenu implements State {
	static var optionAnims:Vector<String> = Vector.fromData(['story mode', 'freeplay', 'awards', 'credits', 'options', 'backspace to exit']);

	var display:CustomDisplay;
	var view:CustomDisplay;
	var roof:CustomDisplay;

	static var optionBuf:Buffer<Actor>;
	static var optionProg:Program;

	static var backgroundBuf:Buffer<Sprite>;
	static var backgroundProg:Program;

	static var watermarkTxt:Text;

	static var optionSelected(default, null):Int = 0;

	var disposed:Bool = false;
	var actions:ActionMap;

	function new() {}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		selectedAlpha = 1.0;
		for (i in 0...alphaLerps.length) alphaLerps[i] = 1.0;
		this.display = display;
		this.view = view;
		this.roof = roof;

		view.scroll.x = 0;
		view.scroll.y = 0;
		view.fov = 1.0;

		if (optionBuf == null) {
			optionBuf = new Buffer<Actor>(optionAnims.length);
		}

		if (optionProg == null) {
			optionProg = new Program(optionBuf);
			optionProg.blendEnabled = true;

			TextureSystem.setTexture(optionProg, "mainMenuSheet", "mainMenuSheet");

			for (i in 0...optionAnims.length) {
				var spr = new Actor(view, "mainMenu", 0, 0, 24, "", false);
				spr.playAnimation(optionAnims[i] + ' basic', true);
				spr.x = 20;
				if (i == 5) {
					optionYLerps[i] = spr.y = (Main.INITIAL_HEIGHT - 45) - spr.h;
				} else {
					optionYLerps[i] = spr.y = (45 + (125 * i)) - (6 * Math.min(optionSelected, optionAnims.length - 2));
				}
				spr.c.aF = 0.0;
				optionBuf.addElement(spr);
			}
		}

		if (backgroundBuf == null) {
			backgroundBuf = new Buffer<Sprite>(1);

			if (backgroundProg == null) {
				backgroundProg = new Program(backgroundBuf);
				backgroundProg.blendEnabled = true;

				TextureSystem.setTexture(backgroundProg, "mainMenuBGTex", "mainMenuBGTex");

				var bg = new Sprite();
				bg.clipWidth = bg.clipSizeX = bg.w = Main.INITIAL_WIDTH;
				bg.clipHeight = bg.clipSizeY = bg.h = Main.INITIAL_HEIGHT;
				backgroundBuf.addElement(bg);

				backgroundBuf.updateElement(bg);
			}
		}

		display.addProgram(optionProg);
		view.addProgram(backgroundProg);

		if (watermarkTxt == null) {
			watermarkTxt = new Text("mainMenuWatermarkTxt", 0, 0, view, "FV TEST BUILD");
			watermarkTxt.y = Main.INITIAL_HEIGHT - watermarkTxt.height;
		} else view.addProgram(watermarkTxt.program);

		haxe.Timer.delay(addEvents, 1);

		updateMenuOptions();

		optionBuf.update();

		actions = [
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_LEFT => { action: left },
			Controls.Action.UI_RIGHT => { action: right },
			Controls.Action.UI_ACCEPT => { action: accept }
		];
	}

	static var optionYLerps:Vector<Float> = new Vector<Float>(5, 1);
	static var alphaLerps:Vector<Float> = new Vector<Float>(6, 1);
	static var selectedAlpha:Float = 1.0;

	function update(deltaTime:Float) {
		for (i in 0...optionBuf.length) {
			var option = optionBuf.getElement(i);

			var t = Math.min(deltaTime * 0.0115, 1);
			if (t == 1) t = 0.0115; // When loading the freeplay menu the first time it gets stuck at 1.0 for a single frame

			if (i != alphaLerps.length - 1) {
				optionYLerps[i] = Tools.lerp(optionYLerps[i], (45 + (125 * i)) - (6 * Math.min(optionSelected, optionAnims.length - 2)), t);
				option.y = optionYLerps[i];
				option.x = (Main.INITIAL_WIDTH - option.w) * 0.5;
			}

			alphaLerps[i] = Tools.lerp(alphaLerps[i], selectedAlpha, t);
			option.c.aF = alphaLerps[i];
			optionBuf.updateElement(option);
		}
	}

	function updateMenuOptions() {
		for (i in 0...optionBuf.length) {
			var option = optionBuf.getElement(i);
			var anim = optionAnims[i];
			if (i == optionSelected) option.playAnimation(anim + ' white', true);
			else option.playAnimation(anim + ' basic', true);
			optionBuf.updateElement(option);
		}
	}

	function up(isDown:Bool, param:Int) {
		optionSelected--;
		if (optionSelected < 0) {
			optionSelected = optionBuf.length - 1;
		}
		updateMenuOptions();
	}

	function down(isDown:Bool, param:Int) {
		optionSelected++;
		if (optionSelected >= optionBuf.length) {
			optionSelected = 0;
		}
		updateMenuOptions();
	}

	function left(isDown:Bool, param:Int) {
		optionSelected = optionBuf.length - 1;
		updateMenuOptions();
	}

	function right(isDown:Bool, param:Int) {
		optionSelected = optionBuf.length - 2;
		updateMenuOptions();
	}

	function accept(isDown:Bool, param:Int) {
		if (!isDown || disposed) return;
		doIt();
	}

	function updateMenuOptions_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		if (!Main.current.fakeWindow.isMouseInsideApp()) return;

		optionSelected -= Math.floor(y);

		if (optionSelected >= optionBuf.length) {
			optionSelected = 0;
		}
		if (optionSelected < 0) {
			optionSelected = optionBuf.length - 1;
		}

		updateMenuOptions();
	}

	function doIt() {
		switch (optionSelected) {
			case 0: // STORY MODE
				selectedAlpha = 0.0;
				Main.current.storyMenu.open();
				removeEvents();
			case 1: // FREEPLAY
				selectedAlpha = 0.0;
				Main.current.freeplayMenu.open();
				removeEvents();
			case 2: // AWARDS
				// TODO
			case 3: // CREDITS
				// TODO
			case 4: // OPTIONS
				selectedAlpha = 0.0;
				Main.current.optionsMenu.open();
				removeEvents();
			case 5:
				Sys.exit(0);
		}
	}

	function doIt_mouse(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (button != LEFT || !Main.current.fakeWindow.isMouseInsideApp()) return;
		doIt();
	}

	function addEvents() {
		var window = lime.app.Application.current.window;

		Main.current.controls.bindTo(actions);
		window.onMouseWheel.add(updateMenuOptions_mouse);
		window.onMouseDown.add(doIt_mouse);
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseWheel.remove(updateMenuOptions_mouse);
		window.onMouseDown.remove(doIt_mouse);
	}

	function dispose() {
		removeEvents();

		view.removeProgram(watermarkTxt.program);

		display.removeProgram(optionProg);
		display = null;

		view.removeProgram(backgroundProg);
		view = null;

		Main.current.freeplayMenu.dispose();

		disposed = true;
	}
}