package gameplay;

import lime.ui.KeyCode;
import lime.app.Event;

/**
	The home of the gameplay state.
	This is the main class that handles the playfield and all of its components.
	It is responsible for initializing the playfield, updating it, and disposing of it when the game is over.
	This class is used in the Main class to handle the gameplay state.

	=== Editor mode ===

	When `editorModeNext` was set before the state switch, create() builds
	the editor subset ONLY (see PlayFieldEditorMode): HUD, note system,
	song system (Mixer), pause menu — plus the stepped strumline input.
	The frontend (PlayFieldFrontEnd: stage/actors, countdown, lua),
	EventSystem and InputSystem are NEVER CONSTRUCTED in editor mode, so
	`frontend`, `eventSystem` and `inputSystem` are null there and every
	path that touches them already null-guards.

	@since Development
**/
@:publicFields
class PlayField {
	var roof(default, null):CustomDisplay;
	var display(default, null):CustomDisplay;
	var view(default, null):CustomDisplay;

	/**
		Set by the editor entry points (EditorMenu, DeveloperStuff debug
		key) before the state switch; consumed by create() to build the
		playfield in editor mode. Toggling routes through
		Main.switchState(GAMEPLAY), whose dispose + recreate IS the song
		restart.
	**/
	static var editorModeNext:Bool = false;

	/** True when this playfield is the chart editor. */
	var playfieldEditorMode(default, null):Bool = false;

	/** The editor-mode subsystem; non-null only in playfieldEditorMode. */
	var editorMode(default, null):PlayFieldEditorMode;

	/**
		The gameplay frontend (stage/actors, countdown, lua). NEVER built
		in editor mode — `frontend` is null there, and the `field`,
		`countdownDisp` and `funkinviewlua` accessors below return null
		with it. All gameplay call sites null-guard these.
	**/
	var frontend(default, null):PlayFieldFrontEnd;

	/** The stage/characters — null in editor mode (no frontend). */
	var field(get, never):Field;

	inline function get_field():Field {
		return frontend != null ? frontend.field : null;
	}

	/** The countdown display — null in editor mode (no frontend). */
	var countdownDisp(get, never):CountdownDisplay;

	inline function get_countdownDisp():CountdownDisplay {
		return frontend != null ? frontend.countdownDisp : null;
	}

	#if linc_luajit_funkinview
	/** The lua VM — null in editor mode (no frontend). */
	var funkinviewlua(get, never):FunkinViewLua;

	inline function get_funkinviewlua():FunkinViewLua {
		return frontend != null ? frontend.funkinviewlua : null;
	}
	#end

	/** Fire-and-forget lua dispatch; no-op in editor mode. */
	inline function luaCall(fname:String, args:haxe.Rest<Dynamic>) {
		#if linc_luajit_funkinview
		if (frontend != null)
			frontend.luaCall(fname, args);
		#end
	}

	/** Lua dispatch whose Function_Stop result matters; false without a frontend. */
	inline function luaCallStop(fname:String, args:haxe.Rest<Dynamic>):Bool {
		#if linc_luajit_funkinview
		if (frontend != null)
			return frontend.luaCallStop(fname, args);
		#end
		return false;
	}

	private var chartPath(default, null):String;

	/**
		Editor-only accessor for the private chartPath — the editor's
		event lane needs the folder that holds eventList.json (same
		folder EventSystem scans). Same pass-in spirit as
		PlayFieldFrontEnd.build(chartPath), but the editor subsystem is
		built from the playfield itself, so an accessor is the honest
		minimal surface.
	**/
	function chartPathForEditor():String {
		return chartPath;
	}

	function new(path:String) {
		chartPath = Paths.asset(path);

		Chart.load(chartPath);
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.roof = roof;
		this.display = display;
		this.view = view;

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
	]; // how this new modifiable system works: you simply just set this array to a new selection of ratings, however you want it.

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

	/**
		Editor-only write access: PlayFieldEditorMode.togglePlayback stops
		playback by dropping songStarted (switches Mixer.update to the
		frozen-clock branch). startSong's own writes go through the class
		itself.
	**/
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

	var hud(default, null):HUD;

	var inputSystem(default, null):InputSystem;
	var noteSystem(default, null):NoteSystem;
	var eventSystem(default, null):EventSystem;

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
		if (disposed || songEnded || paused || died)
			return;

