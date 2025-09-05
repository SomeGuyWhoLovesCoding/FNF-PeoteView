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
		Chart.load(path);
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.roof = roof;
		this.display = display;
		this.view = view;

		create(roof, display, Chart.header.mania);
		if (RenderingMode.enabled) RenderingMode.initRender();
	}

	var score:Int128 = 0;
	var misses:Int128 = 0;
	var combo:Int128 = 0;
	var sickScore:Int128 = 400;
	var goodScore:Int128 = 200;
	var badScore:Int128 = 100;
	var shitScore:Int128 = 50;
	var accuracy(default, null):Accuracy = new Accuracy();
	var health:Float = 0.5;
	var healthGain:Array<Float>;
	var healthLoss:Array<Float>;
	var latencyCompensation:Int;

	var dispShake:Point = {x: 0, y: 0};
	var viewShake:Point = {x: 0, y: 0};

	var scrollSpeed(default, set):Float = 1.0;
	function set_scrollSpeed(value:Float) {
		return noteSystem.setScrollSpeed(scrollSpeed = value);
	}

	var downScroll(default, set):Bool;
	function set_downScroll(value:Bool) {
		downScroll = value;
		if (noteSystem != null) {
			var pos = Tools.betterInt64FromFloat(songPosition * 100);
			noteSystem.resetStrumlines(false);
			noteSystem.update(pos);
		}
		if (hud != null) {
			hud.update(0.0);
			hud.updateScoreText(0.0);
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
			var pos = Tools.betterInt64FromFloat(songPosition * 100);
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
	var onNoteHit:Event<MetaNote->Int->Float->Void>;
	var onNoteMiss:Event<MetaNote->Float->Void>;
	var onSustainComplete:Event<MetaNote->Void>;
	var onSustainRelease:Event<MetaNote->Void>;
	var onKeyPress:Event<KeyCode->Void>;
	var onKeyRelease:Event<KeyCode->Void>;

	var flipHealthBar:Bool;
	var hitbox:Float = 200;
	var ready:Bool = false;

	function setTime(value:Float, playAgain:Bool = false) {
		if (disposed || !songStarted || songEnded || paused || died) return;
		if (value > Mixer.length - 1000) value = Mixer.length - 1000;

		Mixer.setTime(Math.max(value, 0.0), this);
		if (hud != null && SaveData.state.preferences.ratingPopup) hud.hideRatingPopup();
		if (noteSystem != null) noteSystem.resetNotes(songPosition);
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

		onNoteHit = new Event<MetaNote->Int->Float->Void>();
		onNoteMiss = new Event<MetaNote->Float->Void>();
		onSustainComplete = new Event<MetaNote->Void>();
		onSustainRelease = new Event<MetaNote->Void>();
		onKeyPress = new Event<KeyCode->Void>();
		onKeyRelease = new Event<KeyCode->Void>();

		var conductor = Main.conductor;
		var timeSig = Chart.header.timeSig;
		conductor.changeBpmAt(0, Chart.header.bpm, timeSig[0], timeSig[1]);
		conductor.onBeat.add(beatHit);
		conductor.onMeasure.add(measureHit);

		onNoteHit.add(hitNote);
		onNoteMiss.add(missNote);
		onSustainComplete.add(completeSustain);
		onSustainRelease.add(releaseSustain);
		onStartSong.add(startSong);
		onStopSong.add(stopSong);
		onDeath.add(gameOver);

		songPosition = -conductor.crochet * 4.5;

		field = new Field(this);
		inputSystem = new InputSystem(mania, this);
		NoteSystem.init();
		noteSystem = new NoteSystem(this);
		Mixer.init(Chart.header);
		HUD.init();
		if (!SaveData.state.preferences.hideHUD) hud = new HUD(display, this);
		CountdownDisplay.init(roof);
		CountdownDisplay.setupSounds();
		countdownDisp = new CountdownDisplay();
		PauseScreen.init(roof);
		pauseScreen = new PauseScreen(Chart.header.difficulty);

		scrollSpeed = Chart.header.speed;
	}

	/**
		Reests the playfield's HUD.
	**/
	function resetHUD() {
		if (hud != null) {
			hud.dispose();
			hud = null;
		}

		if (!SaveData.state.preferences.hideHUD) {
			hud = new HUD(display, this);
			hud.alphaLerp = 1;
			hud.setHUDAlpha(1);
			hud.update(Math.POSITIVE_INFINITY);
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

		if (RenderingMode.enabled) {
			deltaTime = 1000 / 60;
		}

		display.update();
		view.update();

		var ratio = Math.max(Math.min((deltaTime * 0.01), 1), 0);
		if (display.fov != 1) display.fov = Tools.lerp(display.fov, 1, ratio);
		if (view.fov != 1) view.fov = Tools.lerp(view.fov, 1, ratio);

		if (!died) {
			Mixer.update(this, deltaTime);
			songPosition += latencyCompensation;
			Main.conductor.time = songPosition;

			var pos = Tools.betterInt64FromFloat(songPosition * 100);

			if (hud != null) hud.update(deltaTime);
			if (noteSystem != null) noteSystem.update(pos);
		} else {
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

		if (field != null) field.update(deltaTime);
		if (countdownDisp != null) countdownDisp.update(deltaTime);

		display.shake(dispShake.x, dispShake.y);
		view.shake(viewShake.x, viewShake.y);

		songPosition -= latencyCompensation;

		if (RenderingMode.enabled && !songEnded) {
			RenderingMode.pipeFrame();
		}
	}

	/**
		Pauses the playfield.
	**/
	function pause() {
		if (disposed || paused || died) return;

		pauseScreen.open();
		if (!RenderingMode.enabled && songStarted) Mixer.stopMusic();
		if (noteSystem != null) noteSystem.resetPlayerStrumlines();
		if (inputSystem != null) inputSystem.removeEvents();

		paused = true;
	}

	/**
		Resumes the playfield.
	**/
	function resume() {
		if (disposed || !paused || died) return;

		pauseScreen.close();
		if (!RenderingMode.enabled && songStarted && !songEnded) Mixer.startMusic();
		if (noteSystem != null) noteSystem.resetPlayerStrumlines();
		if (inputSystem != null) haxe.Timer.delay(inputSystem.addEvents, 1);

		paused = false;
	}

	inline function beatHit(beat:Float) {
		if (beat == 0 && !songStarted) onStartSong.dispatch(Chart.header);
		if (beat < 0) countdownDisp.countdownTick(Math.floor(4 + beat));
	}

	inline function measureHit(measure:Float) {
		if (measure >= 0 && SaveData.state.preferences.cameraZooming) {
			display.fov += 0.03;
			view.fov += 0.015;
		}
	}

	function hitNote(note:MetaNote, timing:Int, notesInOne:Float) {
		var index = 1 + note.lane;
		if (index > 0 && index <= Mixer.trackCount) Mixer.changeTrackVolume(index, 1);

		if (!inputSystem.strumlinePlayable[note.lane]) {
			health -= healthLoss[note.lane];
			if (health < 0.05) {
				health = 0.05;
			}
			return;
		}

		combo += Tools.betterInt64FromFloat(notesInOne);

		health += healthGain[note.lane];
		if (health > 1) {
			health = 1;
		}

		var preferences = SaveData.state.preferences;
		var scoreTxt = HUD.scoreTxt;

		if (scoreTxt != null && preferences.scoreTxtBopping) {
			scoreTxt.scale = 1.1;
		}

		var absTiming = Math.abs(timing);
		var notesInOneI64 = Tools.betterInt64FromFloat(notesInOne);

		if (absTiming > 60) {
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(3);
			accuracy.increment(0.5, false, notesInOne);
			score += shitScore * notesInOneI64;
			return;
		}

		if (absTiming > 45) {
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(2);
			accuracy.increment(0.75, false, notesInOne);
			score += badScore * notesInOneI64;
			return;
		}

		if (absTiming > 30) {
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(1);
			accuracy.increment(0.8, false, notesInOne);
			score += goodScore * notesInOneI64;
			return;
		}

		if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(0);
		accuracy.increment(1, false, notesInOne);
		score += sickScore * notesInOneI64;
	}

	function missNote(note:MetaNote, notesInOne:Float) {
		var index = 1 + note.lane;
		if (index > 0 && index <= Mixer.trackCount) Mixer.changeTrackVolume(index, 0);

		health -= healthLoss[note.lane];

		combo = 0;
		score -= 50 * Tools.betterInt64FromFloat(notesInOne);
		misses += Tools.betterInt64FromFloat(notesInOne);
		accuracy.increment(1.0, true, notesInOne);

		if (health < 0 && !disposed) {
			onDeath.dispatch(Chart.header, note.lane);
			return;
		}

		if (practiceMode && health < 0.05) {
			health = 0.05;
		}
	}

	function completeSustain(note:MetaNote) {
		if (noteSystem != null && noteSystem.strumlines[note.lane].confirmed(note.index)) return;

		if (!inputSystem.strumlinePlayable[note.lane]) {
			health -= healthLoss[note.lane];

			if (health < 0.05) {
				health = 0.05;
			}

			return;
		}

		health += healthGain[note.lane];

		if (health > 1) {
			health = 1;
		}
	}

	function releaseSustain(note:MetaNote) {
		combo = 0;
	}

	function startSong(header:Header) {
		Sys.println('Song activity is on');

		if (!RenderingMode.enabled) {
			Mixer.startMusic();
		}

		songStarted = true;
		songEnded = false;
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
		onDeath.remove(gameOver);

		died = true;
		songEnded = true;
		songPosition = 0;

		Sys.println("Game Over");

		if (RenderingMode.enabled) {
			RenderingMode.stopRender();
		}

		onNoteHit.remove(hitNote);
		onNoteMiss.remove(missNote);
		onSustainComplete.remove(completeSustain);
		onSustainRelease.remove(releaseSustain);

		var conductor = Main.conductor;
		conductor.onBeat.remove(beatHit);
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
		conductor.onBeat.remove(beatHit);
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

		onNoteHit.remove(hitNote);
		onNoteMiss.remove(missNote);
		onSustainComplete.remove(completeSustain);
		onSustainRelease.remove(releaseSustain);
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