package;

import lime.ui.MouseButton;
import sys.io.File;
import sys.io.FileOutput;
import haxe.CallStack;
import lime.app.Application;
import lime.ui.Window;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.Gamepad;

@:publicFields
class Main extends Application
{
	/**
	 * FNF's standard resolution is 720p.
	 * Resizing the window won't make the game look crispier
	 * unless you create a higher resolution version of your images.
	**/
	static inline var INITIAL_WIDTH = 1280;
	static inline var INITIAL_HEIGHT = 720;
	static var VARIABLE_WIDTH(get, never):Int;
	static var VARIABLE_HEIGHT(get, never):Int;

	inline static function get_VARIABLE_WIDTH() {
		return current.peoteView.width;
	}

	inline static function get_VARIABLE_HEIGHT() {
		return current.peoteView.height;
	}

	// Internal variable for checking if the game has booted up
	private var _started(default, null):Bool;

	override function onWindowCreate()
	{
		var titleBarColor:Color = SaveData.state.graphics.customTitleBarColor;
		#if windows
		Titlebar.setTitlebarColor(titleBarColor.r, titleBarColor.g, titleBarColor.b);
		Titlebar.setTitleFontColor(0, 0, 0);
		Titlebar.setButtonFontColor(20, 10, 30);
		Titlebar.setTitleFont("Unispace-Bold", sys.FileSystem.absolutePath('assets/fonts/unispace/unispace bd.ttf'), 16);
		Titlebar.initialize();
		#end

		switch (window.context.type)
		{
			case WEBGL, OPENGL, OPENGLES:
				try {
					startSample(window);
				} catch (_) {
					trace(CallStack.toString(CallStack.exceptionStack()), _);
				}
			default: throw("Sorry, only works with OpenGL.");
		}
	}

	static var songChosen:String = "";