		// EDITOR MODE: the base setTime's backwards-seek branch is a full
		// song restart (pause + switchState + recreate) because judged
		// gameplay state cannot be un-judged. The editor has no judged
		// state — its render path is pure — so ALL editor seeks, backwards
		// included, take the light path: seek the PCM transport, snap the
		// editor-owned position, reset+redraw the note system.
		if (playfieldEditorMode) {
			// Frozen editor with no playback: seekTo() is the only mover
			// (base setTime is a no-op there). While ENTER playback is on,
			// external setters (DeveloperStuff PERIOD/COMMA) take the
			// same light seek path.
			if (!songStarted && (editorMode == null || !editorMode.playing))
				return;
			if (value < 0)
				value = 0;
			if (value > Mixer.length - 1000)
				value = Mixer.length - 1000;
			Mixer.setTime(Math.max(value, 0.0), this);
			songPosition = value;
			if (noteSystem != null) {
				var pos = MetaNote.floatToMetaNotePosition(value);
				noteSystem.onSongPositionJump(pos, pushToOffset);
			}
			return;
		}

		if (!songStarted)
			return;
		if (value > Mixer.length - 1000)
			value = Mixer.length - 1000;

		var isBackwards = value < songPosition;

		if (isBackwards) {
			onRestartingForBackwardTimeSetting = true;
			timeForRestartingBackwardTime = value;

			if (eventSystem != null)
				eventSystem.clearEventTimers(); // immediately clear out any event timers to prevent them flooding the rest of the song through

			luaCall('preTimeChange', timeForRestartingBackwardTime, Chart.header);

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
		playfieldEditorMode = editorModeNext;

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
		songPosition = -conductor.crochet * 4.5;

		HUD.init();
		if (!SaveData.state.preferences.hideHUD)
			hud = new HUD(display, this);

		// InputSystem's constructor attaches the gameplay keybind handlers
		// to the window — the editor (StrumlineNoteInteraction + its own
		// key handler) must never have them, so it is not constructed at
		// all in editor mode instead of being disposed after the fact.
		if (!playfieldEditorMode)
			inputSystem = new InputSystem(initialMania, this);

		NoteSystem.init();
		noteSystem = new NoteSystem(this);

		Mixer.init(Chart.header);

		// EventSystem scans and dispatches the song's scripted events —
		// a pure gameplay concern; the editor chart carries no runtime
		// events and must never trigger them.
		if (!playfieldEditorMode)
			eventSystem = new EventSystem(this);

		// The pause MENU is a gameplay construct. The editor's pause is a
		// bare pause(false) — the frozen-flag freeze, no menu, no ticking
		// (Main skips update+render while paused, both modes) — so the
		// screen is never constructed there and every access below is
		// null-guarded.
		if (!playfieldEditorMode) {
			PauseScreen.init(roof);
			pauseScreen = new PauseScreen(Chart.header.difficulty);
		}

		scrollSpeed = Chart.header.speed;

		// ----------------------------------------------------------------
		// EDITOR MODE: build the editor subset and STOP here. The frontend
		// (stage/actors, countdown, lua), InputSystem and EventSystem are
		// never constructed, so `field`, `countdownDisp`, `funkinviewlua`,
		// `inputSystem` and `eventSystem` are all null by construction.
		// ----------------------------------------------------------------
		if (playfieldEditorMode) {
			editorMode = new PlayFieldEditorMode(this);
			editorMode.build();
			startedCountdown = false;

			// The playfield-owned debug-key window listener (see
			// attachDebugKey) covers both modes for the playfield's whole
			// lifetime — running, paused, gameplay and editor.
			attachDebugKey();
			return;
		}

		// ----------------------------------------------------------------
		// GAMEPLAY: build the frontend (stage, countdown, lua) on top of
		// the shared subsystems above.
		// ----------------------------------------------------------------
		frontend = new PlayFieldFrontEnd(this);
		frontend.build(chartPath);

		// Debug key active in gameplay too (see attachDebugKey).
		attachDebugKey();

		// Attach countdown-specific handler (drives countdownDisp and triggers onStartSong)
		countdownDisp.conductor.onBeatUnoffsetted.add(countdownBeatHit);

		if (RenderingMode.enabled) {
			RenderingMode.initRender();
		}

		startedCountdown = !onRestartingForBackwardTimeSetting;

		// A script returning Function_Stop cancels the automatic countdown
		// (the script starts the song itself); anything else — including
		// no frontend at all — keeps the engine countdown.
		if (luaCallStop('startCountdown', formatCustomSongName(Chart.header.title), Chart.header.difficulty))
			startedCountdown = true;
		luaCall('createPost', null);

		if (onRestartingForBackwardTimeSetting) {
			onRestartingForBackwardTimeSetting = false;
			startSong(Chart.header);
			setTime(timeForRestartingBackwardTime);

			songPosition = timeForRestartingBackwardTime;

			luaCall('postTimeChange', timeForRestartingBackwardTime, Chart.header);

			timeForRestartingBackwardTime = 0;
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
		if (funkinviewlua != null)
			funkinviewlua.updateVariablesList();
		#end
		luaCall('update', deltaTime);

		if (!ready) {
			ready = true;
			return;
		}

		display.update();
		view.update();

		additiveDispShake.x = 0;
		additiveDispShake.y = 0;
		additiveViewShake.x = 0;
		additiveViewShake.y = 0;

		if (playfieldEditorMode) {
			// ============================================================
			// EDITOR MODE — update ONLY the song system, HUD, note system
			// and the stepped strumline input. No frontend (stage/countdown/
			// lua never exist), no EventSystem, no InputSystem. The
			// songPosition is editor-owned: frozen while silent, driven by
			// the real audio clock while ENTER playback is on.
			// ============================================================
			Mixer.update(this, deltaTime);
			updateNoteLatency();
			noteTime = songPosition - noteLatency;
			Main.conductor.time = noteTime;

			if (hud != null)
				hud.update(deltaTime);

			// Smooth scroll: the note window/conductor run on the
			// SMOOTHED render position (a fast lerp toward songPosition
			// while silent — wheel/arrow seeks glide instead of
			// teleporting; exact while playing). songPosition itself
			// stays the exact seek target for the readout and edit math.
			var renderPos = editorMode != null ? editorMode.advanceSmoothScroll(deltaTime) : songPosition;
			var pos = MetaNote.floatToMetaNotePosition(renderPos);
			if (noteSystem != null)
				noteSystem.update(pos);

			// AFTER hud.update (whose updateScoreText is overwritten) and
			// AFTER noteSystem.update (so the cull window is this frame's
			// live value, not last frame's).
			if (editorMode != null)
				editorMode.updateReadout();

			if (editorMode != null && editorMode.strumlineInput != null)
				editorMode.strumlineInput.update(deltaTime);

			if (editorMode != null && editorMode.exitPopup != null)
				editorMode.exitPopup.update(deltaTime);

			if (editorMode != null && editorMode.instructionsPopup != null)
				editorMode.instructionsPopup.update(deltaTime);
			return;
		}

		if (frontend != null)
			frontend.update(deltaTime);

		var ratio = Math.max(Math.min((deltaTime * 0.01), 1), 0);
		if (display.fov != 1)
			display.fov = Tools.lerp(display.fov, 1, ratio);
		if (view.fov != 1)
			view.fov = Tools.lerp(view.fov, 1, ratio);

		if (eventSystem != null && !died) {
			eventSystem.update(deltaTime, songPosition);
		}

		display.shake(dispShake.x + additiveDispShake.x, dispShake.y + additiveDispShake.y);
		if (frontend != null)
			frontend.updateCamera(deltaTime);

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

			luaCall('updatePost', deltaTime);
			luaCall('postUpdate', deltaTime); // alternative syntax

			return;
		}

		// DIED: the game-over screen now OWNS the frame. Field.gameOver()
		// (via frontend.update above) just started the death sequence —
		// the death actor animates, its music/sfx play, InputSystem's
		// gameCondition branch routes keys to endGameOver, and mouse
		// clicks go through Main.mouseDown to the same place. All of
		// that needs the frontend (Field) and the input system to STAY
		// ALIVE.
		//
		// The notes and the HUD, though, are DEAD the moment the death
		// callback fires: gameOver() schedules
		// disposeNoteSystemAndHUD() (deferred one tick — it can fire
		// from inside NoteSystem's own update loop), and this branch
		// runs it directly as the belt-and-suspenders path (whichever
		// gets there first; the second call no-ops on nulls). What
		// remains on screen: the stage fading to black, the death actor
		// — the classic bare game-over look.
		//
		// (The OLD code also disposed the FRONTEND here, same frame,
		// which destroyed the death screen the instant it appeared —
		// frontend.dispose() nulls PlayField.field, so InputSystem
		// bailed on every key: black screen, no input, no state switch.
		// The frontend stays; teardown happens through endGameOver →
		// switchState → stateDestroy → dispose().)
		//
		// Keep only the pause menu from intercepting input mid-death:
		// its ESC handler would pause a dead playfield.
		disposeNoteSystemAndHUD();
		if (pauseScreen != null) {
			pauseScreen.dispose();
			pauseScreen = null;
		}
	}

