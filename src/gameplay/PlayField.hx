package gameplay;

import lime.ui.KeyCode;
import lime.app.Event;

/**
	The home of the gameplay state.
	This is the main class that handles the playfield and all of its components.
	It is responsible for initializing the playfield, updating it, and disposing of it when the game is over.
	This class is used in the Main class to handle the gameplay state.
	@since Development
**/
@:publicFields
class PlayField {
	/**
	 * Set by the debug key (DeveloperStuff) before the state switch; consumed
	 * by create() to build the playfield in playfieldEditorMode. Toggling
	 * routes through Main.switchState(GAMEPLAY), whose dispose + recreate IS
	 * the song restart.
	 */
	static var editorModeNext:Bool = false;

	/**
	 * True when this playfield is the playfield editor: only the note system,
	 * HUD, song system (Mixer/conductor) and pause menu are created and
	 * updated. The Field, lua (FunkinViewLua), EventSystem, InputSystem and
	 * CountdownDisplay never exist here — no note hit registration, no
	 * keybind input, no events, no stage.
	 *
	 * All editor logic lives in PlayFieldEditorMode (field `editorMode`);
	 * the branches in this class only delegate to it. Audio there is
	 * silent by default: the song runs on Mixer.update's fake clock and
	 * the mixer transport is never started at entry — the pause keybind
	 * starts playback through the same onStartSong event the countdown
	 * path uses.
	 */
	var playfieldEditorMode(default, null):Bool = false;

	/** The editor-mode subsystem; non-null only in playfieldEditorMode. */
	var editorMode(default, null):PlayFieldEditorMode;

	var roof(default, null):CustomDisplay;
	var display(default, null):CustomDisplay;
	var view(default, null):CustomDisplay;

	// lua
	// (This was previously `if (!playfieldEditorMode) { var funkinviewlua... }`
	// at class level — a syntax error whenever the lua lib is compiled in,
	// i.e. in every non-FV_NO_LUA build. The mode check lives at runtime now:
	// every access goes through the #if blocks' !playfieldEditorMode guards.)
	#if linc_luajit_funkinview
	var funkinviewlua(default, null):FunkinViewLua;
	#end

	private var chartPath(default, null):String;

	function new(path:String) {
		chartPath = Paths.asset(path);

		Chart.load(chartPath);
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.roof = roof;
		this.display = display;
		this.view = view;

		playfieldEditorMode = editorModeNext;

		#if linc_luajit_funkinview
		// In playfieldEditorMode lua never runs (as intended).
		if (!playfieldEditorMode)
			funkinviewlua = new FunkinViewLua(this, chartPath, Chart.header);
		#end

		create(roof, display, Chart.header.mania);
	}

	function changeBpmAt(time:Float, value:Float, timeNum:Float, timeDen:Float) {
		if (Main.conductor != null)
			Main.conductor.changeBpmAt(time, value, timeNum, timeDen);
	}

	static var onRestartingForBackwardTimeSetting(default, null):Bool = false;
	static var timeForRestartingBackwardTime(default, null):Float = 0;

	// https://github.com/ShadowMario/FNF-PsychEngine/blob/main/source/backend/Rating.hx#L29
	var ratingJudgementList:Array<Judgement> = [
		[
			1.0 - 0.67, // target
			0, // id
			1, // accuracy
			400 // score
		],
		[1.0 - 0.34, 1, 0.8, 200],
		[1.0, 2, 0.675, 100],
		[Math.POSITIVE_INFINITY, 3, 0.5, 50]
	]; // how this new modifiable system works: you simply just set this array to a new selection of ratings, however you want.

	var score:Int64 = 0;
	var misses:Int64 = 0;
	var combo:Int64 = 0;
	var accuracy(default, null):Accuracy = new Accuracy();
	var health:Float = 0.5;
	var healthGain:Array<Float>;
	var healthLoss:Array<Float>;
	var deathCounter:Int;
	var startedCountdown:Bool = false;

	var latencyCompensation:Int;

	// songPosition is ALWAYS raw audio time — never mutated for latency.
	// noteTime = songPosition - noteLatency is the latency-corrected time
	// used for all note processing, conductor, and receptor timing.
	var noteTime:Float = 0;
	var noteLatency(default, null):Float = 0;

	function updateNoteLatency() {
		noteLatency = latencyCompensation + Mixer.latency();
	}

	var dispShake:Vec2 = {x: 0, y: 0};
	var viewShake:Vec2 = {x: 0, y: 0};

	// For Screen Shake event
	var additiveDispShake:Point = {x: 0, y: 0, isSmooth: true};
	var additiveViewShake:Point = {x: 0, y: 0, isSmooth: true};

	var scrollSpeed(default, set):Float = 1.0;

	function set_scrollSpeed(value:Float) {
		if (noteSystem != null)
			noteSystem.setScrollSpeed(scrollSpeed = value);
		return value;
	}

	var downScroll(default, set):Bool;

	function set_downScroll(value:Bool) {
		downScroll = value;
		if (noteSystem != null) {
			var t = startedCountdown ? noteTime : songPosition;
			var pos = MetaNote.floatToMetaNotePosition(t);
			noteSystem.resetStrumlines(false);
			noteSystem.update(pos);
			noteSystem.renderNotes(pos);
		}
		if (hud != null) {
			hud.render();
			hud.update(Math.POSITIVE_INFINITY);
			hud.updateBuffers();
		}
		return value;
	}

