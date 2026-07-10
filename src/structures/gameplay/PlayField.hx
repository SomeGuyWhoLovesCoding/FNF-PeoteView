package structures.gameplay;

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
	var roof(default, null):CustomDisplay;
	var display(default, null):CustomDisplay;
	var view(default, null):CustomDisplay;

	// lua
	var funkinviewlua(default, null):FunkinViewLua;

	private var chartPath(default, null):String; // made this a variable due to complications with lua scripting. not a bug complication, but just an intentional design quirk.

	function new(path:String) {
		chartPath = Paths.asset(path);

		Chart.load(chartPath);
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.roof = roof;
		this.display = display;
		this.view = view;

		#if linc_luajit_funkinview
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
			1.0-0.67, // target
			0, // id
			1, // accuracy
			400 // score
		],
		[
			1.0-0.34,
			1,
			0.8,
			200
		],
		[
			1.0,
			2,
			0.675,
			100
		],
		[
			Math.POSITIVE_INFINITY,
			3,
			0.5,
			50
		]
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

	var dispShake:Point = {x: 0, y: 0};
	var viewShake:Point = {x: 0, y: 0};

	// For Screen Shake event
	var additiveDispShake:Point = {x: 0, y: 0, isSmooth: true};
	var additiveViewShake:Point = {x: 0, y: 0, isSmooth: true};

	var scrollSpeed(default, set):Float = 1.0;
	function set_scrollSpeed(value:Float) {
		if (noteSystem != null) noteSystem.setScrollSpeed(scrollSpeed = value);
		return value;
	}

	var downScroll(default, set):Bool;
	function set_downScroll(value:Bool) {
		downScroll = value;
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			noteSystem.resetStrumlines(false);
			noteSystem.update(pos);
			noteSystem.renderNotes(pos); // new, because of the change I did to the note system to allow for an easy greedy merging optimization
		}
		if (hud != null) {
			hud.render();
			hud.update(Math.POSITIVE_INFINITY);
			hud.updateBuffers();
		}
		return value;
	}

	var practiceMode:Bool;
	var songStarted(default, null):Bool;
	var songEnded(default, null):Bool;
	var disposed(default, null):Bool;
	var paused(default, null):Bool;
	var died(default, null):Bool;
	var botplay(default, set):Bool;
	function set_botplay(value:Bool) {
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
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
		if (mania > 256) mania = 256;
		if (mania < 1) mania = 1;

		/*#if linc_luajit_funkinview
		funkinviewlua.callFunction('postManiaChange', value);
		#end*/

		return mania = value;
	}

	var field(default, null):Field;
	var hud(default, null):HUD;

	var inputSystem(default, null):InputSystem;
	var noteSystem(default, null):NoteSystem;
	var eventSystem(default, null):EventSystem;

	var countdownDisp(default, null):CountdownDisplay;
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
		if (disposed || !songStarted || songEnded || paused || died) return;
		if (value > Mixer.length - 1000) value = Mixer.length - 1000;

		if (value < songPosition) {
			onRestartingForBackwardTimeSetting = true;
			timeForRestartingBackwardTime = value;

			if (eventSystem != null) eventSystem.clearEventTimers(); // immediately clear out any event timers to prevent them flooding the rest of the song through
			
			#if linc_luajit_funkinview
			funkinviewlua.callFunction('preTimeChange', timeForRestartingBackwardTime, Chart.header);
			#end
			pause(false);
			Tools.forSync(() -> {
				Main.switchState(GAMEPLAY, true);
			});
			return;
		}

		Mixer.setTime(Math.max(value, 0.0), this);
		if (hud != null && SaveData.state.preferences.ratingPopup) hud.hideRatingPopup();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(value);
			noteSystem.onSongPositionJump(pos, pushToOffset);
		}
		if (field != null) field.resetCharacters();
	}

	var songPosition:Float;

	/**
	 * Creates the playfield.
	 * @param roof The top display you want the playfield's pause screen to go to.
	 * @param display The ui display you want the playfield's countdown display and hud to go to.
	 * @param initialMania The amount of keys you want for your fnf song. (up to 256 supported) (This is configured by the song's header)
	 */
	function create(roof:CustomDisplay, display:CustomDisplay, initialMania:Int = 4) {
		AsyncInput.init();

		mania = initialMania;

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
		conductor.offset = latencyCompensation - Mixer.latency();
		songPosition = (-conductor.crochet * 4.5) - conductor.offset;

		field = new Field(this);

		HUD.init();
		if (!SaveData.state.preferences.hideHUD) hud = new HUD(display, this);

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

		#if linc_luajit_funkinview
		startedCountdown = !onRestartingForBackwardTimeSetting || funkinviewlua.callFunction('startCountdown', formatCustomSongName(Chart.header.title), Chart.header.difficulty)[0] != FunkinViewLua.Function_Stop;
		funkinviewlua.callFunction('createPost', null);
		#end

		if (onRestartingForBackwardTimeSetting) {
			onRestartingForBackwardTimeSetting = false;
			startSong(Chart.header);
			setTime(timeForRestartingBackwardTime);
			
			#if linc_luajit_funkinview
			funkinviewlua.callFunction('postTimeChange', timeForRestartingBackwardTime, Chart.header);
			#end

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

		//rawJsonParent.events.sort((a, b) -> a.evTime > b.evTime);

		var rawJson:Array<EventSystem.RawEventObject> = rawJsonParent.events;

		for (event in rawJson) {
			e.parsedObjects.push(new EventSystem.EventObject(
				event.evName,
				event.value1,
				event.value2 != null ? event.value2 : "",
				event.evTime
			));
			//trace(event.evName,event.value1,event.value2,event.evTime);
		}

		e.init();

		return true;
	}

	/**
		Updates the playfield.
	**/
	var eventTimers:Array<EventTimer> = [];
	function update(deltaTime:Float) {
		if (disposed || paused) return;

		#if linc_luajit_funkinview
		funkinviewlua.updateVariablesList();
		funkinviewlua.callFunction('update', deltaTime);
		#end

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

		if (field != null) field.update(deltaTime);

		var ratio = Math.max(Math.min((deltaTime * 0.01), 1), 0);
		if (display.fov != 1) display.fov = Tools.lerp(display.fov, 1, ratio);
		if (view.fov != 1) view.fov = Tools.lerp(view.fov, 1, ratio);

		if (countdownDisp != null) countdownDisp.update(deltaTime);

		if (eventSystem != null && !died) {
			eventSystem.update(deltaTime, songPosition);
		}

		display.shake(dispShake.x + additiveDispShake.x, dispShake.y + additiveDispShake.y);
		if (field != null) field.updateCamera(deltaTime);

		if (!died) {
			if (startedCountdown) {
				Mixer.update(this, deltaTime);

				#if !FV_LIME_FORK
				// If the song hasn't started yet, update the countdown conductor only.
				// Do NOT apply latency compensation here — countdownDisp.conductor must see a pure musical timeline.
				if (!songStarted && !songEnded) {
					// Mixer already advanced playfield.songPosition during pre-start,
					// so simply push that time to the countdown conductor.
					if (countdownDisp != null && countdownDisp.conductor != null) {
						countdownDisp.conductor.time = songPosition;
					}
				}
				#end

				songPosition -= latencyCompensation;
				songPosition -= Mixer.latency();
			}

			var renderingModeEnabled = RenderingMode.enabled;
			if (hud != null) hud.update(renderingModeEnabled ? (1000 / RenderingMode.frameRate) : deltaTime);

			#if !FV_LIME_FORK
			Main.conductor.time = songPosition;
			#end

			var pos = MetaNote.floatToMetaNotePosition(songPosition);

			if (noteSystem != null) {
				noteSystem.update(pos);
			}

			if (startedCountdown) {
				songPosition += latencyCompensation;
				songPosition += Mixer.latency();
			}

			#if linc_luajit_funkinview
			funkinviewlua.callFunction('updatePost', deltaTime);
			funkinviewlua.callFunction('postUpdate', deltaTime); // alternative syntax
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
	function render() {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('render', null);
		#end

		var renderingModeEnabled = RenderingMode.enabled;
		if (renderingModeEnabled) update(1000 / RenderingMode.frameRate);
		var noteSystem = noteSystem;
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
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
			//if (scoreTxt != null) scoreTxt.text = ((noteSpawner.timeSpentOnIt * 1000000000) / Tools.int64ToFloat(noteSpawner.top - noteSpawner.bottom)) + "ns";
			//if (scoreTxt != null) scoreTxt.text = (noteSpawner.timeSpentOnIt * 1000) + "ms";

			hud.updateBuffers();
		}

		if (renderingModeEnabled) RenderingMode.pipeFrame();

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('renderPost', null);
		funkinviewlua.callFunction('postRender', null); // alternative syntax
		#end
	}

	/**
		Pauses the playfield.
	**/
	function pause(showpausescreen:Bool = true) {
		if (disposed || paused || died || RenderingMode.enabled) return;

		#if linc_luajit_funkinview
		if (funkinviewlua.callFunction('pause', null)[0] == FunkinViewLua.Function_Stop) return;
		#end

		if (showpausescreen) pauseScreen.open();
		if (songStarted) Mixer.stopMusic();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			noteSystem.resetStrumlines();
		}
		if (inputSystem != null) inputSystem.removeEvents();

		paused = true;

		if (showpausescreen) Main.current.playScrollSound();

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('pausePost', null);
		funkinviewlua.callFunction('postPause', null); // alternative syntax
		#end
	}

	/**
		Resumes the playfield.
	**/
	function resume() {
		if (disposed || !paused || died) return;

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('resume', null);
		#end

		pauseScreen.close();
		if (!RenderingMode.enabled && songStarted && !songEnded) Mixer.startMusic();
		if (inputSystem != null) haxe.Timer.delay(inputSystem.addEvents, 1);

		paused = false;

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('resumePost', null);
		funkinviewlua.callFunction('postResume', null); // alternative syntax
		#end
	}

	function countdownBeatHit(beat:Float) {
		if (beat == 0 && !songStarted) {
			onStartSong.dispatch(Chart.header);

			// When the game actually begins, remove countdown listener immediately
			// to avoid duplicate triggers and let Main.conductor take over.
			if (countdownDisp.conductor != null) countdownDisp.conductor.onBeatUnoffsetted.remove(countdownBeatHit);
			Main.conductor.onStep.add(stepHit);
			Main.conductor.onBeat.add(beatHit);
			Main.conductor.onMeasure.add(measureHit);
		}

		if (beat < 0) {
			// Countdown visuals: maps beats -4..-1 to 3..0
			countdownDisp.countdownTick(Math.floor(4 + beat));
		}
	}

	function stepHit(step:Float) {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('stepHit', step);
		#end
	}

	function beatHit(beat:Float) {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('beatHit', beat);
		#end
	}

	function measureHit(measure:Float) {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('measureHit', measure);
		#end

		if (measure >= 0 && SaveData.state.preferences.cameraZooming && songStarted) {
			display.fov += 0.025;
			view.fov += 0.011;
		}
	}

	function hitNote(note:MetaNote, timing:Float, notesInOne:Int64, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		if (funkinviewlua.callFunction('hitNote', notePos, note.index, note.duration, note.type, timing, notesInOne)[0] == FunkinViewLua.Function_Stop) {
			return;
		};
		#end

		var lane = note.type;

		if (noteSystem.noteTypeFunctionalityPre[note.type] != null) lane = 1;

		var index = 1 + lane;
		if (Chart.header.voicesDirs.length > 1) index = 1;
		if (index > 0 && index <= Mixer.trackCount) Mixer.changeTrackVolume(index, 1);

		var playable = inputSystem.strumlinePlayable[lane];

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
		//static var ratingList = [];

		// determine rating list based on 0%..100%

		// Handle edge cases first
		// If timing is worse than the worst threshold, return worst rating
		if (absTiming >= ratingJudgementList[ratingJudgementList.length - 1][0]) {
			var worstJudgement = ratingJudgementList[ratingJudgementList.length - 1];
			var judgementID = Std.int(worstJudgement[1]);
			var judgementAcc = haxe.Int64Helper.fromFloat(worstJudgement[2] * 10000);
			var judgementScore = Std.int(worstJudgement[3]);
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(judgementID);
			accuracy.increment(judgementAcc, false, notesInOne * 10000);
			score += judgementScore * notesInOne;
			postHitNote(#if linc_luajit_funkinview notePos, #end note, timing, notesInOne);
			return;
		}

		// Check from best to worst thresholds
		for (i in 0...ratingJudgementList.length) {
			if (absTiming < ratingJudgementList[i][0]) {
				var judgement = ratingJudgementList[i];
				var judgementID = Std.int(judgement[1]);
				var judgementAcc = haxe.Int64Helper.fromFloat(judgement[2] * 10000);
				var judgementScore = Std.int(judgement[3]);
				if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(judgementID);
				accuracy.increment(judgementAcc, false, notesInOne * 10000);
				score += judgementScore * notesInOne;
				postHitNote(#if linc_luajit_funkinview notePos, #end note, timing, notesInOne);
				return;
			}
		}
	}

	function postHitNote(#if linc_luajit_funkinview notePos:Float, #end note:MetaNote, timing:Float, notesInOne:Int64) {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('hitNotePost', notePos, note.index, note.duration, note.type, timing, notesInOne);
		funkinviewlua.callFunction('postHitNote', notePos, note.index, note.duration, note.type, timing, notesInOne); // alternative syntax
		#end
	}

	function missNote(note:MetaNote, notesInOne:Int64, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		if (funkinviewlua.callFunction('missNote', notePos, note.index, note.duration, note.type, notesInOne)[0] == FunkinViewLua.Function_Stop) {
			return;
		};
		#end

		if (practiceMode && health < 0.05) {
			health = 0.05;
		}

		var lane = note.type;
		if (noteSystem.noteTypeFunctionalityPre[note.type] != null) lane = 1;

		var index = 1 + lane;
		if (Chart.header.voicesDirs.length > 1) index = 1;
		if (index > 0 && index <= Mixer.trackCount) Mixer.changeTrackVolume(index, 0);

		health -= healthLoss[lane] * Tools.int64ToFloat(notesInOne);

		combo = 0;
		score -= 50 * notesInOne;
		misses += notesInOne;
		accuracy.increment(10000, true, notesInOne * 10000);

		if (health < 0 && !disposed)
			onDeath.dispatch(Chart.header, lane);

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('missNotePost', notePos, note.index, note.duration, note.type, notesInOne);
		funkinviewlua.callFunction('postMissNote', notePos, note.index, note.duration, note.type, notesInOne); // alternative syntax
		#end
	}

	function completeSustain(note:MetaNote, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		funkinviewlua.callFunction('completeSustain', notePos, note.index, note.duration, note.type);
		#end

		var lane = note.type;
		if (noteSystem.noteTypeFunctionalityPre[note.type] != null) lane = 1;

		if (noteSystem != null && noteSystem.strumlines[lane].confirmed(note.index)) return;

		var playable = inputSystem.strumlinePlayable[lane];

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
		funkinviewlua.callFunction('completeSustainPost', notePos, note.index, note.duration, note.type);
		funkinviewlua.callFunction('postCompleteSustain', notePos, note.index, note.duration, note.type); // alternative syntax
		#end
	}

	inline function releaseSustain(note:MetaNote, _i:Int64) {
		#if linc_luajit_funkinview
		var notePos = MetaNote.metaNotePositionToSongTime(note.position);
		funkinviewlua.callFunction('releaseSustain', notePos, note.index, note.duration, note.type);
		#end

		combo = 0;

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('releaseSustainPost', notePos, note.index, note.duration, note.type);
		funkinviewlua.callFunction('postReleaseSustain', notePos, note.index, note.duration, note.type); // alternative syntax
		#end
	}

	var songStartTime:Float = 0.0; // Hardware timestamp when the song actually started

	function startSong(header:Header) {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('startSong', formatCustomSongName(header.title), header.difficulty);
		#end

		Sys.println('Song activity is on');

		if (!RenderingMode.enabled) {
			Mixer.startMusic();
			var attempts = 0;
			while (MiniAudio.getPlaybackPosition() <= 0 && attempts++ < 500) {}
			songPosition = MiniAudio.getPlaybackPosition() + latencyCompensation + Mixer.latency();
		}

		songStarted = true;
		songEnded = false;

		if (countdownDisp != null) {
			if (countdownDisp.conductor != null) 
				countdownDisp.conductor.onBeatUnoffsetted.remove(countdownBeatHit);
		}

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('startSongPost', formatCustomSongName(header.title), header.difficulty);
		funkinviewlua.callFunction('postStartSong', formatCustomSongName(header.title), header.difficulty); // alternative syntax
		#end
	}

	function stopSong(header:Header) {
		#if linc_luajit_funkinview
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
		funkinviewlua.callFunction('stopSongPost', formatCustomSongName(header.title), header.difficulty);
		funkinviewlua.callFunction('postStopSong', formatCustomSongName(header.title), header.difficulty); // alternative syntax
		#end

		Main.switchState(MAIN_MENU);
	}

	function gameOver(header:Header, lane:Int) {
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('gameOver', null);
		#end

		inputSystem.removeEvents();
		haxe.Timer.delay(inputSystem.addEvents, 2000); // prevent instant end gameover

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

		var char = field.actors[lane + field.numSpectators];
		if (char == null) char = field.actors[1 + field.numSpectators];

		field.actorOnGameOver = char;

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('gameOverPost', null);
		funkinviewlua.callFunction('postGameOverPost', null); // alternative syntax
		#end

		deathCounter++;
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
		#if linc_luajit_funkinview
		funkinviewlua.callFunction('onChangeStage', stage);
		#end
	}

	/**
		Disposes the playfield.
	**/
	function dispose() {
		AsyncInput.shutdown();

		ready = false;
		disposed = true;

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('dispose', null);
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

		if (display.fov != 1) { display.fov = 1; display.x = 0; display.y = 0; display.r = 0; }
		if (view.fov != 1) { view.fov = 1; view.x = 0; view.y = 0; view.r = 0; }

		#if linc_luajit_funkinview
		funkinviewlua.callFunction('disposePost', null);
		funkinviewlua.callFunction('postDispose', null); // alternative syntax
		funkinviewlua.dispose();
		#end
	}
}