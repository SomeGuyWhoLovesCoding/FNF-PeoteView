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
class PlayField implements State {
	var roof(default, null):CustomDisplay;
	var display(default, null):CustomDisplay;
	var view(default, null):CustomDisplay;

	function new(path:String) {
		Chart.load(Paths.asset(path));
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
		/*if (field.gfConductor != null)
			field.gfConductor.changeBpmAt(time, value);*/
	}

	var ratingJudgementList:Array<Judgement> = [
		[
			0.3, // target
			0, // id
			1, // accuracy
			400 // score
		],
		[
			0.6,
			1,
			0.8,
			200
		],
		[
			0.85,
			2,
			0.675,
			100
		],
		[
			0.95,
			3,
			0.5,
			50
		]
	]; // how this new modifiable system works: you simply just set this array to a new selection of ratings, however you want.

	var score:Int128 = 0;
	var misses:Int128 = 0;
	var combo:Int128 = 0;
	var accuracy(default, null):Accuracy = new Accuracy();
	var health:Float = 0.5;
	var healthGain:Array<Float>;
	var healthLoss:Array<Float>;

	var latencyCompensation:Int;

	var dispShake:Point = {x: 0, y: 0};
	var viewShake:Point = {x: 0, y: 0};

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
			hud.render(Math.POSITIVE_INFINITY);
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

	var field(default, null):Field;
	var inputSystem(default, null):InputSystem;
	var noteSystem(default, null):NoteSystem;
	var hud(default, null):HUD;
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