	var practiceMode:Bool;
	var songStarted(default, set):Bool;
	var songEnded(default, null):Bool;
	var disposed(default, null):Bool;
	var paused(default, null):Bool;
	var died(default, null):Bool;
	var botplay(default, set):Bool;

	/** Editor-only write access: PlayFieldEditorMode.togglePlayback stops
	 *  playback by dropping songStarted (switches Mixer.update to the
	 *  fake clock). startSong's own writes go through the class itself. */
	@:allow(gameplay.PlayFieldEditorMode)
	function set_songStarted(value:Bool):Bool {
		return songStarted = value;
	}

	function set_botplay(value:Bool) {
		if (noteSystem != null) {
			var t = startedCountdown ? noteTime : songPosition;
			var pos = MetaNote.floatToMetaNotePosition(t);
			noteSystem.resetPlayerStrumlines();
			noteSystem.update(pos);
		}
		return botplay = value;
	}

	/**
		Does not start at zero.
	**/
	@:isVar var mania(get, set):Int = 0;

	inline function get_mania() {
		return mania;
	}

	inline function set_mania(value:Int) {
		if (mania > 256)
			mania = 256;
		if (mania < 1)
			mania = 1;

		return mania = value;
	}

	var field(default, null):Field;
	/** Editor-only write access (PlayFieldEditorMode builds the editor subset). */
	@:allow(gameplay.PlayFieldEditorMode)
	var hud(default, null):HUD;

	var inputSystem(default, null):InputSystem;
	/** Editor-only write access (PlayFieldEditorMode builds the editor subset). */
	@:allow(gameplay.PlayFieldEditorMode)
	var noteSystem(default, null):NoteSystem;
	var eventSystem(default, null):EventSystem;

	var countdownDisp(default, null):CountdownDisplay;
	/** Editor-only write access (PlayFieldEditorMode builds the editor subset). */
	@:allow(gameplay.PlayFieldEditorMode)
	var pauseScreen(default, null):PauseScreen;

	var onStartSong:Event<Header->Void>;
	var onPauseSong:Event<Header->Void>;
	var onResumeSong:Event<Header->Void>;
	var onStopSong:Event<Header->Void>;
	var onDeath:Event<Header->Int->Void>;
	var onNoteHit:Event<MetaNote->Float->Int64->Void>;
	var onNoteMiss:Event<MetaNote->Int64->Void>;
	var onSustainComplete:Event<MetaNote->Void>;
	var onSustainRelease:Event<MetaNote->Void>;
	var onKeyPress:Event<KeyCode->Void>;
	var onKeyRelease:Event<KeyCode->Void>;

	var flipHealthBar:Bool;
	var hitbox:Float = 220;
	var ready:Bool = false;

	function setTime(value:Float, pushToOffset:Float = 0) {
		if (disposed || !songStarted || songEnded || paused || died)
			return;
		if (value > Mixer.length - 1000)
			value = Mixer.length - 1000;

		var isBackwards = value < songPosition;

		if (isBackwards) {
			onRestartingForBackwardTimeSetting = true;
			timeForRestartingBackwardTime = value;

			if (eventSystem != null)
				eventSystem.clearEventTimers(); // immediately clear out any event timers to prevent them flooding the rest of the song through

			#if linc_luajit_funkinview
			if (!playfieldEditorMode) {
				funkinviewlua.callFunction('preTimeChange', timeForRestartingBackwardTime, Chart.header);
			}
			#end

			pause(false);
			Tools.forSync(() -> {
				Main.switchState(GAMEPLAY, true);
			});
		}

		Mixer.setTime(Math.max(value, 0.0), this);

		if (isBackwards)
			return;

		if (hud != null && SaveData.state.preferences.ratingPopup)
			hud.hideRatingPopup();

		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(value);
			noteSystem.onSongPositionJump(pos, pushToOffset);
		}

