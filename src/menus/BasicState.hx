package menus;

import lime.ui.KeyCode;

/**
	The basic state.
**/
#if !debug
@:noDebug
#end
class BasicState extends State {
	// The gameplay camera.
	var gpCam:Camera;

	// The interface camera.
	var uiCam:Camera;

	// The sound.
	var inst:Audio;
	var voices:Audio;

	// The conductor.
	var conductor:Conductor;

	// The bpm change stuff.
	var bpmChangePosition:Int = 0;
	var bpmChanges:Array<Array<Float>> = [
		//[11162.79069767442, 344, 0, 0],
		/*[100465.1162790698, 0, 3, 4],
		[107441.8604651163, 0, 4, 3]*/
	];

	// The countdown event stuff.
	var countdownEventPosition:Int = 0;
	var countdownEvents:Array<Array<Float>> = [
		/*[4534.883720930233, 0],
		[4883.720930232559, 1],
		[5232.558139534884, 2],
		[5581.39534883721, 3],
		[11162.79069767442, 3]*/
	];

	// The chart.
	var chart:Chart;

	// The countdown display.
	var countdownDisp:CountdownDisplay;

	override function new() {
		super();

		gpCam = new Camera(0, 0, Screen.view.width, Screen.view.height, 0xFF00FF7F);
		uiCam = new Camera(0, 0, Screen.view.width, Screen.view.height, 0x00000000);

		chart = new Chart("assets/songs/fresh");

		conductor = new Conductor(chart.header.bpm);
		/*conductor.onStep.add(function(step) {
			Sys.println('Step $step');
		});*/

		conductor.onBeat.add(function(beat) {
			//Sys.println('Beat $beat');
			if (beat % conductor.denominator != 0) {
				Audio.playSound("assets/conductor/beat.wav");
			}

			if (beat < 0) {
				countdownDisp.countdownTick(Math.floor(4 + beat));
			}

			if (beat == 0) {
				inst = new Audio(chart.header.instDir);
				inst.play();

				voices = new Audio(chart.header.voicesDir);
				voices.play();
			}
		});

		conductor.onMeasure.add(function(measure) {
			//Sys.println('Measure $measure');
			Audio.playSound("assets/conductor/measure.wav");
		});

		conductor.active = false;
		conductor.time = -conductor.crochet * 5;
		conductor.active = true;

		countdownDisp = new CountdownDisplay(chart, uiCam);
	}

	var time:Float = 0;
	override function update(deltaTime:Float) {
		countdownDisp.update(deltaTime);

		if (countdownEventPosition < countdownEvents.length) {
			var countdownEvent = countdownEvents[countdownEventPosition];
			if (conductor.time > countdownEvent[0]) {
				countdownDisp.countdownTick(Math.floor(countdownEvent[1]));
				++countdownEventPosition;
			}
		}

		if (bpmChangePosition < bpmChanges.length) {
			var bpmChange = bpmChanges[bpmChangePosition];
			var position = bpmChange[0];
			if (conductor.time > position) {
				var numerator = bpmChange[2];
				Sys.println(numerator);

				if (numerator < 1) {
					numerator = conductor.numerator;
				}

				var denominator = bpmChange[3];
				Sys.println(denominator);

				if (denominator < 1) {
					denominator = conductor.denominator;
				}

				conductor.changeBpmAt(position, bpmChange[1], numerator, denominator);
				++bpmChangePosition;
			}
		}

		var musicTime:Float = 0;

		if (inst != null) {
			inst.update(deltaTime);
			voices.update(deltaTime);
			musicTime = inst.time;
			conductor.time = musicTime;
		} else {
			musicTime = conductor.time += deltaTime;
		}

		chart.update(musicTime);

		//uiCam.r = Math.sin(time) * 20;
		gpCam.update();
		uiCam.update();
	}

	override function onKeyDown(keyCode, keyModifier) {
		//trace(keyCode);

		if (inst == null) {
			return;
		}

		switch (keyCode) {
			case RETURN:
				inst.play();
				voices.play();

			case SPACE:
				inst.pause();
				voices.pause();

			case M:
				inst.volume = inst.volume == 0.1 ? 1 : 0.1;
				voices.volume = voices.volume == 0.1 ? 1 : 0.1;

			case B:
				inst.time = 1000000;
				voices.time = 1000000;

			case A:
				var time = inst.time;
				time -= 1000;
				inst.time = time;
				voices.time = time;

			case D:
				var time = inst.time;
				time += 1000;
				inst.time = time;
				voices.time = time;

			case BACKSPACE:
				inst.stop();
				voices.stop();

			case NUMBER_6:
				gpCam.scrollX = gpCam.scrollX == 100 ? 0 : 100;

			case NUMBER_7:
				gpCam.scrollY = gpCam.scrollY == 100 ? 0 : 100;

			case NUMBER_8:
				uiCam.scrollX = uiCam.scrollX == 100 ? 0 : 100;

			case NUMBER_9:
				uiCam.scrollY = uiCam.scrollY == 100 ? 0 : 100;

			default:
		}
	}
}