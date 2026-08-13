package structures;

import input2action.ActionMap;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The first state of the game.
	This is the main menu where the player can select options such as story mode, freeplay, awards, credits, options, and exit.
	It is responsible for rendering the main menu and updating it based on the player's input.
	@since Development
**/
@:publicFields
class MainMenu {
	inline static var fnfpVer = '0.94';

	static var optionAnims:Array<String> = [
		'story mode',
		'freeplay', /*'awards', 'credits',*/
		'options',
		'backspace to exit'
	];

	var display:CustomDisplay;
	var view:CustomDisplay;
	var roof:CustomDisplay;

	static var optionBuf:Buffer<Actor>;
	static var optionProg:CustomProgram;

	static var backgroundBuf:Buffer<Sprite>;
	static var backgroundProg:CustomProgram;

	static var watermarkTxt:Text;

	static var nav(default, null):Navigation = new Navigation();

	var disposed:Bool = false;
	var actions:ActionMap;
	var pendingDoIt:Bool = false;

	function new() {}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		selectedAlpha = 1.0;
		for (i in 0...alphaLerps.length)
			alphaLerps[i] = 1.0;
		this.display = display;
		this.view = view;
		this.roof = roof;

		view.scroll.x = 0;
		view.scroll.y = 0;
		view.fov = 1.0;

		if (optionBuf == null) {
			optionBuf = new Buffer<Actor>(optionAnims.length);
		}

		if (backgroundBuf == null) {
			backgroundBuf = new Buffer<Sprite>(1);

			if (backgroundProg == null) {
				backgroundProg = new CustomProgram(backgroundBuf);

				TextureSystem.setTexture(backgroundProg, "mainMenuBGTex", "mainMenuBGTex");

				var bg = new Sprite();
				bg.clipWidth = bg.clipSizeX = bg.w = Main.INITIAL_WIDTH;
				bg.clipHeight = bg.clipSizeY = bg.h = Main.INITIAL_HEIGHT;
				backgroundBuf.addElement(bg);

				backgroundBuf.updateElement(bg);
			}
		}

		var watermarkText = 'Press 7 (DEBUG) to test the Noteskin Editor and be surprised\nFunkin\' View - Version $fnfpVer';

		if (watermarkTxt == null) {
			watermarkTxt = new Text("mainMenuWatermarkTxt", 0, 0, display, watermarkText);
			watermarkTxt.scale = 0.667;
			watermarkTxt.multiline = true;
			watermarkTxt.x = 3;
			watermarkTxt.outlineColor = 0x000000FF;
			watermarkTxt.outlineSize = 1.15;
		}

		if (!Main.UP_TO_DATE) {
			watermarkTxt.text = '[ NO WIFI / OUTDATED VERSION - PLEASE GO TO GAMEBANA PAGE & RUN INSTALLER TO UPDATE ]\n$watermarkText';
		}

		watermarkTxt.y = Main.INITIAL_HEIGHT - watermarkTxt.height - 3;

		if (optionProg == null) {
			var texName = "mainMenuSheet";
			optionProg = new CustomProgram(optionBuf);

			TextureSystem.setTexture(optionProg, texName, texName);

			for (i in 0...optionAnims.length) {
				var spr = Actor.create(view, null, "images/mainMenu", 0, 0, 24, "", false);
				spr.playAnimation(optionAnims[i] + ' basic', true);
				if (optionAnims[i] == 'backspace to exit') {
					spr.x = 20;
					spr.y = Main.current.peoteView.height - spr.h - watermarkTxt.height - 10;
				} else {
					spr.x = 20;
					if (i == 5) {
						optionYLerps[i] = spr.y = (Main.INITIAL_HEIGHT - 55) - spr.h;
					} else {
						optionYLerps[i] = spr.y = optionYFormula(i, nav.value());
					}
				}
				spr.color.aF = 0.0;
				optionBuf.addElement(spr);
			}

			if (Main.current.upscale) {
				optionProg.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER);
				optionProg.setColorFormula('
                                        iconPixel(${texName}_ID, vTexCoord, vec2(spriteW, 0.0), vec2(spriteH, 0.0)) * color
                                ');
			}
		}

		view.addProgram(backgroundProg);
		display.addProgram(optionProg);

		watermarkTxt.addProgram();

		actions = [
			Controls.Action.UI_DOWN => {action: down},
			Controls.Action.UI_UP => {action: up},
			Controls.Action.UI_LEFT => {action: left},
			Controls.Action.UI_RIGHT => {action: right},
			Controls.Action.UI_ACCEPT => {action: accept},
			Controls.Action.GAME_DEBUG => {action: goToEditors}
		];