		if (field != null)
			field.resetCharacters();
	}

	var songPosition:Float;

	/**
	 * Creates the playfield.
	 * @param roof The top display you want the playfield's pause screen to go to.
	 * @param display The ui display you want the playfield's countdown display and hud to go to.
	 * @param initialMania The amount of keys you want for your fnf song. (up to 256 supported) (This is configured by the song's header)
	 */
	function create(roof:CustomDisplay, display:CustomDisplay, initialMania:Int = 4) {
		mania = initialMania;

		// The debug key (controls.game.debug, same bind the Main Menu
		// uses for GAME_DEBUG) is attached at the WINDOW level and for
		// the playfield's whole lifetime — gameplay AND editor mode,
		// running AND paused. A window listener is the only single place
		// that covers all of those: InputSystem is gameplay-only and is
		// detached while paused, and the editor's keyDown bails on
		// paused. DeveloperStuff has its own window listener for the
		// same key; debugKeyDown re-dispatches into its shared action
		// only when DeveloperStuff has NOT already consumed the press.
		attachDebugKey();

		healthLoss = [for (i in 0...128) 0.02];
		healthGain = [for (i in 0...128) 0.025];

		onStartSong = new Event<Header->Void>();
		onPauseSong = new Event<Header->Void>();
		onResumeSong = new Event<Header->Void>();
		onStopSong = new Event<Header->Void>();
		onDeath = new Event<Header->Int->Void>();

		onNoteHit = new Event<MetaNote->Float->Int64->Void>();
		onNoteMiss = new Event<MetaNote->Int64->Void>();
		onSustainComplete = new Event<MetaNote->Void>();
		onSustainRelease = new Event<MetaNote->Void>();
		onKeyPress = new Event<KeyCode->Void>();
		onKeyRelease = new Event<KeyCode->Void>();

		var timeSig = Chart.header.timeSig;
		changeBpmAt(0, Chart.header.bpm, timeSig[0], timeSig[1]);

		onStartSong.add(startSong);
		onStopSong.add(stopSong);
		onDeath.add(gameOver);

		var conductor = Main.conductor;
		conductor.offset = 0; // latency is now handled via noteTime, not conductor.offset

		if (playfieldEditorMode) {
			// ============================================================
			// PLAYFIELD EDITOR MODE — PlayFieldEditorMode.build() creates
			// ONLY the note system, HUD, song system and pause menu, and
			// hooks the editor's key + mouse input. No Field (stage/
			// characters/camera), no FunkinViewLua, no EventSystem, no
			// InputSystem, no CountdownDisplay. The song NEVER starts at
			// entry: songStarted stays false so Mixer.update advances
			// songPosition on its fake clock (completely silent — the
			// mixer transport is never started, nothing to mute). The
			// pause keybind starts real audio through onStartSong, the
			// same event the countdown path dispatches in gameplay.
			// ============================================================
			editorMode = new PlayFieldEditorMode(this);

			// Receptors enter the STATIC NoteSystem.notesBuf mid-constructor;
			// if anything below throws, `noteSystem` never gets assigned and
			// dispose() would skip it — leaving those receptors as permanent
			// strumline ghosts on screen. Wrap the build so a failure cleans
			// up whatever got created before rethrowing.
			try {
				editorMode.build();
			} catch (e:Dynamic) {
				Sys.println('[ PlayField ] editor-mode create failed: $e — cleaning up partial build');
				cleanupFailedCreate();
				throw e;
			}

			startedCountdown = false;
			return;
		}

		songPosition = -conductor.crochet * 4.5;

		field = new Field(this);

		HUD.init();
		if (!SaveData.state.preferences.hideHUD)
			hud = new HUD(display, this);

		inputSystem = new InputSystem(initialMania, this);

		NoteSystem.init();
		noteSystem = new NoteSystem(this);

		Mixer.init(Chart.header);

		eventSystem = new EventSystem(this);

		CountdownDisplay.init(roof);
		countdownDisp = new CountdownDisplay();
		countdownDisp.setupSounds();

		// Attach countdown-specific handler (drives countdownDisp and triggers onStartSong)
		countdownDisp.conductor.onBeatUnoffsetted.add(countdownBeatHit);

		PauseScreen.init(roof);
		pauseScreen = new PauseScreen(Chart.header.difficulty);

		scrollSpeed = Chart.header.speed;

		if (RenderingMode.enabled) {
			RenderingMode.initRender();
		}

		startedCountdown = !onRestartingForBackwardTimeSetting;

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			startedCountdown = startedCountdown
			|| funkinviewlua.callFunction('startCountdown', formatCustomSongName(Chart.header.title),
				Chart.header.difficulty)[0] != FunkinViewLua.Function_Stop;
			funkinviewlua.callFunction('createPost', null);
		}
		#end

		if (onRestartingForBackwardTimeSetting) {
			onRestartingForBackwardTimeSetting = false;
			startSong(Chart.header);
			setTime(timeForRestartingBackwardTime);

			songPosition = timeForRestartingBackwardTime;

			#if linc_luajit_funkinview
			if (!playfieldEditorMode) {
				funkinviewlua.callFunction('postTimeChange', timeForRestartingBackwardTime, Chart.header);
			}
			#end

			timeForRestartingBackwardTime = 0;
		}
	}

	/**
	 * Editor-mode create() failure recovery. A NoteSystem constructor that
	 * throws mid-way has already added its receptors to the STATIC
	 * NoteSystem.notesBuf/sustainsBuf — but `noteSystem` never got assigned,
	 * so a later dispose() would skip it and those receptors would stay on
	 * screen forever. Drop everything that was partially built here.
	 */
	function cleanupFailedCreate() {
		if (noteSystem != null) {
			noteSystem.dispose();
			noteSystem = null;
		} else {
			// The ctor threw before assignment: nothing references the
			// half-built instance, but its receptors sit in the static
			// buffers. Clear them — the buffers are re-filled element-by-
			// element by the next NoteSystem construction.
			NoteSystem.notesBuf.clear();
			NoteSystem.sustainsBuf.clear();
		}

		if (hud != null) {
			hud.dispose();
			hud = null;
		}

		if (pauseScreen != null) {
			pauseScreen.dispose();
			pauseScreen = null;
		}

		// Editor subsystem (keys, mouse input, instructions overlay).
		if (editorMode != null) {
			editorMode.dispose();
			editorMode = null;
		}
	}

	/**
		Reests the playfield's HUD.
	**/
	function resetHUD() {
		// dispose first then re-render since that's the easiest way out
		if (hud != null) {
			hud.dispose();
			hud = null;
		}

		if (!SaveData.state.preferences.hideHUD) {
			hud = new HUD(display, this);
			hud.alphaLerp = 1;
			hud.setHUDAlpha(1);
			hud.render();
			hud.update(Math.POSITIVE_INFINITY);
			hud.updateBuffers();
		}
	}

	/**
		Scans the song for an event file.
	**/
	function scanForEventFile(e:EventSystem) {
		var eventsPath = '$chartPath/eventList.json';
		if (!sys.FileSystem.exists(eventsPath)) {
			Sys.println("  [ Event System ] No event json file, but go on anyway.");
			return false;
		}
		Sys.println("  [ Event System ] Event json file found, parsing...");

		var content = sys.io.File.getContent(eventsPath);
		var rawJsonParent = haxe.Json.parse(content);

		var rawJson:Array<EventSystem.RawEventObject> = rawJsonParent.events;

		for (event in rawJson) {
			e.parsedObjects.push(new EventSystem.EventObject(event.evName, event.value1, event.value2 != null ? event.value2 : "", event.evTime));
		}

		e.init();

		return true;
	}

	/**
		Updates the playfield.
	**/
	var eventTimers:Array<EventTimer> = [];

	function update(deltaTime:Float) {
		if (disposed || paused)
			return;

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.updateVariablesList();
			funkinviewlua.callFunction('update', deltaTime);
		}
		#end

		if (!ready) {
			ready = true;
			return;
		}

		if (playfieldEditorMode) {
			// ============================================================
			// PLAYFIELD EDITOR MODE — update ONLY the song system, HUD,
			// note system and stepped strumline input. lua is skipped
			// above; no Field/EventSystem/CountdownDisplay exist here.
			// The songPosition in editor mode is EDITOR-OWNED: frozen
			// while silent (Mixer.update never adds deltaTime to it —
			// see Mixer.update's editorFrozen branch), moved only by
			// explicit editor seeks, and driven by the real audio clock
			// while the pause keybind holds playback on.
			// ============================================================
			display.update();
			view.update();

			Mixer.update(this, deltaTime);
			updateNoteLatency();
			noteTime = songPosition - noteLatency;
			Main.conductor.time = noteTime;

			if (hud != null)
				hud.update(deltaTime);

			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			if (noteSystem != null)
				noteSystem.update(pos);

			if (editorMode != null && editorMode.strumlineInput != null)
				editorMode.strumlineInput.update();
			return;
		}

		display.update();
		view.update();

		additiveDispShake.x = 0;
		additiveDispShake.y = 0;
		additiveViewShake.x = 0;
		additiveViewShake.y = 0;

		if (field != null)
			field.update(deltaTime);

		var ratio = Math.max(Math.min((deltaTime * 0.01), 1), 0);
		if (display.fov != 1)
			display.fov = Tools.lerp(display.fov, 1, ratio);
		if (view.fov != 1)
			view.fov = Tools.lerp(view.fov, 1, ratio);

		if (countdownDisp != null)
			countdownDisp.update(deltaTime);

		if (eventSystem != null && !died) {
			eventSystem.update(deltaTime, songPosition);
		}

		display.shake(dispShake.x + additiveDispShake.x, dispShake.y + additiveDispShake.y);
		if (field != null)
			field.updateCamera(deltaTime);

		if (!died) {
			if (startedCountdown) {
				Mixer.update(this, deltaTime);

				// songPosition stays raw — compute noteTime once
				updateNoteLatency();
				noteTime = songPosition - noteLatency;

				if (!songStarted && !songEnded) {
					if (countdownDisp != null && countdownDisp.conductor != null) {
						countdownDisp.conductor.time = songPosition;
					}
				}
			}

			var renderingModeEnabled = RenderingMode.enabled;
			if (hud != null)
				hud.update(renderingModeEnabled ? (1000 / RenderingMode.frameRate) : deltaTime);

			var t = startedCountdown ? noteTime : songPosition;

			Main.conductor.time = t;

			var pos = MetaNote.floatToMetaNotePosition(t);

			if (noteSystem != null) {
				noteSystem.update(pos);
			}

			#if linc_luajit_funkinview
			if (!playfieldEditorMode) {
				funkinviewlua.callFunction('updatePost', deltaTime);
				funkinviewlua.callFunction('postUpdate', deltaTime); // alternative syntax
			}
			#end

			return;
		}

		if (noteSystem != null) {
			noteSystem.dispose();
			noteSystem = null;
		}

		if (countdownDisp != null) {
			countdownDisp.dispose();
			countdownDisp = null;
		}

		if (pauseScreen != null) {
			pauseScreen.dispose();
			pauseScreen = null;
		}

		if (hud != null) {
			hud.dispose();
			hud = null;
		}
	}

	/**
		There is mainly nothing in this render function except a couple extra things.
	**/
	/**
		Paused-editor tick, called by Main while the editor's pause menu is
		open. A PURE render pass at the FROZEN editor position — the editor's
		note rendering stays on screen underneath the pause menu for its
		entire lifetime. Nothing here can move the song or process input:
		no Mixer.update (the transport is stopped and songPosition stays
		frozen), no conductor.time write, no strumlineInput.update, no
		eventSystem. Only the note system + HUD keep ticking at the frozen
		position, exactly what the un-paused editor branch does each frame
		while silent.
	**/
	function updatePausedEditor(deltaTime:Float) {
		if (disposed || !paused || !playfieldEditorMode)
			return;

		display.update();
		view.update();

		if (hud != null)
			hud.update(deltaTime);

		var pos = MetaNote.floatToMetaNotePosition(songPosition);
		if (noteSystem != null)
			noteSystem.update(pos);
	}

	function render() {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode)
			funkinviewlua.callFunction('render', null);
		#end

		var renderingModeEnabled = RenderingMode.enabled;
		if (renderingModeEnabled)
			update(1000 / RenderingMode.frameRate);

		if (playfieldEditorMode) {
			// ============================================================
			// PLAYFIELD EDITOR MODE — render the note system + HUD only.
			// The StrumlineNoteInteraction square lives in its own program
			// added AFTER notesProg, so it draws on top of the note system
			// render (and everything else) automatically. Position input is
			// the same editor-owned songPosition the update loop uses
			// (startedCountdown is always false in the editor).
			// ============================================================
			var noteSystem = noteSystem;
			if (noteSystem != null) {
				var pos = MetaNote.floatToMetaNotePosition(songPosition);
				noteSystem.renderNotes(pos);
			}

			if (hud != null) {
				hud.render();
				hud.updateBuffers();
			}
			return;
		}

		var noteSystem = noteSystem;
		if (noteSystem != null) {
			var t = startedCountdown ? noteTime : songPosition;
			var pos = MetaNote.floatToMetaNotePosition(t);
			noteSystem.renderNotes(pos);
		}

		var field = field;
		if (field != null) {
			field.render();
		}

		var hud = hud;
		if (hud != null) {
			hud.render();

			var scoreTxt = HUD.scoreTxt;
			var noteSpawner = noteSystem.noteSpawner;
			// if (scoreTxt != null) scoreTxt.text = ((noteSpawner.timeSpentOnIt * 1000000000) / Tools.int64ToFloat(noteSpawner.top - noteSpawner.bottom)) + "ns";
			// if (scoreTxt != null) scoreTxt.text = (noteSpawner.timeSpentOnIt * 1000) + "ms";

			hud.updateBuffers();
		}

		if (renderingModeEnabled)
			RenderingMode.pipeFrame();

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('renderPost', null);
			funkinviewlua.callFunction('postRender', null); // alternative syntax
		}
		#end
	}

	/**
		Pauses the playfield.
	**/
	function pause(showpausescreen:Bool = true) {
		if (disposed || paused || died || RenderingMode.enabled)
			return;

		#if linc_luajit_funkinview
		if (!playfieldEditorMode && funkinviewlua.callFunction('pause', null)[0] == FunkinViewLua.Function_Stop)
			return;
		#end

		if (showpausescreen)
			pauseScreen.open();
		if (songStarted)
			Mixer.stopMusic();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			noteSystem.resetStrumlines();
		}
		if (playfieldEditorMode) {
			if (editorMode != null)
				editorMode.onPause();
		} else if (inputSystem != null)
			inputSystem.removeEvents();

		paused = true;

		if (showpausescreen)
			Main.current.playScrollSound();

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('pausePost', null);
			funkinviewlua.callFunction('postPause', null); // alternative syntax
		}
		#end
	}

	/**
		Resumes the playfield.
	**/
	function resume() {
		if (disposed || !paused || died)
			return;

		#if linc_luajit_funkinview
		if (!playfieldEditorMode)
			funkinviewlua.callFunction('resume', null);
		#end

		pauseScreen.close();
		if (!RenderingMode.enabled && songStarted && !songEnded)
			Mixer.startMusic();
		if (playfieldEditorMode) {
			if (editorMode != null)
				editorMode.onResume();
		} else if (inputSystem != null) {
			Tools.forSync(inputSystem.addEvents);
		}

		paused = false;

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('resumePost', null);
			funkinviewlua.callFunction('postResume', null); // alternative syntax
		}
		#end
	}

	function countdownBeatHit(beat:Float) {
		if (beat == 0 && !songStarted) {
			onStartSong.dispatch(Chart.header);

			if (countdownDisp.conductor != null)
				countdownDisp.conductor.onBeatUnoffsetted.remove(countdownBeatHit);
		}

		if (beat < 0) {
			// Countdown visuals: maps beats -4..-1 to 3..0
			countdownDisp.countdownTick(Math.floor(4 + beat));
		}
	}

	function stepHit(step:Float) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('stepHit', step);
		}
		#end
	}

	function beatHit(beat:Float) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('beatHit', beat);
		}
		#end
	}

	function measureHit(measure:Float) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('measureHit', measure);
		}
		#end

		if (measure >= 0 && !playfieldEditorMode && SaveData.state.preferences.cameraZooming && songStarted) {
			display.fov += 0.025;
			view.fov += 0.011;
		}
	}

	function hitNote(note:MetaNote, timing:Float, notesInOne:Int64, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos:Float = playfieldEditorMode ? 0 : MetaNote.metaNotePositionToSongTime(note.position);
		if (!playfieldEditorMode
			&& funkinviewlua.callFunction('hitNote', notePos, note.index, note.duration, note.type, timing, notesInOne)[0] == FunkinViewLua.Function_Stop) {
			return;
		}
		#end

		var lane = note.type;

		var index = 1 + lane;
		if (Chart.header.voicesDirs.length > 1)
			index = 1;
		if (index > 0 && index <= Mixer.trackCount)
			Mixer.changeTrackVolume(index, 1);

		// During create() the NoteSystem constructor itself draws the spawn
		// window (editor mode starts at songPosition 0) and calls back into
		// here before `noteSystem` has been assigned. No note system →
		// nothing is playable → opponent-style health-only handling.
		var playable = noteSystem != null && noteSystem.strumlines[lane].playable;

		if (!playable) {
			health -= healthLoss[lane];
			if (health < 0.05) {
				health = 0.05;
			}
			return;
		}

		combo += notesInOne;

		health += healthGain[lane] * Tools.int64ToFloat(notesInOne);
		if (health > 1) {
			health = 1;
		}

		var preferences = SaveData.state.preferences;
		var scoreTxt = HUD.scoreTxt;

		if (scoreTxt != null && preferences.scoreTxtBopping) {
			scoreTxt.scale = 1.1;
		}

		var absTiming = Math.abs(timing);
		var notesInOne_accuracy = notesInOne * 10000;

		if (absTiming >= ratingJudgementList[ratingJudgementList.length - 1][0]) {
			var worstJudgement = ratingJudgementList[ratingJudgementList.length - 1];
			var judgementID = Std.int(worstJudgement[1]);
			var judgementAcc = haxe.Int64Helper.fromFloat(worstJudgement[2] * 10000);
			var judgementScore = Std.int(worstJudgement[3]);
			if (hud != null && preferences.ratingPopup)
				hud.respondWithRatingID(judgementID);
			playJudgementHitsound(judgementID);
			accuracy.increment(judgementAcc, false, notesInOne * 10000);
			score += judgementScore * notesInOne;
			postHitNote(#if linc_luajit_funkinview notePos, #end note, timing, notesInOne);
			return;
		}

		for (i in 0...ratingJudgementList.length) {
			if (absTiming < ratingJudgementList[i][0]) {
				var judgement = ratingJudgementList[i];
				var judgementID = Std.int(judgement[1]);
				var judgementAcc = haxe.Int64Helper.fromFloat(judgement[2] * 10000);
				var judgementScore = Std.int(judgement[3]);
				if (hud != null && preferences.ratingPopup)
					hud.respondWithRatingID(judgementID);
				playJudgementHitsound(judgementID);
				accuracy.increment(judgementAcc, false, notesInOne * 10000);
				score += judgementScore * notesInOne;
				postHitNote(#if linc_luajit_funkinview notePos, #end note, timing, notesInOne);
				return;
			}
		}
	}

	/**
		Plays the cached hitsound on every Sick (0) or Good (1) hit when
		the Audio > Toggle Hitsound option is enabled.  The sound itself
		is preloaded inside Main alongside the menu sounds.
	**/
	inline function playJudgementHitsound(judgementID:Int) {
		if (SaveData.state.audio.hitsound && judgementID <= 1)
			Main.current.playHitsound();
	}

	function postHitNote(#if linc_luajit_funkinview notePos:Float, #end note:MetaNote, timing:Float, notesInOne:Int64) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('hitNotePost', notePos, note.index, note.duration, note.type, timing, notesInOne);
			funkinviewlua.callFunction('postHitNote', notePos, note.index, note.duration, note.type, timing, notesInOne); // alternative syntax
		}
		#end
	}

	function missNote(note:MetaNote, notesInOne:Int64, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos:Float = playfieldEditorMode ? 0 : MetaNote.metaNotePositionToSongTime(note.position);
		if (!playfieldEditorMode
			&& funkinviewlua.callFunction('missNote', notePos, note.index, note.duration, note.type, notesInOne)[0] == FunkinViewLua.Function_Stop) {
			return;
		}
		#end

		if (practiceMode && health < 0.05) {
			health = 0.05;
		}

		var lane = note.type;

		var index = 1 + lane;
		if (Chart.header.voicesDirs.length > 1)
			index = 1;
		if (index > 0 && index <= Mixer.trackCount)
			Mixer.changeTrackVolume(index, 0);

		health -= healthLoss[lane] * Tools.int64ToFloat(notesInOne);

		combo = 0;
		score -= 50 * notesInOne;
		misses += notesInOne;
		accuracy.increment(10000, true, notesInOne * 10000);

		if (health < 0 && !disposed)
			onDeath.dispatch(Chart.header, lane);

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('missNotePost', notePos, note.index, note.duration, note.type, notesInOne);
			funkinviewlua.callFunction('postMissNote', notePos, note.index, note.duration, note.type, notesInOne); // alternative syntax
		}
		#end
	}

	function completeSustain(note:MetaNote, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos:Float = playfieldEditorMode ? 0 : MetaNote.metaNotePositionToSongTime(note.position);
		if (!playfieldEditorMode)
			funkinviewlua.callFunction('completeSustain', notePos, note.index, note.duration, note.type);
		#end

		var lane = note.type;

		// Same create()-time guard as hitNote: the NoteSystem ctor can call
		// back into here before `noteSystem` is assigned.
		if (noteSystem != null && noteSystem.strumlines[lane].confirmed(note.index))
			return;

		var playable = noteSystem != null && noteSystem.strumlines[lane].playable;

		if (!playable) {
			health -= healthLoss[lane];

			if (health < 0.05) {
				health = 0.05;
			}
		} else {
			health += healthGain[lane];

			if (health > 1) {
				health = 1;
			}
		}

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('completeSustainPost', notePos, note.index, note.duration, note.type);
			funkinviewlua.callFunction('postCompleteSustain', notePos, note.index, note.duration, note.type); // alternative syntax
		}
		#end
	}

	inline function releaseSustain(note:MetaNote, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos:Float = playfieldEditorMode ? 0 : MetaNote.metaNotePositionToSongTime(note.position);
		if (!playfieldEditorMode)
			funkinviewlua.callFunction('releaseSustain', notePos, note.index, note.duration, note.type);
		#end

		combo = 0;

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('releaseSustainPost', notePos, note.index, note.duration, note.type);
			funkinviewlua.callFunction('postReleaseSustain', notePos, note.index, note.duration, note.type); // alternative syntax
		}
		#end
	}

	var songStartTime:Float = 0.0; // Hardware timestamp when the song actually started

	function startSong(header:Header) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode)
			funkinviewlua.callFunction('startSong', formatCustomSongName(header.title), header.difficulty);
		#end

		Sys.println('Song activity is on');

		if (!RenderingMode.enabled) {
			Mixer.startMusic();
		}

		songStarted = true;
		songEnded = false;

		var conductor = Main.conductor;
		conductor.onStep.add(stepHit);
		conductor.onBeat.add(beatHit);
		conductor.onMeasure.add(measureHit);

		if (countdownDisp != null) {
			if (countdownDisp.conductor != null)
				countdownDisp.conductor.onBeatUnoffsetted.remove(countdownBeatHit);
		}

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('startSongPost', formatCustomSongName(header.title), header.difficulty);
			funkinviewlua.callFunction('postStartSong', formatCustomSongName(header.title), header.difficulty); // alternative syntax
		}
		#end
	}

	function stopSong(header:Header) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode)
			funkinviewlua.callFunction('stopSong', formatCustomSongName(header.title), header.difficulty);
		#end

		Sys.println('Song activity is off');

		if (!RenderingMode.enabled) {
			Mixer.stopMusic();
		} else {
			RenderingMode.stopRender();
		}

		songEnded = true;
		songStarted = false;

		Mixer.setTime(0, null);

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('stopSongPost', formatCustomSongName(header.title), header.difficulty);
			funkinviewlua.callFunction('postStopSong', formatCustomSongName(header.title), header.difficulty); // alternative syntax
		}
		#end

		// Editor mode returns to the main menu like gameplay does.
		Main.switchState(MAIN_MENU);
	}

	function gameOver(header:Header, lane:Int) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('gameOver', null);
		}
		#end

		// Editor mode never dies (no playable strumlines → no misses), but
		// inputSystem is null there, so guard the teardown anyway.
		if (inputSystem != null) {
			inputSystem.removeEvents();
			haxe.Timer.delay(inputSystem.addEvents, 2000); // prevent instant end gameover
		}

		onDeath.remove(gameOver);

		died = true;
		songEnded = true;
		songPosition = 0;

		Sys.println("Game Over");

		if (RenderingMode.enabled) {
			RenderingMode.stopRender();
		}

		var conductor = Main.conductor;
		conductor.onMeasure.remove(measureHit);
		conductor.onStep.remove(stepHit);
		conductor.onBeat.remove(beatHit);

		Mixer.stopMusic();

		Mixer.setTime(0, null);

		// field (stage/actors) never exists in editor mode.
		if (field != null) {
			var char = field.actors[lane + field.numSpectators];
			if (char == null)
				char = field.actors[1 + field.numSpectators];

			field.actorOnGameOver = char;
		}

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('gameOverPost', null);
			funkinviewlua.callFunction('postGameOverPost', null); // alternative syntax
		}
		#end

		deathCounter++;
	}

	var customSongName = "";

	// helper function made for playfield
	/**
		Debug-key handler (the controls.game.debug bind, default 7/C per
		saved binds). Works from BOTH gameplay and editor mode and while
		paused: flips the editorModeNext flag the next GAMEPLAY build
		reads, dispatches the lua `toggleEditorMode` callback BEFORE the
		toggle (song name, difficulty, artist — same name formatting the
		startSong callbacks use), then restarts the song so the playfield
		is rebuilt in the other mode. Mirrors exactly what
		DeveloperStuff.testPlayfieldInputStuff does, minus the other dev
		test keys, so both entry points stay in one behavior.
	**/
	function debugToggleEditorMode() {
		if (disposed)
			return;

		var entering = !PlayField.editorModeNext;
		var header = Chart.header;

		#if linc_luajit_funkinview
		// The toggle dispatch happens BEFORE the mode flips — scripts get
		// the song context while the (still running) playfield can still
		// answer questions about it. In editor mode lua never runs, so
		// this only fires when toggling OUT of gameplay into the editor
		// (the gameplay→editor direction is where a script cares anyway:
		// it is about to lose control until the toggle back).
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('toggleEditorMode', formatCustomSongName(header.title), header.difficulty, header.artist);
		}
		#end

		PlayField.editorModeNext = entering;
		File.setEditorMode(entering);
		Sys.println('  [ Developer ] playfieldEditorMode ${entering ? "ON" : "OFF"} — restarting song.');

		// Same teardown the backwards-seek restart does: stop the music
		// and unhook input BEFORE the dispose + recreate cycle, so the
		// playfield is never disposed while its audio clock is still
		// running (which leaves the mixer state machine mid-flight for
		// the next Mixer.init/startMusic).
		if (!paused)
			pause(false);
		Tools.forSync(() -> {
			Main.switchState(GAMEPLAY, true);
		});
	}

	// -------------------------------------------------------------------
	// Debug key (playfield-owned window listener)
	// -------------------------------------------------------------------

	var debugKeysActive:Bool = false;

	function attachDebugKey() {
		if (debugKeysActive || disposed)
			return;
		debugKeysActive = true;
		#if !android
		lime.app.Application.current.window.onKeyDown.add(debugKeyDown);
		#end
	}

	function detachDebugKey() {
		if (!debugKeysActive)
			return;
		debugKeysActive = false;
		#if !android
		lime.app.Application.current.window.onKeyDown.remove(debugKeyDown);
		#end
	}

	/**
		Window-level dispatch for the debug key. DeveloperStuff (FV_DEBUG
		builds) fires on the same window event with its own listener; to
		avoid a double toggle, whoever runs first wins — DeveloperStuff
		flips this flag as part of its restart, and the same-frame
		re-press here sees the flag already moved and bails.
	**/
	function debugKeyDown(code:lime.ui.KeyCode, mod:lime.ui.KeyModifier) {
		if (disposed)
			return;
		if (code != SaveData.state.controls.game.debug)
			return;

		// Already consumed by DeveloperStuff this press? It flips
		// editorModeNext AND queues the restart; if the flag or the
		// queued switch changed since this playfield was built, the
		// press belongs to the other handler.
		if (editorModeNext != playfieldEditorMode)
			return;

		debugToggleEditorMode();
	}

	inline function formatCustomSongName(title:String) {
		return customSongName == "" ? title : customSongName;
	}

	var customStage = "";

	// helper function made for playfield
	inline function formatCustomStage(stage:String) {
		return customStage == "" ? stage : customStage;
	}

	inline function setCustomStage(stage:String) {
		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('onChangeStage', stage);
		}
		#end
	}

	/**
		Disposes the playfield.
	**/
	function dispose() {
		ready = false;
		disposed = true;

		// The playfield-owned debug-key window listener goes first —
		// nothing after this point may receive input.
		detachDebugKey();

		// Editor-only systems first (they own window events + programs).
		if (playfieldEditorMode && editorMode != null) {
			editorMode.dispose();
			editorMode = null;
		}

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('dispose', null);
		}
		#end

		var conductor = Main.conductor;
		conductor.onMeasure.remove(measureHit);
		conductor.onStep.remove(stepHit);
		conductor.onBeat.remove(beatHit);

		if (field != null) {
			field.dispose();
			field = null;
		}

		if (inputSystem != null) {
			inputSystem.dispose();
			inputSystem = null;
		}

		if (noteSystem != null) {
			noteSystem.dispose();
			noteSystem = null;
		}

		if (countdownDisp != null) {
			countdownDisp.dispose();
			countdownDisp = null;
		}

		if (pauseScreen != null) {
			pauseScreen.dispose();
			pauseScreen = null;
		}

		if (hud != null) {
			hud.dispose();
			hud = null;
		}

		onStartSong.remove(startSong);
		onStopSong.remove(stopSong);
		onDeath.remove(gameOver);

		onStartSong = null;
		onPauseSong = null;
		onResumeSong = null;
		onStopSong = null;
		onDeath = null;
		onNoteHit = null;
		onNoteMiss = null;
		onSustainComplete = null;
		onSustainRelease = null;
		onKeyPress = null;
		onKeyRelease = null;

		songEnded = true;

		Chart.destroy();

		if (display.fov != 1) {
			display.fov = 1;
			display.x = 0;
			display.y = 0;
			display.r = 0;
		}
		if (view.fov != 1) {
			view.fov = 1;
			view.x = 0;
			view.y = 0;
			view.r = 0;
		}

		#if linc_luajit_funkinview
		if (!playfieldEditorMode) {
			funkinviewlua.callFunction('disposePost', null);
			funkinviewlua.callFunction('postDispose', null); // alternative syntax
			funkinviewlua.dispose();
		}
		#end
	}

}