	static public function switchState(newState:StateSelection) {
		var instance = Main.current;

		try {
			switch (instance.currentState) {
				case MAIN_MENU:
					instance.mainMenu.dispose();
					instance.mainMenu = null;
				case GAMEPLAY:
					instance.playField.dispose();
					instance.playField = null;
				case AWARDS:
				case CREDITS:
				case NONE:
			}
		} catch (_) trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()), _);

		instance.currentState = newState;

		try {
			switch (newState) {
				case MAIN_MENU:
					//trace('That\'s it I\'m crashing out');
					instance.mainMenu = new MainMenu();
					instance.mainMenu.init(instance.topDisplay, instance.middleDisplay, instance.bottomDisplay);
				case GAMEPLAY:
					instance.playField = new PlayField(songChosen);
					instance.playField.init(instance.topDisplay, instance.middleDisplay, instance.bottomDisplay);
					instance.playField.downScroll = SaveData.state.preferences.downScroll;
				case AWARDS:
				case CREDITS:
				case NONE:
			}
		} catch (_) trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()), _);

		//GC.run(10);
		GC.enable(false);

		var peoteView = Main.current.peoteView;
	}

	// ------------------------------------------------------------
	// --------------------- GAME STARTS HERE ---------------------
	// ------------------------------------------------------------

	// STARTING POINT
	static var current:Main;
	var peoteView:PeoteView;

	// MUSIC
	static var conductor:Conductor;

	// DISPLAYS
	var bottomDisplay:CustomDisplay;
	var middleDisplay:CustomDisplay;
	var topDisplay:CustomDisplay;
	var optionsScreen:CustomDisplay;
	var freeplayScreen:CustomDisplay;
	var storyScreen:CustomDisplay;

	// STATES
	var currentState:StateSelection;
	var mainMenu:MainMenu;
	var playField:PlayField;

	// MENUS
	var optionsMenu(default, null):OptionsMenu;
	var freeplayMenu(default, null):FreeplayMenu;
	var storyMenu(default, null):StoryMenu;

	// CONTROLS
	var controls(default, null):Controls;
	var gamepad(default, null):Gamepad;

	// This is a replacement for Application.current.window.onMouseDown as it's a rouge piece a shit I've noticed was especially targetable on hashlink where the freeplay mouse click bug arose 
	var mouseDown:(Float, Float, MouseButton)->Void = function(x:Float, y:Float, button:MouseButton) {};

	public function startSample(window:Window)
	{
		current = this;

		SaveData.init();
		Tools.getIconGridMap('assets/ui');

		window.frameRate = SaveData.state.graphics.frameRate;

		prepareGameplayState();

		peoteView = new PeoteView(window);

		haxe.Timer.delay(function() {
			createTextures();
			createDisplays();

			peoteView.start();

			addDisplays();

			conductor = new Conductor();

			OptionsMenu.init(optionsScreen);
			optionsMenu = new OptionsMenu();

			FreeplayMenu.init(freeplayScreen);
			freeplayMenu = new FreeplayMenu();

			StoryMenu.init(storyScreen);
			storyMenu = new StoryMenu();

			resize(peoteView.width, peoteView.height);

			switchState(MAIN_MENU);

			window.onResize.add(resize);
			window.onKeyDown.add(controlVolume);

			#if FV_DEBUG
			DeveloperStuff.init(window, this);
			#end

			window.onMouseDown.add((x, y, button) -> {
				mouseDown(x, y, button);
			});

			_started = true;
		}, 100);
	}

	private function prepareGameplayState() {
		Gamepad.onConnect.add((gamepad:Gamepad) -> {
			trace('Gamepad ${gamepad.name} connected');
		});

		gamepad = new Gamepad(0);
		controls = new Controls();

		HealthBarSprite.healthBarProperties = Tools.parseHealthBarConfig('assets/ui');
		UISprite.timeBarProperties = Tools.parseTimeBarConfig('assets/ui');
		Tools.parseNoteskinData('assets/notes');
	}

	private function createTextures() {
		var stamp = haxe.Timer.stamp();
		trace("Preloading textures...");
		TextureSystem.createTexture("mainMenuBGTex", "assets/mainMenu/menuBG.png");
		TextureSystem.createTexture("mainMenuSheet", "assets/mainMenu/sheet.png");
		TextureSystem.createTexture("noteTex", "assets/notes/noteSheet.png");
		TextureSystem.createTexture("uiTex", "assets/ui/uiSheet.png");
		TextureSystem.createTexture("hbTex", "assets/ui/hbSheet.png");
		TextureSystem.createTexture("storyModeSheet", "assets/ui/storyModeSheet.png");
		TextureSystem.createTexture("optionsMenuSheet", "assets/ui/optionsMenuSheet.png");
		TextureSystem.createTexture("alphabetSheet", "assets/alphabetText/sheet.png");
		trace('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function createDisplays() {
		var stamp = haxe.Timer.stamp();
		trace("Creating displays...");
		bottomDisplay = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF33);
		middleDisplay = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF00);
		topDisplay = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF00);
		optionsScreen = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF00);
		freeplayScreen = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF00);
		storyScreen = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF00);
		trace('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function addDisplays() {
		var stamp = haxe.Timer.stamp();
		trace("Adding displays...");

		peoteView.addDisplay(bottomDisplay);
		peoteView.addDisplay(middleDisplay);
		peoteView.addDisplay(topDisplay);
		peoteView.addDisplay(optionsScreen);
		peoteView.addDisplay(freeplayScreen);
		peoteView.addDisplay(storyScreen);
		trace('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function controlVolume(keyCode:KeyCode, keyModifier:KeyModifier) {
		// Temporarily disabled volume control because its music mixer system is currently wip
		/*switch (keyCode) {
			case KeyCode.EQUALS:
				Sound.globalVolume += 0.1;
				Sys.println('NEW VOLUME: ${Sound.globalVolume}');
			case KeyCode.MINUS:
				Sound.globalVolume -= 0.1;
				Sys.println('NEW VOLUME: ${Sound.globalVolume}');
			default:
		}*/
	}

	var newDeltaTimeSeconds:Int = 0;
	var newDeltaTime:Float = 0;

	override function update(deltaTime:haxe.Int64) {
		Tools.profileFrame();

		if (_started) {
			//if (window.onMouseDown.__listeners[1] != null) trace(window.onMouseDown.__listeners[1]);
			// The if check is to prevent the div operation from running every frame even though `newDeltaTimeSeconds` will be 0 most of the time
			newDeltaTimeSeconds = deltaTime < 1000000000 ? 0 : Int64.div(deltaTime, 1000000000).low;
			newDeltaTime = newDeltaTimeSeconds + (Int64.mod(deltaTime, 1000000000).low * 0.000001);

			try {
				if (mainMenu != null && !mainMenu.disposed) {
					mainMenu.update(newDeltaTime);
				}

				if (playField != null && !playField.disposed) {
					if (!playField.paused) {
						playField.update(newDeltaTime);
					}

					if (PauseScreen.active()) {
						var pauseScreen = playField.pauseScreen;
						pauseScreen.update(newDeltaTime);
					}
				}

				if (optionsMenu.active) {
					optionsMenu.update(newDeltaTime);
				}

				if (freeplayMenu.active) {
					freeplayMenu.update(newDeltaTime);
				}

				if (storyMenu.active) {
					storyMenu.update(newDeltaTime);
				}
			} catch (_) {
				trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			}
		}

		Tools.profileFrame();
	}

	function popupOptionsMenu() {
		if (!optionsScreen.isVisible) optionsScreen.show();
	}

	function removeOptionsMenu() {
		if (optionsScreen.isVisible) optionsScreen.hide();
	}

	function popupFreeplayMenu() {
		if (!freeplayScreen.isVisible) freeplayScreen.show();
	}

	function removeFreeplayMenu() {
		if (freeplayScreen.isVisible) freeplayScreen.hide();
	}

	function popupStoryMenu() {
		if (!storyScreen.isVisible) storyScreen.show();
	}

	function removeStoryMenu() {
		if (storyScreen.isVisible) storyScreen.hide();
	}


	function resize(w:Int, h:Int) {
		peoteView.resize(w, h);

		centerDisplayOnWindow(bottomDisplay, w, h);
		centerDisplayOnWindow(middleDisplay, w, h);
		centerDisplayOnWindow(topDisplay, w, h);
		centerDisplayOnWindow(optionsScreen, w, h);
		centerDisplayOnWindow(freeplayScreen, w, h);
		centerDisplayOnWindow(storyScreen, w, h);
	}

	function centerDisplayOnWindow(display:CustomDisplay, w:Int, h:Int) {
		var scale = h / INITIAL_HEIGHT;

		display.width = w;
		display.height = h;
		display.scale = scale;
	}

	// ------------------------------------------------------------
	// ---------------------- GAME ENDS HERE ----------------------
	// ------------------------------------------------------------
}

private enum abstract StateSelection(Int) {
	var NONE;
	var MAIN_MENU;
	var GAMEPLAY;
	var AWARDS;
	var CREDITS;
}