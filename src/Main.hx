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

// generated from claude.ai
class FrameLogger {
    static var last:Float = 0;
    static var buf:StringBuf = new StringBuf();
    static var size:Int = 0;
    static var file:sys.io.FileOutput;

    public static function log(deltaTime:Int64/*, deltaTimeINGAME:Float*/) {
		if (file == null) {
			file = sys.io.File.append("frametimes.log", false);
			Application.current.window.onClose.add(flush);
		}
        var line = 'Raw: $deltaTime'/* + ', In-game: $deltaTimeINGAME'*/ + '\n';
		buf.add(line);
		size += line.length;
		if (size >= 16384) flush();
    }

    public static function flush() {
        file.writeString(buf.toString());
        file.flush();
        buf = new StringBuf();
        size = 0;
    }
}

private enum abstract StateSelection(Int) {
	var NONE;
	var MAIN_MENU;
	var GAMEPLAY;
	var AWARDS;
	var CREDITS;
}

/**
	* The entry point for the application
	@since Zero
**/
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

		AsyncInput.main();

		#if (windows && customtitlebar)
		Titlebar.setTitlebarColor(titleBarColor.r, titleBarColor.g, titleBarColor.b);
		Titlebar.setTitleFontColor(255, 255, 255);
		Titlebar.setPrimaryButtonImage("assets/system/WM/maximize.png");
		Titlebar.setSecondaryButtonImage("assets/system/WM/maximize.png");
		Titlebar.setTitleFont("Inconsolata SemiBold", 'assets/fonts/ttfs/inconsolata.ttf', 16);
		Titlebar.setButtonFontColor(255, 255, 255);
		Titlebar.initialize();
		Titlebar.redrawWindow();
		#end

		#if chart_test
		haxe.Timer.delay(function() {
			// START CHART POFILE
			Chart.load("assets/songs/god-eater");
			var len = File.getLength();
			trace('Chart Length ' + len);
			var i:Int64 = 0;
			while (i < len) {
				var note = File.getNote(i);
				var noteTime = MetaNote.metaNotePositionToSongTime(note.position + File.getTimeCorrectionForIndex(i));
				//trace("Processed time: " + noteTime + " | Note time (combined): " + (note.position + File.getTimeCorrectionForIndex(i)) + " | Note time: " + note.position + " | Correction time: " + File.getTimeCorrectionForIndex(i));
				i++;
			}
			// Start initializing total time variables
			var insertTime:Float = 0;
			var removalTime:Float = 0;

			for (i in 0...1) {
				var stamp = haxe.Timer.stamp();
				//trace("Insert 1,000,000 notes (array)");f
				//Sys.println("Insert 1,000,000 notes (function)");
				var stamp2 = haxe.Timer.stamp();
				for (i in 0...20) {
					var pos = Tools.betterInt64FromFloat((0.0 + (200000000.0 * i)));
					var dur = 100 * 2;
					var ind = i % 9;
					var typ = 1;
					//trace('adding note ${i+1} (pos,dur,ind,type)',pos,dur,ind,typ);
					File.insertNote(pos, dur, /* Equal to `note.duration(ms) * 2`. */ ind, typ);
				}
				insertTime += haxe.Timer.stamp() - stamp2;
				//Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp2) * 1000}ms');
				// Remove notes
				var stamp3 = haxe.Timer.stamp();
				//Sys.println("Remove 1,000,000 notes (function)");
				//Sys.println(arr.length);
				for (i in 5...6) {
					trace('removing note (index)',i);
					File.removeNote(i);
				}
				removalTime += haxe.Timer.stamp() - stamp3;
				//Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp3) * 1000}ms');
				//Sys.println('Inserting 1,000,000 notes fully done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
				Sys.println('Iteration $i done');
			}
			// Average it out
			Sys.println('Total insert time: ' + ((insertTime * 1000) / 1) + 'ms');
			Sys.println('Total removal time: ' + ((removalTime * 1000) / 1) + 'ms');
			Chart.destroy();
		}, 8000);
		#end

		switch (window.context.type)
		{
			case WEBGL, OPENGL, OPENGLES:
				startSample(window);
			default: throw("Sorry, only works with OpenGL.");
		}
	}

	static var songChosen:String = "";

	static public dynamic function uponSongExit() {
		switchState(MAIN_MENU);
	}

	static public function switchState(newState:StateSelection, skipTransition:Bool = false) {
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

	// NOW FOR THE SOUND EFFECTS
	var sound_scrollIdx:Int;
	var sound_confIdx:Int;
	var sound_cancelIdx:Int;

	// UPSCALE CONDITION - WHENEVER YOU WANT YOUR GAME TO RUN LIKE COCK OR RUN LIKE WHEELS
	var upscale:Bool = false;

	public function startSample(window:Window)
	{
		current = this;

		SaveData.init(window);
		Tools.getIconGridMap('assets/images/ui');

		peoteView = new PeoteView(window);

		haxe.Timer.delay(function() {
			createSounds();
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

			switchState(MAIN_MENU);

			resize(peoteView.width, peoteView.height);

			window.onResize.add(resize);
			window.onKeyDown.add(controlVolume);
			window.onClose.add(Chart.destroy);

			#if FV_DEBUG
			DeveloperStuff.init(window, this);
			#end

			window.onMouseDown.add((x, y, button) -> {
				if (mouseDown != null) mouseDown(x, y, button);
			});

			//Application.current.window.uncappedFrameRate = true;

			_started = true;
		}, 100);
	}

	private function prepareGameplayState() {
		controls = new Controls();
	}

	private function createSounds() {
		sound_scrollIdx = MiniAudio.loadSoundEffect(Paths.asset("assets/sounds/scrollMenu.ogg"));
		sound_confIdx = MiniAudio.loadSoundEffect(Paths.asset("assets/sounds/confirmMenu.ogg"));
		sound_cancelIdx = MiniAudio.loadSoundEffect(Paths.asset("assets/sounds/cancelMenu.ogg"));
	}

	public function playScrollSound() {
		MiniAudio.playSoundEffect(sound_scrollIdx, 0.7);
	}
	public function playConfirmSound() {
		MiniAudio.playSoundEffect(sound_confIdx, 0.7);
	}
	public function playCancelSound() {
		MiniAudio.playSoundEffect(sound_cancelIdx, 0.7);
	}

	private function createTextures() {
		var stamp = haxe.Timer.stamp();
		Sys.println("Preloading textures...");

		HealthBarSprite.healthBarProperties = Tools.parseHealthBarConfig('assets/images/ui');
		UISprite.timeBarProperties = Tools.parseTimeBarConfig('assets/images/ui');
		Tools.parseNoteskinData('assets/images/notes');

		TextureSystem.createTexture("mainMenuBGTex", "assets/images/mainMenu/menuBG.png", false, true);
		TextureSystem.createTexture("mainMenuSheet", "assets/images/mainMenu/sheet.png", false, true);
		TextureSystem.createTexture("uiTex", "assets/images/ui/uiSheet.png", false, true);
		TextureSystem.createTexture("hbTex", "assets/images/ui/hbSheet.png", false, true);
		TextureSystem.createTexture("storyModeSheet", "assets/images/ui/storyModeSheet.png", false, true);
		TextureSystem.createTexture("optionsMenuSheet", "assets/images/ui/optionsMenuSheet.png", false, true);
		TextureSystem.createTexture("alphabetSheet", "assets/alphabetText/sheet.png", false, true);

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
		//Sys.println('INITIAL VOLUME: ${Mixer.globalVolume}');
		switch (keyCode) {
			case KeyCode.EQUALS:
				Mixer.globalVolume = Math.min(Mixer.globalVolume + 0.1, 1);
				MiniAudio.setMixerMasterVolume(Mixer.globalVolume);
				Sys.println('NEW VOLUME: ${Mixer.globalVolume}');
			case KeyCode.MINUS:
				Mixer.globalVolume = Math.max(Mixer.globalVolume - 0.1, 0);
				Sys.println('NEW VOLUME: ${Mixer.globalVolume}');
				MiniAudio.setMixerMasterVolume(Mixer.globalVolume);
			default:
		}
	}

	var newDeltaTime:Float = 0;

	override function update(deltaTime:Int) {
		Tools.profileFrame();
		//Sys.println(deltaTime);
		//FrameLogger.log(deltaTime);

		/*if (@:privateAccess !Mixer.hasSubLoopTick) {
			AsyncInput.poll();
		}*/

		var lastTitle = Application.current.window.title;

		if (_started) {
			#if FV_LIME_FORK
			newDeltaTime = deltaTime * 0.00001;
			#else
			newDeltaTime = 1000 / Application.current.window.frameRate;
			#end
			//trace(newDeltaTime);

			if (Application.current.window.uncappedFrameRate && !RenderingMode.enabled) {
				var mult = (1000 / Application.current.window.frameRate) / newDeltaTime;
				newDeltaTime *= mult;
			}

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
		var renderRate = newDeltaTime; // Render is set directly after updating so this is the solution
		//trace(renderRate);
		#else
		var renderFrameRate = Application.current.window.frameRate;
		var renderRate = 1000 / renderFrameRate;
		#end

		if (playField != null) {
			if (!playField.paused) {
				playField.render();
			}
		}
		if (freeplayMenu != null) {
			if (freeplayMenu.active) {
				//Sys.println(renderRate);
				freeplayMenu.render(renderRate);
			}
		}

		//Sys.println('Uncapped framerate: ${Application.current.window.uncappedFrameRate}');
		//Sys.println('Delta time: $newDeltaTime');
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
