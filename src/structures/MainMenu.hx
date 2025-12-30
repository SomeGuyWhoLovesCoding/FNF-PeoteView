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
	static var optionAnims:Array<String> = ['story mode', 'freeplay', /*'awards', 'credits',*/ 'options', 'backspace to exit'];

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

		if (watermarkTxt == null) {
			watermarkTxt = new Text("mainMenuWatermarkTxt", 0, 0, view, "Funkin' View - Prototype");
			watermarkTxt.y = Main.INITIAL_HEIGHT - watermarkTxt.height - 3;
			watermarkTxt.x = 3;
			watermarkTxt.outlineColor = 0x000000FF;
			watermarkTxt.outlineSize = 0.12; // Usually the default text+ outline size on DaVinci Resolve
		}

		if (optionBuf == null) {
			optionBuf = new Buffer<Actor>(optionAnims.length);
		}

		if (backgroundBuf == null) {
			backgroundBuf = new Buffer<Sprite>(1);

			if (backgroundProg == null) {
				backgroundProg = new Program(backgroundBuf);
				backgroundProg.blendEnabled = true;
				backgroundProg.blendSrc = backgroundProg.blendSrcAlpha = BlendFactor.ONE;
				backgroundProg.blendDst = backgroundProg.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

				TextureSystem.setTexture(backgroundProg, "mainMenuBGTex", "mainMenuBGTex");

				var bg = new Sprite();
				bg.clipWidth = bg.clipSizeX = bg.w = Main.INITIAL_WIDTH;
				bg.clipHeight = bg.clipSizeY = bg.h = Main.INITIAL_HEIGHT;
				backgroundBuf.addElement(bg);

				backgroundBuf.updateElement(bg);
			}
		}

		if (optionProg == null) {
			optionProg = new Program(optionBuf);
			optionProg.blendEnabled = true;
			optionProg.blendSrc = optionProg.blendSrcAlpha = BlendFactor.ONE;
			optionProg.blendDst = optionProg.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

			TextureSystem.setTexture(optionProg, "mainMenuSheet", "mainMenuSheet");

			for (i in 0...optionAnims.length) {
				var spr = new Actor(view, null, "images/mainMenu", 0, 0, 24, "", false);
				spr.playAnimation(optionAnims[i] + ' basic', true);
				if (optionAnims[i] == 'backspace to exit') {
					spr.x = 20;
					spr.y = Main.current.peoteView.height - spr.h - watermarkTxt.height - 10;
				} else {
					spr.x = 20;
					if (i == 5) {
						optionYLerps[i] = spr.y = (Main.INITIAL_HEIGHT - 55) - spr.h;
					} else {
						optionYLerps[i] = spr.y = optionYFormula(i, optionSelected);
					}
				}
				spr.c.aF = 0.0;
				optionBuf.addElement(spr);
			}
		}

		display.addProgram(optionProg);
		view.addProgram(backgroundProg);

		if (watermarkTxt != null) {
			view.addProgram(watermarkTxt.program);
		} else {
			view.removeProgram(watermarkTxt.program);
			view.addProgram(watermarkTxt.program);
		}

		haxe.Timer.delay(addEvents, 100);

		actions = [
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_LEFT => { action: left },
			Controls.Action.UI_RIGHT => { action: right },
			Controls.Action.UI_ACCEPT => { action: accept }
		];
	}

	static var optionYLerps:Array<Float> = [for (i in 0...5) 1];
	static var alphaLerps:Array<Float> = [for (i in 0...6) 1];
	static var selectedAlpha:Float = 1.0;

	/**
	 * This is here to clear up duplicated code.
	 * @param i `i`.
	 * @param o `optionSelected`.
	 */
	inline function optionYFormula(i:Int, o:Int) {
		return (
			(150 -
				(24 * (optionAnims.length - 1)
			)
		) + (125 * i)
		) - (
			6 * Math.min(o, optionAnims.length - 2)
		);
	}

	function update(deltaTime:Float) {
		for (i in 0...optionBuf.length) {
			var option = optionBuf.getElement(i);

			var t = Math.min(deltaTime * 0.0115, 1);
			if (t == 1) t = (1/lime.app.Application.current.window.frameRate) * 0.0115;

			var anim = optionAnims[i];
			if (i == optionSelected) option.playAnimation(anim + ' white', true);
			else option.playAnimation(anim + ' basic', true);

			if (anim != 'backspace to exit') {
				optionYLerps[i] = Tools.lerp(optionYLerps[i], optionYFormula(i, optionSelected), t);
				option.y = optionYLerps[i];
				option.x = (Main.INITIAL_WIDTH - option.w) * 0.5;
			}

			var alpha = alphaLerps[i] = Tools.lerp(alphaLerps[i], selectedAlpha, t);
			option.c.aF = alpha;
			option.c.luminanceF = alpha;
			optionBuf.updateElement(option);
		}
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown || disposed) return;
		optionSelected--;
		if (optionSelected < 0) {
			optionSelected = optionBuf.length - 1;
		}
		Main.current.playScrollSound();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown || disposed) return;
		optionSelected++;
		if (optionSelected >= optionBuf.length) {
			optionSelected = 0;
		}
		Main.current.playScrollSound();
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown || disposed) return;
		optionSelected = optionBuf.length - 1;
		Main.current.playScrollSound();
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown || disposed) return;
		optionSelected = optionBuf.length - 2;
		Main.current.playScrollSound();
	}

	function accept(isDown:Bool, param:Int) {
		if (!isDown || disposed) return;
		doIt();
	}

	function updateMenuOptions_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		optionSelected -= Math.floor(y);

		if (optionSelected >= optionBuf.length) {
			optionSelected = 0;
		}
		if (optionSelected < 0) {
			optionSelected = optionBuf.length - 1;
		}
		Main.current.playScrollSound();
	}

	function doIt() {
		var optionString = optionAnims[optionSelected];
		switch (optionString) {
			case 'story mode': // STORY MODE
				// TODO
				Main.current.playConfirmSound();
			case 'freeplay': // FREEPLAY
				selectedAlpha = 0.0;
				Main.current.freeplayMenu.open();
				removeEvents();
				Main.current.playScrollSound();
			case 'awards': // AWARDS
				// TODO
				Main.current.playConfirmSound();
			case 'credits': // CREDITS
				// TODO
				Main.current.playConfirmSound();
			case 'options': // OPTIONS
				selectedAlpha = 0.0;
				Main.current.optionsMenu.open();
				removeEvents();
				Main.current.playScrollSound();
			case 'backspace to exit':
				// TODO: ONCE TITLE SCREEN IS DONE ENOUGH, I WILL REPLACE THIS
				Sys.exit(0);
		}
	}

	function doIt_mouse(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		//Sys.println("Fuck you game 2");
		if (button != MouseButton.LEFT) return;
		doIt();
	}

	function addEvents() {
		var window = lime.app.Application.current.window;

		Main.current.controls.bindTo(actions);
		window.onMouseWheel.add(updateMenuOptions_mouse);
		Main.current.mouseDown = doIt_mouse;
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseWheel.remove(updateMenuOptions_mouse);
		Main.current.mouseDown = null;
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