	function setTime(value:Float, playAgain:Bool = false) {
		if (disposed || !songStarted || songEnded || paused || died) return;
		if (value > Mixer.length - 1000) value = Mixer.length - 1000;

		Mixer.setTime(Math.max(value, 0.0), this);
		if (hud != null && SaveData.state.preferences.ratingPopup) hud.hideRatingPopup();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(value);
			noteSystem.resetNotes(value);
			noteSystem.onSongPositionJump(pos);
		}
		if (field != null) field.resetCharacters();
	}

	var songPosition:Float;

	/**
	 * Creates the playfield.
	 * @param roof The top display you want the playfield's pause screen to go to.
	 * @param display The ui display you want the playfield's countdown display and hud to go to.
	 * @param mania The amount of keys you want for your fnf song. (This is configured by the song's header)
	 */
	function create(roof:CustomDisplay, display:CustomDisplay, mania:Int = 4) {
		if (mania > 16) mania = 16;

		healthLoss = [for (i in 0...64) 0.02];
		healthGain = [for (i in 0...64) 0.025];

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

		var pos = MetaNote.floatToMetaNotePosition(songPosition);

		field = new Field(this);

		inputSystem = new InputSystem(mania, this);

		NoteSystem.init();
		noteSystem = new NoteSystem(this);

		Mixer.init(Chart.header);

		HUD.init();
		if (!SaveData.state.preferences.hideHUD) hud = new HUD(display, this);

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
			hud.render(Math.POSITIVE_INFINITY);
			hud.updateBuffers();
		}
	}

	/**
		Updates the playfield.
	**/
	function update(deltaTime:Float) {
		if (disposed || paused) return;

		if (!ready) {
			ready = true;
			return;
		}

		display.update();
		view.update();

		display.shake(dispShake.x, dispShake.y);
		view.shake(viewShake.x, viewShake.y);

		var ratio = Math.max(Math.min((deltaTime * 0.01), 1), 0);
		if (display.fov != 1) display.fov = Tools.lerp(display.fov, 1, ratio);
		if (view.fov != 1) view.fov = Tools.lerp(view.fov, 1, ratio);

		if (!died) {
			Mixer.update(this, deltaTime);
			Sys.println(songPosition);

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

			if (field != null) field.update(deltaTime);
			if (countdownDisp != null) countdownDisp.update(deltaTime);

			#if !FV_LIME_FORK
			Main.conductor.time = songPosition;
			#end

			var pos = MetaNote.floatToMetaNotePosition(songPosition);

			if (noteSystem != null) {
				noteSystem.update(pos);

				var noteSpawner = noteSystem.noteSpawner;
				//if (HUD.scoreTxt != null) HUD.scoreTxt.text = ((noteSpawner.timeSpentOnIt * 1000000000) / Tools.int64ToFloat(noteSpawner.top - noteSpawner.bottom)) + "ns";
				//if (HUD.scoreTxt != null) HUD.scoreTxt.text = (noteSpawner.timeSpentOnIt * 1000) + "ms";
			}

			songPosition += latencyCompensation;
			songPosition += Mixer.latency();

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
		Pauses the playfield.
	**/
	function pause() {
		if (disposed || paused || died || RenderingMode.enabled) return;

		pauseScreen.open();
		if (songStarted) Mixer.stopMusic();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			noteSystem.onSongPositionJump(pos);
			noteSystem.resetStrumlines();
		}
		if (inputSystem != null) inputSystem.removeEvents();

		paused = true;

		Main.current.playScrollSound();
	}

	/**
		Resumes the playfield.
	**/
	function resume() {
		if (disposed || !paused || died) return;

		pauseScreen.close();
		if (!RenderingMode.enabled && songStarted && !songEnded) Mixer.startMusic();
		if (noteSystem != null) {
			var pos = MetaNote.floatToMetaNotePosition(songPosition);
			noteSystem.onSongPositionJump(pos);
		}
		if (inputSystem != null) haxe.Timer.delay(inputSystem.addEvents, 1);

		paused = false;
	}

	function countdownBeatHit(beat:Float) {
		if (beat == 0 && !songStarted) {
			onStartSong.dispatch(Chart.header);

			// When the game actually begins, remove countdown listener immediately
			// to avoid duplicate triggers and let Main.conductor take over.
			if (countdownDisp.conductor != null) countdownDisp.conductor.onBeatUnoffsetted.remove(countdownBeatHit);
			Main.conductor.onMeasure.add(measureHit);
		}

		if (beat < 0) {
			// Countdown visuals: maps beats -4..-1 to 3..0
			countdownDisp.countdownTick(Math.floor(4 + beat));
		}
	}

	inline function measureHit(measure:Float) {
		if (measure >= 0 && SaveData.state.preferences.cameraZooming && songStarted) {
			display.fov += 0.025;
			view.fov += 0.011;
		}
	}

	function hitNote(note:MetaNote, timing:Float, notesInOne:Int64) {
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
		/*if (handleJudgement(absTiming, ratingJudgementList[0], notesInOne, preferences))
			return;*/

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
				return;
			}
		}
	}

	function missNote(note:MetaNote, notesInOne:Int64) {
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
	}

	function completeSustain(note:MetaNote) {
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
	}

	inline function releaseSustain(note:MetaNote) {
		combo = 0;
	}

	function startSong(header:Header) {
		Sys.println('Song activity is on');

		if (!RenderingMode.enabled) {
			Mixer.startMusic();
		}

		songStarted = true;
		songEnded = false;

		// Remove countdown handler if still present (defensive)
		if (countdownDisp.conductor != null) countdownDisp.conductor.onBeat.remove(countdownBeatHit);
	}

	function stopSong(header:Header) {
		Sys.println('Song activity is off');

		if (!RenderingMode.enabled) {
			Mixer.stopMusic();
		} else {
			RenderingMode.stopRender();
		}

		songEnded = true;
		songStarted = false;

		Mixer.setTime(0, null);

		Main.switchState(MAIN_MENU);
	}

	function gameOver(header:Header, lane:Int) {
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

		Mixer.stopMusic();

		Mixer.setTime(0, null);

		var char = field.actors[lane + field.numSpectators];
		if (char == null) char = field.actors[1 + field.numSpectators];

		field.actorOnGameOver = char;
	}

	/**
		Disposes the playfield.
	**/
	function dispose() {
		ready = false;
		disposed = true;

		var conductor = Main.conductor;
		conductor.onMeasure.remove(measureHit);

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

		if (display.fov != 1) display.fov = 1;
		if (view.fov != 1) view.fov = 1;
	}
}