		addEvents();
	}

	static var optionYLerps:Array<Float> = [for (i in 0...5) 1];
	static var alphaLerps:Array<Float> = [for (i in 0...6) 1];
	static var selectedAlpha:Float = 1.0;
	static var lastNavValue:Int = -1;

	/**
	 * This is here to clear up duplicated code.
	 * @param i `i`.
	 * @param o `nav.value()`.
	 */
	inline function optionYFormula(i:Int, o:Int) {
		return ((150 - (24 * (optionAnims.length - 1))) + (125 * i)) - (6 * Math.min(o, optionAnims.length - 2));
	}

	function update(deltaTime:Float) {
		if (pendingDoIt) {
			pendingDoIt = false;
			doIt();
		}
		if (optionBuf == null)
			return; // stupid

		var cur = nav.value();
		if (cur != lastNavValue) {
			lastNavValue = cur;
			for (i in 0...optionBuf.length) {
				var opt = optionBuf.getElement(i);
				if (opt == null) continue;
				opt.playAnimation(optionAnims[i] + (i == cur ? ' white' : ' basic'), true);
			}
		}

		for (i in 0...optionBuf.length) {
			var option = optionBuf.getElement(i);
			if (option == null) continue;

			var t = Math.min(deltaTime * 0.0115, 1);
			if (t == 1)
				t = (1 / lime.app.Application.current.window.frameRate) * 0.0115;

			var anim = optionAnims[i];

			if (anim != 'backspace to exit') {
				optionYLerps[i] = Tools.lerp(optionYLerps[i], optionYFormula(i, cur), t);
				option.y = optionYLerps[i];
				option.x = (Main.INITIAL_WIDTH - option.w) * 0.5;
			}

			var alpha = alphaLerps[i] = Tools.lerp(alphaLerps[i], selectedAlpha, t);
			option.color.aF = alpha;
			option.color.luminanceF = alpha;
		}
		optionBuf.update();
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		nav.scroll(-1);
		nav.resetIfUnder(optionBuf.length - 1);
		Main.current.playScrollSound();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		nav.scroll(1);
		nav.resetIfOver(optionBuf.length);
		Main.current.playScrollSound();
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		nav.setTo(optionBuf.length - 1);
		Main.current.playScrollSound();
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		nav.setTo(optionBuf.length - 2);
		Main.current.playScrollSound();
	}

	function accept(isDown:Bool, param:Int) {
		if (!isDown || disposed)
			return;
		doIt();
	}

	function updateMenuOptions_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		if (disposed || optionBuf == null)
			return;
		nav.scroll(-Math.floor(y));
		nav.resetIfBoth(optionBuf.length, optionBuf.length - 1);
		Main.current.playScrollSound();
	}

	function doIt() {
		var optionString = optionAnims[nav.value()];
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
			case 'editors': // EDITORS
				selectedAlpha = 0.0;
				removeEvents();
				Main.switchState(EDITOR_MENU);
				Main.current.playScrollSound();
			case 'backspace to exit':
				// TODO: ONCE TITLE SCREEN IS DONE ENOUGH, I WILL REPLACE THIS
				Sys.exit(0);
		}
	}

	function mouseDown(x:Float, y:Float, button:MouseButton) {
		if (disposed || optionBuf == null || view == null)
			return;
		//trace('.');
		var peoteView = Main.current.peoteView;
		//trace('.');
		x = view.localX(x, peoteView);
		//trace('.');
		y = view.localY(y, peoteView);
		//trace('.');
		if (button != MouseButton.LEFT)
			return;
		//trace('.');
		for (i in 0...optionBuf.length) {
		//trace(i);
			var option = optionBuf.getElement(i);
			trace(option + " " + i);
			if (option == null) return;
			if (x >= option.x && x <= option.x + option.w && y >= (option.y - 15) && y <= option.y + (option.h - 15)) {
				nav.setTo(i);
				return;
			}
		}
	}

	function mouseUp(x:Float, y:Float, button:MouseButton) {
		//trace('.');
		if (disposed || optionBuf == null || view == null)
			return;
		//trace('.');
		var peoteView = Main.current.peoteView;
		//trace('.');
		x = view.localX(x, peoteView);
		//trace('.');
		y = view.localY(y, peoteView);
		//trace('.');
		if (button != MouseButton.LEFT)
			return;
		//trace('.');
		for (i in 0...optionBuf.length) {
		//trace(i);
			var option = optionBuf.getElement(i);
			trace(option + " " + i);
			if (option == null) return;
			if (x >= option.x && x <= option.x + option.w && y >= (option.y - 15) && y <= option.y + (option.h - 15) && i == nav.value()) {
				// Can't call doIt() here directly, because doIt() -> removeEvents()
				// -> window.onMouseUp.remove(mouseUp) mutates lime's listener
				// arrays while onMouseUp dispatch is still iterating them.
				// Timer.delay is not reliable for this (fires same-frame on HL release).
				pendingDoIt = true;
				break;
			}
		}
	}

	function goToEditors(isDown:Bool, param:Int) {
		if (!isDown)
			return;
		//trace('.');
		removeEvents();
		//trace('.');
		Main.switchState(EDITOR_MENU);
	}

	function addEvents() {
		var window = lime.app.Application.current.window;

		//trace('.');
		Main.current.controls.bindTo(actions);
		//trace('.');
		window.onMouseDown.add(mouseDown);
		//trace('.');
		window.onMouseWheel.add(updateMenuOptions_mouse);
		//trace('.');
		window.onMouseUp.add(mouseUp);
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		//trace('.');
		Main.current.controls.unBind();
		//trace('.');
		window.onMouseDown.remove(mouseDown);
		//trace('.');
		window.onMouseWheel.remove(updateMenuOptions_mouse);
		//trace('.');
		window.onMouseUp.remove(mouseUp);
	}

	function dispose() {
		removeEvents();

		//trace('.');
		watermarkTxt.removeProgram();

		// dont do this
		/*if (Main.current.upscale) {
			optionProg.injectIntoFragmentShader('');
			optionProg.setColorFormula('c');
		}*/

		//trace('.');
		display.removeProgram(optionProg);
		display = null;

		//trace('.');
		view.removeProgram(backgroundProg);
		view = null;

		disposed = true;
	}
}