	/**
		There is mainly nothing in this render function except a couple extra things.
	**/
	function render() {
		// EDITOR MODE: notes + HUD only, at the editor-owned position
		// (startedCountdown is always false there — but keep the split
		// explicit anyway). The StrumlineNoteInteraction square's program
		// was added AFTER notesProg, so it draws on top of the note
		// system render automatically.
		if (playfieldEditorMode) {
			var noteSystem = noteSystem;
			if (noteSystem != null) {
				// Render at the SAME smoothed position update() advanced
				// the window to — otherwise renderNotes' own cull pass
				// fights the lerp and the notes jitter.
				var renderPos = editorMode != null ? editorMode.smoothPosition : songPosition;
				noteSystem.renderNotes(MetaNote.floatToMetaNotePosition(renderPos));
			}
			if (hud != null) {
				hud.render();
				hud.updateBuffers();
			}
			return;
		}

		// GAMEPLAY: baseline order — lua render, rendering-mode tick,
		// notes, stage, HUD.
		luaCall('render', null);

		var renderingModeEnabled = RenderingMode.enabled;
		if (renderingModeEnabled)
			update(1000 / RenderingMode.frameRate);
		var noteSystem = noteSystem;
		if (noteSystem != null) {
			var t = startedCountdown ? noteTime : songPosition;
			var pos = MetaNote.floatToMetaNotePosition(t);
			noteSystem.renderNotes(pos);
		}

		var frontend = frontend;
		if (frontend != null) {
			frontend.render();
		}

		var hud = hud;
		if (hud != null) {
			hud.render();

			// (The old debug lines here dereferenced
			// noteSystem.noteSpawner — a guaranteed NPE after the
			// game-over dispose, which kills the note system while the
			// HUD still renders one last frame.)

			hud.updateBuffers();
		}

		if (renderingModeEnabled)
			RenderingMode.pipeFrame();

		luaCall('renderPost', null);
		luaCall('postRender', null); // alternative syntax
	}

