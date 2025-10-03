package;

import lime.graphics.RenderContext;
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

		#if (windows && customtitlebar)
		Titlebar.setTitlebarColor(titleBarColor.r, titleBarColor.g, titleBarColor.b);
		Titlebar.setTitleFontColor(0, 0, 0);
		Titlebar.setButtonFontColor(20, 10, 30);
		var path = sys.FileSystem.absolutePath('assets/fonts/unispace/unispace bd.ttf');
		trace(path);
		Titlebar.setTitleFont("Unispace-Bold", path, 16);
		Titlebar.initialize();
		#end

		switch (window.context.type)
		{
			case WEBGL, OPENGL, OPENGLES:
				startSample(window);
			default: throw("Sorry, only works with OpenGL.");
		}

		/*#if (chart_test || hl)
		haxe.Timer.delay(function() {
			// START CHART POFILE
			Chart.load("assets/songs/termination");
			// Start initializing total time variables
			var insertTime:Float = 0;
			var removalTime:Float = 0;

			var arr = new Array<MetaNote>();
			for (i in 0...1000000) {
				arr.push(new MetaNote(Tools.betterInt64FromFloat((50.0 + (50.0 * i)) * 100),
					Math.floor(//100
						0 * 0.2), // Equal to `note.duration / 5`.
					i % 4,
					0,
				1));
				//Sys.println(i);
			}

			for (i in 0...250) {
				var stamp = haxe.Timer.stamp();
				//trace("Insert 1,000,000 notes (array)");
				//Sys.println("Insert 1,000,000 notes (function)");
				var stamp2 = haxe.Timer.stamp();
				File.insertNotes(arr);
				insertTime += haxe.Timer.stamp() - stamp2;
				//Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp2) * 1000}ms');
				// Remove notes
				var stamp3 = haxe.Timer.stamp();
				//Sys.println("Remove 1,000,000 notes (function)");
				//Sys.println(arr.length);
				File.removeNotes(arr);
				removalTime += haxe.Timer.stamp() - stamp3;
				//Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp3) * 1000}ms');
				//Sys.println('Inserting 1,000,000 notes fully done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
				Sys.println('Iteration $i done');
			}
			// Average it out
			Sys.println('Total insert time: ' + ((insertTime * 1000) / 250) + 'ms');
			Sys.println('Total removal time: ' + ((removalTime * 1000) / 250) + 'ms');
			Chart.destroy();
		}, 8000);
		#end*/
	}

	static var songChosen:String = "";

	static public function switchState(newState:StateSelection) {
		var instance = Main.current;

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

		instance.currentState = newState;

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

	// This is a replacement for Application.current.window.onMouseDown as it's a rogue piece a shit I've noticed was especially targetable on hashlink where the freeplay mouse click bug arose
	var mouseDown:(Float, Float, MouseButton)->Void;

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
			window.onClose.add(Chart.destroy);

			#if FV_DEBUG
			DeveloperStuff.init(window, this);
			#end

			window.onMouseDown.add((x, y, button) -> {
				//trace('$mouseDown $currentState');
				if (mouseDown != null) mouseDown(x, y, button);
			});

			GC.run(10);
			GC.enable(false);

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
		TextureSystem.createTexture("mainMenuBGTex", "assets/mainMenu/menuBG.png", false, true);
		TextureSystem.createTexture("mainMenuSheet", "assets/mainMenu/sheet.png", false, true);
		TextureSystem.createTexture("noteTex", "assets/notes/noteSheet.png", false, true);
		TextureSystem.createTexture("uiTex", "assets/ui/uiSheet.png", false, true);
		TextureSystem.createTexture("hbTex", "assets/ui/hbSheet.png", false, true);
		TextureSystem.createTexture("storyModeSheet", "assets/ui/storyModeSheet.png", false, true);
		TextureSystem.createTexture("optionsMenuSheet", "assets/ui/optionsMenuSheet.png", false, true);
		TextureSystem.createTexture("alphabetSheet", "assets/alphabetText/sheet.png", false, true);
		trace('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function createDisplays() {
		var stamp = haxe.Timer.stamp();
		trace("Creating displays...");
		bottomDisplay = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF33);
		middleDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		topDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		optionsScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		freeplayScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		storyScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
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

	var newDeltaTime:Float = 0;

	override function update(deltaTime:Int) {
		Tools.profileFrame();
		//Sys.println(1000000 / deltaTime);

		if (_started) {
			newDeltaTime = deltaTime * 0.001;

			//try {
				if (mainMenu != null && !mainMenu.disposed) {
					mainMenu.update(newDeltaTime);
				}

				if (playField != null && !playField.disposed) {
					if (playField.pauseScreen != null) {
						var pauseScreen = playField.pauseScreen;
						if (!pauseScreen.disposed) pauseScreen.update(newDeltaTime);
					}

					if (!playField.paused) {
						playField.update(newDeltaTime);
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
			//} catch (_) {
			//	trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			//}
		}

		Tools.profileFrame();
	}

	override function render(context:RenderContext) {
		super.render(context);

		if (RenderingMode.enabled && (playField != null && !playField.songEnded)) {
			RenderingMode.pipeFrame();
		}
		//Sys.println("render is decoupled?");
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
