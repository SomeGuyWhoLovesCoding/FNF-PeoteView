package structures.gameplay;

import lime.ui.KeyCode;
import lime.app.Event;

/**
	The home of the gameplay state.
**/
@:publicFields
class PlayField implements State {
	var roof(default, null):CustomDisplay;
	var display(default, null):CustomDisplay;
	var view(default, null):CustomDisplay;

	function new(songName:String) {
		chart = new Chart('assets/songs/$songName');
	}

	function init(roof:CustomDisplay, display:CustomDisplay, view:CustomDisplay) {
		this.roof = roof;
		this.display = display;
		this.view = view;

		create(roof, display, chart.header.mania);
		if (RenderingMode.enabled) RenderingMode.initRender(this);
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
	var healthGain:Vector<Float>;
	var healthLoss:Vector<Float>;
	var latencyCompensation:Int;

	var dispShake:Point = {x: 1, y: 0};
	var viewShake:Point = {x: 1, y: 0};

	var scrollSpeed(default, set):Float = 1.0;
	inline function set_scrollSpeed(value:Float) {
		return noteSystem.setScrollSpeed(scrollSpeed = value);
	}

	var downScroll(default, set):Bool;
	inline function set_downScroll(value:Bool) {
		downScroll = value;
		if (noteSystem != null) {
			var pos = Tools.betterInt64FromFloat(songPosition * 100);
			noteSystem.resetStrumlines(false);
			noteSystem.update(pos);
		}
		if (hud != null) {
			hud.updateHealthBar();
			hud.updateHealthIcons();
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
	inline function set_botplay(value:Bool) {
		if (noteSystem != null) {
			noteSystem.resetStrumlines();
			noteSystem.update(0);
		}
		return botplay = value;
	}

	var field(default, null):Field;
	var inputSystem(default, null):InputSystem;
	var noteSystem(default, null):NoteSystem;
	var audioSystem(default, null):AudioSystem;
	var hud(default, null):HUD;
	var countdownDisp(default, null):CountdownDisplay;
	var pauseScreen(default, null):PauseScreen;

	var onStartSong:Event<Chart->Void>;
	var onPauseSong:Event<Chart->Void>;
	var onResumeSong:Event<Chart->Void>;
	var onStopSong:Event<Chart->Void>;
	var onDeath:Event<Chart->Int->Void>;
	var onNoteHit:Event<MetaNote->Int->Void>;
	var onNoteMiss:Event<MetaNote->Void>;
	var onSustainComplete:Event<MetaNote->Void>;
	var onSustainRelease:Event<MetaNote->Void>;
	var onKeyPress:Event<KeyCode->Void>;
	var onKeyRelease:Event<KeyCode->Void>;

	var flipHealthBar:Bool;
	var hitbox:Float = 200;
	var ready:Bool = false;

	function setTime(value:Float, playAgain:Bool = false) {
		if (disposed || !songStarted || songEnded || paused || died) return;

		songPosition = Math.max(value, 0.0);
		if (audioSystem != null) audioSystem.setTime(songPosition);
		if (hud != null && SaveData.state.preferences.ratingPopup) hud.hideRatingPopup();
		if (noteSystem != null) noteSystem.resetNotes(songPosition);
		if (field != null) field.resetCharacters();
	}

	var songPosition:Float;
	var chart:Chart;

	/**
	 * Creates the playfield.
	 * @param roof The top display you want the playfield's pause screen to go to.
	 * @param display The ui display you want the playfield's countdown display and hud to go to.
	 * @param mania The amount of keys you want for your fnf song. (This is configured by the song's header)
	 */
	function create(roof:CustomDisplay, display:CustomDisplay, mania:Int = 4) {
		if (mania > 16) mania = 16;

		healthLoss = new Vector<Float>(64, 0.02);
		healthGain = new Vector<Float>(64, 0.025);

		onStartSong = new Event<Chart->Void>();
		onPauseSong = new Event<Chart->Void>();
		onResumeSong = new Event<Chart->Void>();
		onStopSong = new Event<Chart->Void>();
		onDeath = new Event<Chart->Int->Void>();

		onNoteHit = new Event<MetaNote->Int->Void>();
		onNoteMiss = new Event<MetaNote->Void>();
		onSustainComplete = new Event<MetaNote->Void>();
		onSustainRelease = new Event<MetaNote->Void>();
		onKeyPress = new Event<KeyCode->Void>();
		onKeyRelease = new Event<KeyCode->Void>();

		var conductor = Main.conductor;
		var timeSig = chart.header.timeSig;
		conductor.changeBpmAt(0, chart.header.bpm, timeSig[0], timeSig[1]);
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
		audioSystem = new AudioSystem(chart);
		HUD.init(display);
		if (!SaveData.state.preferences.hideHUD) hud = new HUD(display, this);
		CountdownDisplay.setupSounds();
		countdownDisp = new CountdownDisplay(HUD.uiBuf);
		PauseScreen.init(roof);
		pauseScreen = new PauseScreen(chart.header.difficulty);

		scrollSpeed = chart.header.speed;
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

		var ratio = (deltaTime * 0.01);
		if (display.fov != 1) display.fov -= (display.fov - 1) * ratio;
		if (view.fov != 1) view.fov -= (view.fov - 1) * ratio;

		if (!died) {
			if (audioSystem != null) audioSystem.update(this, deltaTime);
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
		if (!RenderingMode.enabled && songStarted && audioSystem != null) audioSystem.stop();
		if (noteSystem != null) noteSystem.resetStrumlines();
		if (inputSystem != null) inputSystem.removeEvents();

		paused = true;
	}

	/**
		Resumes the playfield.
	**/
	function resume() {
		if (disposed || !paused || died) return;

		pauseScreen.close();
		if (!RenderingMode.enabled && songStarted && !songEnded && audioSystem != null) audioSystem.play();
		if (noteSystem != null) noteSystem.resetStrumlines();
		if (inputSystem != null) haxe.Timer.delay(inputSystem.addEvents, 1);

		paused = false;
	}

	inline function beatHit(beat:Float) {
		if (beat == 0 && !songStarted) onStartSong.dispatch(chart);
		if (beat < 0) countdownDisp.countdownTick(Math.floor(4 + beat));
	}

	inline function measureHit(measure:Float) {
		if (measure >= 0 && SaveData.state.preferences.cameraZooming) {
			display.fov += 0.03;
			view.fov += 0.015;
		}
	}

	function hitNote(note:MetaNote, timing:Int) {
		if (audioSystem != null) {
			var voicesTrack = audioSystem.voices[note.lane];
			if (voicesTrack == null) voicesTrack = audioSystem.voices[0];
			if (voicesTrack != null) {
				voicesTrack.volume = 1;
			}
		}

		if (!inputSystem.strumlinePlayable[note.lane]) {
			health -= healthLoss[note.lane];
			if (health < 0.05) {
				health = 0.05;
			}
			return;
		}

		++combo;

		health += healthGain[note.lane];
		if (health > 1) {
			health = 1;
		}

		var preferences = SaveData.state.preferences;

		if (hud != null && preferences.scoreTxtBopping) {
			hud.scoreTxt.scale = 1.1;
		}

		var absTiming = Math.abs(timing);

		if (absTiming > 60) {
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(3);
			accuracy.increment(0.5);
			score += shitScore;
			return;
		}

		if (absTiming > 45) {
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(2);
			accuracy.increment(0.75);
			score += badScore;
			return;
		}

		if (absTiming > 30) {
			if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(1);
			accuracy.increment(0.8);
			score += goodScore;
			return;
		}

		if (hud != null && preferences.ratingPopup) hud.respondWithRatingID(0);
		accuracy.increment();
		score += sickScore;
	}

	function missNote(note:MetaNote) {
		if (audioSystem != null) {
			var voicesTrack = audioSystem.voices[note.lane];
			if (voicesTrack == null) voicesTrack = audioSystem.voices[0];
			if (voicesTrack != null) {
				voicesTrack.volume = 0;
			}
		}

		health -= healthLoss[note.lane];

		combo = 0;
		score -= 50;
		++misses;
		accuracy.increment(1.0, true);

		if (health < 0 && !disposed) {
			onDeath.dispatch(chart, note.lane);
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

	inline function releaseSustain(note:MetaNote) {
		combo = 0;
	}

	function startSong(chart:Chart) {
		Sys.println('Song activity is on');

		if (!RenderingMode.enabled) {
			audioSystem.play();
		}

		songStarted = true;
		songEnded = false;
	}

	function stopSong(chart:Chart) {
		Sys.println('Song activity is off');

		if (!RenderingMode.enabled) {
			audioSystem.stop();
		} else {
			RenderingMode.stopRender();
		}

		songEnded = true;
		songStarted = false;

		Main.switchState(MAIN_MENU);
	}

	function gameOver(chart:Chart, lane:Int) {
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

		if (audioSystem != null) audioSystem.stop();

		var char = field.actors[lane + field.numSpectators];
		if (char == null) char = field.actors[1 + field.numSpectators];

		field.actorOnGameOver = char;
		field.targetCamera.x = lane == 0 ? -50 : 50; // Prototype camera logic I have for now
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
		GC.run();
	}
}