	/**
		Pauses the playfield.
	**/
	function pause(showpausescreen:Bool = true) {
		if (disposed || paused || died || RenderingMode.enabled)
			return;

		if (luaCallStop('pause', null))
			return;

		if (showpausescreen && pauseScreen != null)
			pauseScreen.open();
		if (songStarted)
			Mixer.stopMusic();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			noteSystem.resetStrumlines();
		}
		if (!playfieldEditorMode && inputSystem != null)
			inputSystem.removeEvents();

		paused = true;

		if (showpausescreen)
			Main.current.playScrollSound();

		luaCall('pausePost', null);
		luaCall('postPause', null); // alternative syntax
	}

	/**
		Resumes the playfield.
	**/
	function resume() {
		if (disposed || !paused || died)
			return;

		luaCall('resume', null);

		if (pauseScreen != null)
			pauseScreen.close();
		if (!RenderingMode.enabled && songStarted && !songEnded)
			Mixer.startMusic();
		if (!playfieldEditorMode && inputSystem != null) {
			Tools.forSync(inputSystem.addEvents);
		}

		paused = false;

		luaCall('resumePost', null);
		luaCall('postResume', null); // alternative syntax
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
		luaCall('stepHit', step);
	}

	function beatHit(beat:Float) {
		luaCall('beatHit', beat);
	}

	function measureHit(measure:Float) {
		luaCall('measureHit', measure);

		if (measure >= 0 && !playfieldEditorMode && SaveData.state.preferences.cameraZooming && songStarted) {
			display.fov += 0.025;
			view.fov += 0.011;
		}
	}

	function hitNote(note:MetaNote, timing:Float, notesInOne:Int64, _i:Int64) {
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		if (luaCallStop('hitNote', notePos, note.index, note.duration, note.type, timing, notesInOne)) {
			return;
		}

		var lane = note.type;

		var index = 1 + lane;
		if (Chart.header.voicesDirs.length > 1)
			index = 1;
		if (index > 0 && index <= Mixer.trackCount)
			Mixer.changeTrackVolume(index, 1);

		// During create() the NoteSystem constructor itself draws the
		// spawn window (editor mode starts at songPosition 0) and calls
		// back into here before `noteSystem` has been assigned. No note
		// system → nothing is playable → opponent-style health-only
		// handling.
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
			postHitNote(notePos, note, timing, notesInOne);
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
				postHitNote(notePos, note, timing, notesInOne);
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

	function postHitNote(notePos:Float, note:MetaNote, timing:Float, notesInOne:Int64) {
		luaCall('hitNotePost', notePos, note.index, note.duration, note.type, timing, notesInOne);
		luaCall('postHitNote', notePos, note.index, note.duration, note.type, timing, notesInOne); // alternative syntax
	}

	function missNote(note:MetaNote, notesInOne:Int64, _i:Int64) {
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		if (luaCallStop('missNote', notePos, note.index, note.duration, note.type, notesInOne)) {
			return;
		}

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

		luaCall('missNotePost', notePos, note.index, note.duration, note.type, notesInOne);
		luaCall('postMissNote', notePos, note.index, note.duration, note.type, notesInOne); // alternative syntax
	}

	function completeSustain(note:MetaNote, _i:Int64) {
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		luaCall('completeSustain', notePos, note.index, note.duration, note.type);

		var lane = note.type;

		if (noteSystem != null && noteSystem.strumlines[lane].confirmed(note.index))
			return;

		// Same create()-time guard as hitNote: the NoteSystem ctor can
		// call back into here before `noteSystem` is assigned.
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

		luaCall('completeSustainPost', notePos, note.index, note.duration, note.type);
		luaCall('postCompleteSustain', notePos, note.index, note.duration, note.type); // alternative syntax
	}

	inline function releaseSustain(note:MetaNote, _i:Int64) {
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		luaCall('releaseSustain', notePos, note.index, note.duration, note.type);

		combo = 0;

		luaCall('releaseSustainPost', notePos, note.index, note.duration, note.type);
		luaCall('postReleaseSustain', notePos, note.index, note.duration, note.type); // alternative syntax
	}

	var songStartTime:Float = 0.0; // Hardware timestamp when the song actually started

	function startSong(header:Header) {
		luaCall('startSong', formatCustomSongName(header.title), header.difficulty);

		Sys.println('Song activity is on');

		if (!RenderingMode.enabled) {
			Mixer.startMusic();
		}

		songStarted = true;
		songEnded = false;

		var conductor = Main.conductor;
		// Idempotent hook-up: lime's Event.add does NOT dedupe, and the
		// editor's ENTER toggle dispatches onStartSong repeatedly
		// (start→stop→start cycles) — remove-first keeps the listeners
		// from stacking one copy per playback cycle.
		conductor.onStep.remove(stepHit);
		conductor.onBeat.remove(beatHit);
		conductor.onMeasure.remove(measureHit);
		conductor.onStep.add(stepHit);
		conductor.onBeat.add(beatHit);
		conductor.onMeasure.add(measureHit);

		if (countdownDisp != null) {
			if (countdownDisp.conductor != null)
				countdownDisp.conductor.onBeatUnoffsetted.remove(countdownBeatHit);
		}

		luaCall('startSongPost', formatCustomSongName(header.title), header.difficulty);
		luaCall('postStartSong', formatCustomSongName(header.title), header.difficulty); // alternative syntax
	}

	function stopSong(header:Header) {
		luaCall('stopSong', formatCustomSongName(header.title), header.difficulty);

		Sys.println('Song activity is off');

		if (!RenderingMode.enabled) {
			Mixer.stopMusic();
		} else {
			RenderingMode.stopRender();
		}

		songEnded = true;
		songStarted = false;

		Mixer.setTime(0, null);

		luaCall('stopSongPost', formatCustomSongName(header.title), header.difficulty);
		luaCall('postStopSong', formatCustomSongName(header.title), header.difficulty); // alternative syntax

		// Editor mode returns to the main menu like gameplay does.
		Main.switchState(MAIN_MENU);
	}

	function gameOver(header:Header, lane:Int) {
		luaCall('gameOver', null);

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

		// The frontend (stage/actors) never exists in editor mode.
		if (field != null) {
			var char = field.actors[lane + field.numSpectators];
			if (char == null)
				char = field.actors[1 + field.numSpectators];

			field.actorOnGameOver = char;
		}

		// The death screen owns the frame from here: the note system
		// (notes + strumlines + receptors) and the ENTIRE HUD are torn
		// down, leaving only the stage, the death actors and the death
		// flow. DEFERRED one tick (Tools.forSync) because this callback
		// can fire from INSIDE NoteSystem's own update loop
		// (missNote → onDeath.dispatch) — disposing it right here would
		// yank the strumlines out from under the running loop. The
		// deferred dispose is still the same frame-ish (1ms), so the
		// player never sees a post-death note or HUD element.
		Tools.forSync(disposeNoteSystemAndHUD);

		luaCall('gameOverPost', null);
		luaCall('postGameOverPost', null); // alternative syntax

		deathCounter++;
	}

	/**
		Game-over teardown for the note system and the whole HUD. Also
		called from the death branch of update() — whichever runs first
		wins, the second call finds nulls and does nothing. Kept
		null-safe because it runs on a timer: the playfield may have
		been disposed (endGameOver → stateDestroy) in between.
	**/
	function disposeNoteSystemAndHUD() {
		if (disposed)
			return;

		if (noteSystem != null) {
			noteSystem.dispose();
			noteSystem = null;
		}

		if (hud != null) {
			hud.dispose();
			hud = null;
		}
	}

	var customSongName = "";

	// helper function made for playfield
	inline function formatCustomSongName(title:String) {
		return customSongName == "" ? title : customSongName;
	}

	var customStage = "";

	// helper function made for playfield
	inline function formatCustomStage(stage:String) {
		return customStage == "" ? stage : customStage;
	}

	inline function setCustomStage(stage:String) {
		luaCall('onChangeStage', stage);
	}

	// -------------------------------------------------------------------
	// Debug key (playfield-owned window listener)
	// -------------------------------------------------------------------

	var debugKeysActive:Bool = false;

	/**
		The debug key (controls.game.debug) toggles playfieldEditorMode:
		it flips the `editorModeNext` static and routes through
		Main.switchState(GAMEPLAY, true) — the state machine's dispose +
		recreate IS the song restart, rebuilding the playfield in the
		other mode (frontend-less editor subset, or the full gameplay
		stack).

		The listener is attached at the WINDOW level for the playfield's
		whole lifetime — gameplay AND editor mode, running AND paused —
		because InputSystem (gameplay) and PlayFieldEditorMode's handler
		(editor) are both detached while the pause menu is open. It is
		removed in dispose(), before any subsystem teardown.
	**/
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

	function debugKeyDown(code:lime.ui.KeyCode, mod:lime.ui.KeyModifier) {
		if (disposed)
			return;
		if (code != SaveData.state.controls.game.debug)
			return;

		toggleEditorMode();
	}

	/**
		The editor ⇄ gameplay toggle, shared by the debug key and the
		editor's exit popup: flips `editorModeNext`, syncs File's editor
		flag, then routes through the state machine's dispose + recreate
		cycle (which IS the song restart).
	**/
	function toggleEditorMode() {
		#if linc_luajit_funkinview
		// Gameplay → editor: let the script know it is about to lose
		// control until the toggle back. (Editor → gameplay fires nothing:
		// there is no lua in the editor.)
		if (!playfieldEditorMode) {
			luaCall('toggleEditorMode', formatCustomSongName(Chart.header.title), Chart.header.difficulty, Chart.header.artist);
		}
		#end

		PlayField.editorModeNext = !playfieldEditorMode;
		File.setEditorMode(editorModeNext);
		Sys.println('  [ Developer ] playfieldEditorMode ${editorModeNext ? "ON" : "OFF"} — restarting song.');

		// Same teardown the backwards-seek restart does: stop the music
		// and unhook input BEFORE the dispose + recreate cycle, so the
		// playfield is never disposed while its audio clock is still
		// running (which would leave the mixer state machine mid-flight
		// for the next Mixer.init/startMusic).
		if (!paused)
			pause(false);
		Tools.forSync(() -> {
			Main.switchState(GAMEPLAY, true);
		});
	}

	/**
		Disposes the playfield.
	**/
	function dispose() {
		ready = false;
		disposed = true;

		luaCall('dispose', null);

		// The playfield-owned debug-key window listener goes first —
		// nothing after this point may receive input.
		detachDebugKey();

		var conductor = Main.conductor;
		conductor.onMeasure.remove(measureHit);
		conductor.onStep.remove(stepHit);
		conductor.onBeat.remove(beatHit);

		// Editor-only subsystem first (it owns window events + programs).
		if (editorMode != null) {
			editorMode.dispose();
			editorMode = null;
		}

		if (frontend != null) {
			frontend.dispose();
			frontend = null;
		}

		if (inputSystem != null) {
			inputSystem.dispose();
			inputSystem = null;
		}

		if (noteSystem != null) {
			noteSystem.dispose();
			noteSystem = null;
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

		luaCall('disposePost', null);
		luaCall('postDispose', null); // alternative syntax
	}
}
