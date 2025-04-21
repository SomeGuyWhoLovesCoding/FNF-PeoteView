package;

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
		return current.peoteView.width - 2;
	}

	inline static function get_VARIABLE_HEIGHT() {
		return current.peoteView.height - 32;
	}

	// Internal variable for checking if the game has booted up
	private var _started(default, null):Bool;

	override function onWindowCreate()
	{
		switch (window.context.type)
		{
			case WEBGL, OPENGL, OPENGLES:
				try {
					songChosen = Sys.args()[0];
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
				case FREEPLAY:
				case GAMEPLAY:
					instance.playField.dispose();
					instance.playField = null;
				case AWARDS:
				case CREDITS:
				case NONE:
			}
		} catch (_) trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()), _);

		instance.currentState = newState;

		switch (newState) {
			case MAIN_MENU:
				instance.mainMenu = new MainMenu();
				instance.mainMenu.init(instance.topDisplay, instance.middleDisplay, instance.bottomDisplay);
			case FREEPLAY:
			case GAMEPLAY:
				instance.playField = new PlayField(songChosen);
				instance.playField.init(instance.topDisplay, instance.middleDisplay, instance.bottomDisplay);
				instance.playField.downScroll = SaveData.state.preferences.downScroll;
			case AWARDS:
			case CREDITS:
			case NONE:
		}

		GC.run(10);
		GC.enable(false);

		var peoteView = Main.current.peoteView;

		Main.current.fakeWindow.reload(peoteView.width, peoteView.height);
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
	var fakeWindow:FakeWindow;

	// STATES
	var currentState:StateSelection;
	var mainMenu:MainMenu;
	var playField:PlayField;

	// MENUS
	var optionsMenu(default, null):OptionsMenu;
	var freeplayMenu(default, null):FreeplayMenu;

	// CONTROLS
	var controls(default, null):Controls;
	var gamepad(default, null):Gamepad;

	public function startSample(window:Window)
	{
		window.opacity = 0;

		current = this;

		SaveData.init();
		Sound.init();
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

			fakeWindow = new FakeWindow(peoteView);

			resize(peoteView.width, peoteView.height);

			switchState(MAIN_MENU);

			window.onResize.add(resize);
			window.onKeyDown.add(controlVolume);

			#if FV_DEBUG
			DeveloperStuff.init(window, this);
			#end

			_started = true;

			window.opacity = 1;
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
		TextureSystem.createTexture("pauseScreenSheet", "assets/ui/pauseScreenSheet.png");
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
		trace('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function addDisplays() {
		var stamp = haxe.Timer.stamp();
		trace("Adding displays...");

		peoteView.addDisplay(bottomDisplay);
		peoteView.addDisplay(middleDisplay);
		peoteView.addDisplay(topDisplay);
		trace('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function controlVolume(keyCode:KeyCode, keyModifier:KeyModifier) {
		switch (keyCode) {
			case KeyCode.EQUALS:
				Sound.globalVolume += 0.1;
				Sys.println('NEW VOLUME: ${Sound.globalVolume}');
			case KeyCode.MINUS:
				Sound.globalVolume -= 0.1;
				Sys.println('NEW VOLUME: ${Sound.globalVolume}');
			default:
		}
	}

	var newDeltaTime:Float = 0;
	var timeStamp:Float = 0;

	override function update(deltaTime:Int) {
		Tools.profileFrame();

		if (_started) {
			fakeWindow.updateCloseButton(deltaTime);

			var ts:Float = stamp();

			newDeltaTime = (ts - timeStamp) * 1000;

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
					freeplayMenu.update(deltaTime);
				}
			} catch (_) trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()), _);

			timeStamp = stamp();
		}

		Tools.profileFrame();
	}

	function popupOptionsMenu() {
		if (!optionsScreen.isIn(peoteView)) {
			peoteView.addDisplay(optionsScreen);
		}
		fakeWindow.reload(peoteView.width, peoteView.height);
	}

	function removeOptionsMenu() {
		if (optionsScreen.isIn(peoteView)) {
			peoteView.removeDisplay(optionsScreen);
		}
		fakeWindow.reload(peoteView.width, peoteView.height);
	}

	function popupFreeplayMenu() {
		if (!freeplayScreen.isIn(peoteView)) {
			peoteView.addDisplay(freeplayScreen);
		}
		fakeWindow.reload(peoteView.width, peoteView.height);
	}

	function removeFreeplayMenu() {
		if (freeplayScreen.isIn(peoteView)) {
			peoteView.removeDisplay(freeplayScreen);
		}
		fakeWindow.reload(peoteView.width, peoteView.height);
	}

	function resize(w:Int, h:Int) {
		peoteView.resize(w, h);
		fakeWindow.reload(w, h);

		centerDisplayOnWindow(bottomDisplay, w, h);
		centerDisplayOnWindow(middleDisplay, w, h);
		centerDisplayOnWindow(topDisplay, w, h);
		centerDisplayOnWindow(optionsScreen, w, h);
		centerDisplayOnWindow(freeplayScreen, w, h);
	}

	function centerDisplayOnWindow(display:CustomDisplay, w:Int, h:Int) {
		var scale = (fakeWindow.visible ? (h - 32) : h) / INITIAL_HEIGHT;

		if (fakeWindow.visible) {
			display.x = 1;
			display.width = w - 2;
			display.y = 31;
			display.height = h - 32;
		} else {
			display.x = 0;
			display.width = w;
			display.y = 0;
			display.height = h;
		}
		display.scale = scale;
	}

	inline function stamp() {
		return Timestamp.get();
	}

	// ------------------------------------------------------------
	// ---------------------- GAME ENDS HERE ----------------------
	// ------------------------------------------------------------
}

private enum abstract StateSelection(Int) {
	var NONE;
	var MAIN_MENU;
	var FREEPLAY;
	var GAMEPLAY;
	var AWARDS;
	var CREDITS;
}