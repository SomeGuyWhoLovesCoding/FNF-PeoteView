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
import system.MenuInput;

/**
	* The entry point for the application
	@since Zero
**/
@:publicFields
class Main extends Application {
	static inline var BUILD = 1;

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

	static var UP_TO_DATE:Bool = false;

	// Internal variable for checking if the game has booted up
	private var _started(default, null):Bool;

	override function onWindowCreate():Void {
		var titleBarColor:Color = SaveData.state.graphics.customTitleBarColor;

		UP_TO_DATE = Tools.checkForUpdates();

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
			File.setEditorMode(true);
			trace('Chart Length ' + len);
			var i:Int64 = 0;
			while (i < len) {
				var note = File.getNote(i);
				var noteTime = MetaNote.metaNotePositionToSongTime(note.position);
				// trace("Processed time: " + noteTime + " | Note time (combined): " + (note.position) + " | Note time: " + note.position);
				i++;
			}
			// Start initializing total time variables
			var insertTime:Float = 0;
			var removalTime:Float = 0;

			for (i in 0...1000) {
				var stamp = haxe.Timer.stamp();
				// trace("Insert 1,000,000 notes (array)");f
				// Sys.println("Insert 1,000,000 notes (function)");
				var stamp2 = haxe.Timer.stamp();
				for (i in 0...20) {
					var pos = Tools.betterInt64FromFloat((0.0 + (200000000.0 * i)));
					var dur = 100 * 2;
					var ind = i % 9;
					var typ = 1;
					// trace('adding note ${i+1} (pos,dur,ind,type)',pos,dur,ind,typ);
					File.insertNote(pos, dur, /* Equal to `note.duration(ms) * 2`. */ ind, typ);
				}
				insertTime += haxe.Timer.stamp() - stamp2;
				// Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp2) * 1000}ms');
				// Remove notes
				var stamp3 = haxe.Timer.stamp();
				// Sys.println("Remove 1,000,000 notes (function)");
				// Sys.println(arr.length);
				/*for (i in 5...6) {
							trace('removing note (index)',i);
							File.removeNote(i);
					}
					removalTime += haxe.Timer.stamp() - stamp3; */
				// Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp3) * 1000}ms');
				// Sys.println('Inserting 1,000,000 notes fully done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
				// Sys.println('Iteration $i done');
			}
			// Average it out
			Sys.println('Total insert time: ' + ((insertTime * 1000) / 1) + 'ms');
			Sys.println('Total removal time: ' + ((removalTime * 1000) / 1) + 'ms');
			File.setEditorMode(false);
			Chart.destroy();
		}, 8000);
		#end

		switch (window.context.type) {
			case WEBGL, OPENGL, OPENGLES:
				try
					startSample(window)
				catch (_)
					trace(CallStack.toString(CallStack.exceptionStack()), _);
			default:
				throw("Sorry, only works with OpenGL.");
		}
	}

	static var songChosen:String = "";

	static public dynamic function uponSongExit() {
		switchState(MAIN_MENU);
	}

	static public function switchState(newState:StateSelection, skipTransition:Bool = false) {
		// Queued and applied at the start of the next application frame so it
		// never happens in the middle of input event dispatch.
		current.stateMachine.switchState(newState);
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
	var editorScreen:CustomDisplay;

	// STATES
	var currentState(get, never):StateSelection;

	inline function get_currentState() {
		return stateMachine != null ? stateMachine.current : NONE;
	}

	var stateMachine:StateMachine;
	var mainMenu:MainMenu;
	var playField:PlayField;
	var noteskinEditor:NoteskinEditor;
	var editorMenu:EditorMenu;

	// MENUS
	var optionsMenu(default, null):OptionsMenu;
	var freeplayMenu(default, null):FreeplayMenu;
	var storyMenu(default, null):StoryMenu;

	// CONTROLS
	var controls(default, null):Controls;

	// This is a replacement for Application.current.window.onMouseDown because holy shit does it prevent any invisible crashes whatsoever
	var mouseDown:(Float, Float, MouseButton) -> Void;

	// ------------------------------------------------------------------
	// Crash visibility: release builds are GUI-subsystem apps, so stdout
	// (trace) is invisible and a Haxe exception looks like a silent crash.
	// Log the first occurrence of each exception to crashlog.txt next to
	// the executable so failures can actually be diagnosed.
	static var _lastCrashKey:String = "";

	static function logCrash(where:String, e:Dynamic) {
		var key = '$where|' + Std.string(e);
		if (key == _lastCrashKey)
			return; // already logging this recurring failure
		_lastCrashKey = key;
		var msg = '[$where] ' + Std.string(e) + '\n' + CallStack.toString(CallStack.exceptionStack());
		try {
			var out = sys.io.File.append('crashlog.txt');
			out.writeString(Date.now().toString() + ' ' + msg + '\n');
			out.close();
		} catch (_) {
			// best effort only
		}
	}

	// NOW FOR THE SOUND EFFECTS
	var sound_scrollIdx:Int;
	var sound_confIdx:Int;
	var sound_cancelIdx:Int;

	// UPSCALE CONDITION - WHENEVER YOU WANT YOUR GAME TO RUN LIKE COCK OR RUN LIKE WHEELS
	var upscale:Bool = false;

	public function startSample(window:Window) {
		current = this;

		SaveData.init(window);

		/*window.onKeyDown.add((code, modifier) -> trace('onKeyDown $code $modifier ' + Date.now()));

		window.onKeyUp.add((code, modifier) -> trace('onKeyUp $code $modifier ' + Date.now()));

		window.onMouseDown.add((x, y, button) -> trace('onMouseDown $x $y $button ' + Date.now()));*/

		brilliantInit(window);
	}

	function brilliantInit(window:Window) {
		var frameRate = SaveData.state.graphics.frameRate;
		var vsync = SaveData.state.graphics.vsync;
		FunkinMainLoop.run(frameRate, false, vsync);

		//trace('');

		peoteView = new PeoteView(window);
		TextureSystem.processQueue();

		controls = new Controls();

		// The state machine is created after the input2action control binding
		// so its window listeners fire after the controls (actions dispatch
		// before routed extras), matching the original ordering.
		stateMachine = new StateMachine(window, controls);
		stateMachine.createState = stateCreate;
		stateMachine.destroyState = stateDestroy;

		#if (!html5)
		trace("Is es3? " + PeoteGL.Version.isES3);
		if (PeoteGL.Version.isES3)
			window.context.gl.disable(0x8DB9); // GL_FRAMEBUFFER_SRGB_EXT
		#end

		peoteView.start();

		trace("createSounds");
		createSounds();
		trace("createTextures");
		createTextures();
		trace("createDisplays");
		createDisplays(); // found that it doesn't consum its own RAM. Now that's amazing

		addDisplays();

		trace("1");
		conductor = new Conductor();

		trace("2");
		OptionsMenu.init(optionsScreen);
		optionsMenu = new OptionsMenu();

		trace("3");
		FreeplayMenu.init(freeplayScreen);
		freeplayMenu = new FreeplayMenu();

		trace("4");
		StoryMenu.init(storyScreen);
		storyMenu = new StoryMenu();

		trace("4.a");
		EditorMenu.preInit(middleDisplay);

		trace("4.b");
		NoteskinEditor.preInit(middleDisplay, bottomDisplay);

		trace("5");
		switchState(MAIN_MENU);

		trace("6");
		resize(peoteView.width, peoteView.height);

		window.onResize.add(resize);
		window.onKeyDown.add(controlVolume);
		window.onClose.add(Chart.destroy);

		#if FV_DEBUG
		DeveloperStuff.init(window, this);
		#end

		window.onMouseDown.add((x, y, button) -> {
			try {
				if (mouseDown != null)
					mouseDown(x, y, button);
			} catch (e:Dynamic) {
				logCrash('onMouseDown', e);
			}
		});

		var title = Application.current.window.title;
		var titleLen = title.length;
		Application.current.window.title = title.substring(0, titleLen - 13);
		// Application.current.window.hidden = false;

		// Only start the frame update loop once every menu/display object this
		// update() branch dereferences actually exists. update() runs before the
		// first onRender dispatch that calls this function, so setting _started
		// here (instead of in startSample) guarantees optionsMenu/storyMenu etc.
		// are non-null on the very first frame.
		_started = true;
	}

	/** Build the state object for `newState`. Returns the menu to route input to (null = no routed menu). */
	function stateCreate(newState:StateSelection):MenuInput {
		switch (newState) {
			case MAIN_MENU:
				Sys.println('create the main menu');
				mainMenu = new MainMenu();
				mainMenu.init(topDisplay, middleDisplay, bottomDisplay);
				return mainMenu;
			case GAMEPLAY:
				Sys.println('create the gameplay menu');
				playField = new PlayField(songChosen);
				playField.init(topDisplay, middleDisplay, bottomDisplay);
				playField.downScroll = SaveData.state.preferences.downScroll;
				return null;
			case AWARDS:
				return null;
			case NOTE_VIEW:
				Sys.println('create the noteskin editor menu');
				noteskinEditor = new NoteskinEditor();
				noteskinEditor.init(topDisplay, middleDisplay, bottomDisplay);
				return null;
			case EDITOR_MENU:
				Sys.println('create the editor menu');
				editorMenu = new EditorMenu();
				editorMenu.init(topDisplay, middleDisplay, bottomDisplay);
				return editorMenu;
			case NONE:
				return null;
		}
		return null;
	}

	/** Tear down the current state object. */
	function stateDestroy(oldState:StateSelection) {
		switch (oldState) {
			case MAIN_MENU:
				Sys.println('dispose the main menu');
				mainMenu.dispose();
				mainMenu = null;
			case GAMEPLAY:
				Sys.println('dispose the gameplay menu');
				playField.dispose();
				playField = null;
			case AWARDS:
			case NOTE_VIEW:
				Sys.println('dispose the noteskin editor menu');
				noteskinEditor.dispose();
				noteskinEditor = null;
			case EDITOR_MENU:
				Sys.println('dispose the editor menu');
				editorMenu.dispose();
				editorMenu = null;
			case NONE:
		}
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

		Tools.getIconGridMap('assets/images/ui');

		HealthBarSprite.healthBarProperties = Tools.parseHealthBarConfig('assets/images/ui');
		UISprite.timeBarProperties = Tools.parseTimeBarConfig('assets/images/ui');
		NoteskinManager.init(); // prepare

		TextureSystem.createTexture("mainMenuBGTex", "assets/images/mainMenu/menuBG.png", false, true, true);
		TextureSystem.createTexture("mainMenuSheet", "assets/images/mainMenu/sheet.png", false, true, true);
		TextureSystem.createTexture("uiTex", "assets/images/ui/uiSheet.png", false, true, true);
		TextureSystem.createTexture("hbTex", "assets/images/ui/hbSheet.png", false, true, true);
		TextureSystem.createTexture("storyModeSheet", "assets/images/ui/storyModeSheet.png", false, true, true);
		TextureSystem.createTexture("alphabetSheet", "assets/alphabetText/sheet.png", false, true, true);

		Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function createDisplays() {
		var stamp = haxe.Timer.stamp();
		Sys.println("Creating displays...");
		bottomDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x11111100);
		middleDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		topDisplay = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		optionsScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		freeplayScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		storyScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
		editorScreen = new CustomDisplay(0, 0, window.width, window.height, 0x00000000);
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
		peoteView.addDisplay(editorScreen);
		Sys.println('Done! Took ${(haxe.Timer.stamp() - stamp) * 1000}ms');
	}

	private function controlVolume(keyCode:KeyCode, keyModifier:KeyModifier) {
		// Sys.println('INITIAL VOLUME: ${Mixer.globalVolume}');
		switch (keyCode) {
			case KeyCode.EQUALS:
				Mixer.globalVolume = Math.min(Mixer.globalVolume + 0.1, 1);
				Sys.println('NEW VOLUME: ${Mixer.globalVolume}');
			case KeyCode.MINUS:
				Mixer.globalVolume = Math.max(Mixer.globalVolume - 0.1, 0);
				Sys.println('NEW VOLUME: ${Mixer.globalVolume}');
			default:
		}
	}

	var newDeltaTime:Float = 0;
	var simulatedDeltaTime:Float = Math.POSITIVE_INFINITY;
	var startSimulatedDeltaTime:Float = 0;
	var averageFrames:Float = 0;

	override function update(deltaTime:Float) {
		Tools.profileFrame();

		averageFrames++;

		if (startSimulatedDeltaTime == Math.POSITIVE_INFINITY) {
			startSimulatedDeltaTime = haxe.Timer.stamp();
		}

		simulatedDeltaTime = haxe.Timer.stamp();

		var lastTitle = Application.current.window.title;

		// Safe point: apply queued state transitions and input-focus changes
		// before anything else runs this frame. Textures created during a state
		// change are uploaded right away (this runs a GC sweep, so only on
		// actual transitions).
		if (stateMachine != null && stateMachine.beginFrame()) {
			TextureSystem.processQueue();
		}

		if (_started) {
			try {
				// Use the live window frame rate so changing the framerate option at
				// runtime keeps the simulated delta in sync (otherwise lerp speeds up).
				newDeltaTime = 1000.0 / Application.current.window.frameRate;
				// if (deltaTime > 50) newDeltaTime = deltaTime;

				if (mainMenu != null && !mainMenu.disposed) {
					mainMenu.update(newDeltaTime);
				}

				if (playField != null && !playField.disposed) {
					if (playField.pauseScreen != null) {
						var pauseScreen = playField.pauseScreen;
						if (!pauseScreen.disposed)
							pauseScreen.update(newDeltaTime);
					}

					if (!playField.paused && !RenderingMode.enabled) {
						playField.update(newDeltaTime);
					}
				}

				if (noteskinEditor != null && !noteskinEditor.disposed) {
					noteskinEditor.update(newDeltaTime);
				}

				if (editorMenu != null && !editorMenu.disposed) {
					editorMenu.update(newDeltaTime);
				}

				if (optionsMenu != null && optionsMenu.active) {
					optionsMenu.update(newDeltaTime);
				}

				if (storyMenu != null && storyMenu.active) {
					storyMenu.update(newDeltaTime);
				}
			} catch (e:Dynamic) {
				logCrash('update', e);
			}
		}

		var delta = simulatedDeltaTime - startSimulatedDeltaTime;
		if (delta >= 1) {
			// Sys.println('FPS $averageFrames\nVRAM ${TextureSystem.VRAMCounter()}\n');
			startSimulatedDeltaTime = haxe.Timer.stamp();
			averageFrames = 0;
		}
	}

	override function render(context:RenderContext) {
		super.render(context);

		var renderFrameRate = Application.current.window.frameRate;
		var renderRate = 1000 / renderFrameRate;

		try {
			if (playField != null && !playField.disposed) {
				if (!playField.paused) {
					playField.render();
				}
			}
			if (freeplayMenu != null) {
				if (freeplayMenu.active && currentState != GAMEPLAY) {
					freeplayMenu.render(renderRate);
				}
			}
		} catch (e:Dynamic) {
			logCrash('render', e);
		}

		simulatedDeltaTime = haxe.Timer.stamp() - simulatedDeltaTime;
	}

	function popupOptionsMenu() {
		if (!optionsScreen.isVisible)
			optionsScreen.show();
	}

	function removeOptionsMenu() {
		if (optionsScreen.isVisible)
			optionsScreen.hide();
	}

	function popupFreeplayMenu() {
		if (!freeplayScreen.isVisible)
			freeplayScreen.show();
	}

	function removeFreeplayMenu() {
		if (freeplayScreen.isVisible)
			freeplayScreen.hide();
	}

	function popupStoryMenu() {
		if (!storyScreen.isVisible)
			storyScreen.show();
	}

	function removeStoryMenu() {
		if (storyScreen.isVisible)
			storyScreen.hide();
	}

	function resize(w:Int, h:Int) {
		peoteView.resize(w, h);

		centerDisplayOnWindow(bottomDisplay, w, h);
		centerDisplayOnWindow(middleDisplay, w, h);
		centerDisplayOnWindow(topDisplay, w, h);
		centerDisplayOnWindow(optionsScreen, w, h);
		centerDisplayOnWindow(freeplayScreen, w, h);
		centerDisplayOnWindow(storyScreen, w, h);
		centerDisplayOnWindow(editorScreen, w, h);
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