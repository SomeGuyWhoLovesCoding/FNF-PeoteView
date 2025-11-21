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
import miniaudio.MiniAudio;

private enum abstract StateSelection(Int) {
	var NONE;
	var MAIN_MENU;
	var GAMEPLAY;
	var AWARDS;
	var CREDITS;
}

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
		Titlebar.setTitleFontColor(255, 255, 255);
		Titlebar.setPrimaryButtonImage("assets/system/WM/maximize.png");
		Titlebar.setSecondaryButtonImage("assets/system/WM/maximize.png");
		//Titlebar.setPrimaryButtonImage("assets/system/WM/maximize.png");
		Titlebar.setButtonFontColor(255, 255, 255);
		var path = sys.FileSystem.absolutePath('assets/fonts/inconsolata/inconsolata-semibold.ttf');
		Titlebar.setTitleFont("Inconsolata-SemiBold", 'assets/fonts/inconsolata/inconsolata-semibold.ttf', 16);
		Titlebar.initialize();
		Titlebar.redrawWindow();
		#end

		switch (window.context.type)
		{
			case WEBGL, OPENGL, OPENGLES:
				startSample(window);
			default: throw("Sorry, only works with OpenGL.");
		}

		/*haxe.Timer.delay(function() {
			// START CHART POFILE
			Chart.load("assets/songs/termination");
			var setTime:Float = 0;
			var TIMES = 20000;
			for (i in 0...250) {
				var stamp = haxe.Timer.stamp();
				for (j in 0...TIMES) {
					var n = File.getNote(j);
					File.setNote(j, n);
				}
				setTime += haxe.Timer.stamp() - stamp;
			}
			Sys.println('Total note setting time: ' + ((((setTime * 1000) / 250)) * 1000000) + 'ns');
			Chart.destroy();
		}, 8000);*/

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

	// This is a replacement for Application.current.window.onMouseDown as it's a rogue piece a shit I've noticed was especially targetable on hashlink where the freeplay mouse click bug arose
	var mouseDown:(Float, Float, MouseButton)->Void;

	public function startSample(window:Window)
	{
		current = this;

		SaveData.init(window);
		Tools.getIconGridMap('assets/images/ui');

		window.frameRate = SaveData.state.graphics.frameRate;

		peoteView = new PeoteView(window);

		haxe.Timer.delay(function() {
			createTextures();
			createDisplays();

			prepareGameplayState();

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
				if (mouseDown != null) mouseDown(x, y, button);
			});

			_started = true;
		}, 100);
	}

	private function prepareGameplayState() {
		controls = new Controls();

		HealthBarSprite.healthBarProperties = Tools.parseHealthBarConfig('assets/images/ui');
		UISprite.timeBarProperties = Tools.parseTimeBarConfig('assets/images/ui');
		Tools.parseNoteskinData('assets/images/notes');
	}

	private function createTextures() {
		var stamp = haxe.Timer.stamp();
		Sys.println("Preloading textures...");
		TextureSystem.createTexture("mainMenuBGTex", "assets/images/mainMenu/menuBG.png", false, true);
		TextureSystem.createTexture("mainMenuSheet", "assets/images/mainMenu/sheet.png", false, true);
		TextureSystem.createTexture("noteTex", "assets/images/notes/noteSheet.png", false, true);
		TextureSystem.createTexture("uiTex", "assets/images/ui/uiSheet.png", false, true);
		TextureSystem.createTexture("hbTex", "assets/images/ui/hbSheet.png", false, true);
		TextureSystem.createTexture("storyModeSheet", "assets/images/ui/storyModeSheet.png", false, true);
		TextureSystem.createTexture("optionsMenuSheet", "assets/images/ui/optionsMenuSheet.png", false, true);
		TextureSystem.createTexture("alphabetSheet", "assets/alphabetText/sheet.png", false, true); // Can't be moved to images folder otherwise the game craps itself.
		Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function createDisplays() {
		var stamp = haxe.Timer.stamp();
		Sys.println("Creating displays...");
		bottomDisplay = new CustomDisplay(0, 0, window.width, window.height, 0xFFFFFF33);
		middleDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		topDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		optionsScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		freeplayScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		storyScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function addDisplays() {
		var stamp = haxe.Timer.stamp();
		Sys.println("Adding displays...");

		peoteView.addDisplay(bottomDisplay);
		peoteView.addDisplay(middleDisplay);
		peoteView.addDisplay(topDisplay);
		peoteView.addDisplay(optionsScreen);
		peoteView.addDisplay(freeplayScreen);
		peoteView.addDisplay(storyScreen);
		Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
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

	#if hxcpp
	var newTimestamp:Float = 0;
	#end
	override function update(deltaTime:Int) {
		Tools.profileFrame();

		if (_started) {
			#if FV_LIME_FORK
			newDeltaTime = deltaTime * 0.00001;
			#else
			newDeltaTime = 1000 / Application.current.window.frameRate;
			#end

			if (mainMenu != null && !mainMenu.disposed) {
				mainMenu.update(newDeltaTime);
			}

			if (playField != null && !playField.disposed) {
				if (playField.pauseScreen != null) {
					var pauseScreen = playField.pauseScreen;
					if (!pauseScreen.disposed) pauseScreen.update(newDeltaTime);
				}

				if (!playField.paused && !RenderingMode.enabled) {
					playField.update(newDeltaTime);
				}
			}

			if (optionsMenu.active) {
				optionsMenu.update(newDeltaTime);
			}

			if (storyMenu.active) {
				storyMenu.update(newDeltaTime);
			}
		}

	}

	override function render(context:RenderContext) {
		super.render(context);

		#if FV_LIME_FORK
		var renderFrameRate = Application.current.window.renderFrameRate;
		var refreshRate:Float = Application.current.window.displayMode.refreshRate;
		if (refreshRate == 0) refreshRate = 60;
		if (renderFrameRate == 0) renderFrameRate = Application.current.window.renderFrameRate = refreshRate;
		#else
		var renderFrameRate = Application.current.window.frameRate;
		#end

		if (playField != null) {
			var renderingModeEnabled = RenderingMode.enabled;
			if (!playField.paused) {
				if (renderingModeEnabled) playField.update(1000 / 60);
				var noteSystem = playField?.noteSystem;
				if (noteSystem != null) {
					var pos = MetaNote.floatToMetaNotePosition(playField.songPosition);
					playField.noteSystem.renderNotes(pos);
				}

				var field = playField?.field;
				if (field != null) {
					field.render();
				}

				var hud = playField?.hud;
				if (hud != null) {
					hud.render(1000 / (renderingModeEnabled ? 60 : renderFrameRate));

					var scoreTxt = HUD.scoreTxt;
					var noteSpawner = noteSystem.noteSpawner;
					//if (scoreTxt != null) scoreTxt.text = ((noteSpawner.timeSpentOnIt * 1000000000) / Tools.int64ToFloat(noteSpawner.top - noteSpawner.bottom)) + "ns";
					//if (scoreTxt != null) scoreTxt.text = (noteSpawner.timeSpentOnIt * 1000) + "ms";

					hud.updateBuffers();
				}

				if (renderingModeEnabled) RenderingMode.pipeFrame();
			}
		}
		if (freeplayMenu != null) {
			if (freeplayMenu.active) {
				freeplayMenu.render(1000 / renderFrameRate);
			}
		}
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