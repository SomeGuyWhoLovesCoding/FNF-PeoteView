package structures.gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;

/**
	The input system for the playfield.
	This class handles the input for the playfield, including key presses, releases, and mouse clicks.
	It maps key codes to receptor IDs and manages the strumline for different mania modes.
	But! It is very important to note that this class is not meant to be used outside of the playfield.
**/
@:publicFields
class InputSystem {
	var keyMap:Array<Array<Int>>; // indexed by KeyCode, stores [index, lane]
	var receptorIds:Array<Int>;
	var strumline:Array<Float>;
	var strumlinePlayable:Array<Bool>;

	var parent:PlayField;

	function new(mania:Int, parent:PlayField) {
		this.parent = parent;

		keyMap = [];
		keyMap.resize(0x111A); // Refer to https://github.com/openfl/lime/blob/develop/src/lime/ui/KeyCode.hx#L251C14-L251C24 to see what I mean by this

		reloadKeybinds(mania);

		switch (mania) {
			case 1:
				receptorIds = [0];
				strumline = [0, 1.05];

			case 2:
				receptorIds = [0, 3];
				strumline = [111, 1.0];

			case 3:
				receptorIds = [0, 2, 3];
				strumline = [104, 0.95];

			case 5:
				receptorIds = [1, 2, 3, 3, 4];
				strumline = [97, 0.9];

			case 6:
				receptorIds = [0, 1, 3, 0, 2, 3];
				strumline = [83, 0.83];

			case 7:
				receptorIds = [0, 1, 3, 2, 0, 2, 3];
				strumline = [75, 0.77];

			case 8:
				receptorIds = [0, 1, 2, 3, 0, 1, 2, 3];
				strumline = [70, 0.68];

			case 9:
				receptorIds = [0, 1, 2, 3, 2, 0, 1, 2, 3];
				strumline = [56, 0.64];

			case 10:
				receptorIds = [0, 1, 2, 3, 1, 2, 0, 1, 2, 3];

				strumline = [53, 0.59];

			case 11:
				receptorIds = [0, 1, 2, 3, 0, 1, 3, 0, 1, 2, 3];

				strumline = [50, 0.57];

			case 12:
				receptorIds = [0, 1, 2, 3, 1, 0, 3, 2, 0, 1, 2, 3];

				strumline = [47, 0.4777];

			case 13:
				receptorIds = [0, 1, 2, 3, 1, 0, 2, 3, 2, 0, 1, 2, 3];

				strumline = [42, 0.432];

			case 14:
				receptorIds = [0, 1, 2, 3, 0, 1, 3, 0, 2, 3, 0, 1, 2, 3];

				strumline = [41, 0.42];

			case 15:
				receptorIds = [0, 1, 2, 3, 0, 1, 3, 2, 0, 2, 3, 0, 1, 2, 3];

				strumline = [39, 0.405];

			case 16:
				receptorIds = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3];

				strumline = [37, 0.375];

			default:
				receptorIds = [0, 1, 2, 3];

				strumline = [112, 1.0];

		}

		strumlinePlayable = [false, true];

		haxe.Timer.delay(addEvents, 1); // Just for a single millisecond the event doesn't get added until next frame
	}

	function reloadKeybinds(mania:Int = 4) {
		keyMap = [];

		var keybinds = SaveData.state.controls.game.keybindArray[mania - 1];
		for (i in 0...keybinds.length) {
			var keybind = keybinds[i];
			for (j in 0...keybind.length) {
				var keyCode = minimize(keybind[j]);
				keyMap[keyCode] = [i, 1];
			}
		}
	}

	function addEvents() {
		var window = lime.app.Application.current.window;
		#if FV_LIME_FORK
		window.onKeyDownPrecise.add(press);
		window.onKeyUpPrecise.add(release);
		#else
		window.onKeyDown.add(press);
		window.onKeyUp.add(release);
		#end
		Main.current.mouseDown = mousePress;
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		#if FV_LIME_FORK
		window.onKeyDownPrecise.remove(press);
		window.onKeyUpPrecise.remove(release);
		#else
		window.onKeyDown.remove(press);
		window.onKeyUp.remove(release);
		#end
		Main.current.mouseDown = null;
	}

	function press(code:KeyCode, mod:KeyModifier
		#if FV_LIME_FORK
		, timestamp:Float
		#end) {
		/*var timeStamp:Float = timestamp;
		Sys.println('Press: $timeStamp, ${timeStamp % (/*100000000/1000 / lime.app.Application.current.window.frameRate)}');*/
		var field = parent.field;
		var isInGameOver = field.isInGameOver;
		var controls = SaveData.state.controls;
		var game = controls.game;
		var ui = controls.ui;

		code = minimize(code);

		if (parent.ready && code == game.pause
			&& !parent.songEnded) {
			if (!parent.paused) parent.pause();
			return;
		}

		if (parent.ready && !parent.botplay
			&& !isInGameOver && !parent.songEnded
			&& !parent.paused && code == game.reset && !RenderingMode.enabled) {
			parent.gameOver(Chart.header, 1);
			return;
		}

		if (parent.ready && isInGameOver) {
			// Yoooooo
			field.endGameOver(code == ui.back);
			return;
		}

		if (parent.disposed || parent.botplay
			|| isInGameOver
			|| RenderingMode.enabled || parent.paused) {
			return;
		}

		var keyData = keyMap[code];
		if (keyData == null) {
			return;
		}

		var index = keyData[0];
		var lane = keyData[1];

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[lane];
			if (!strumline.playerHitsToCheck[index]) {
				strumline.playerHitsToCheck[index] = true;
				strumline.press(index #if FV_LIME_FORK , timestamp #end);
			}
		}

		parent.onKeyPress.dispatch(code);
	}

	function release(code:KeyCode, mod:KeyModifier
		#if FV_LIME_FORK
		, timestamp:Float
		#end) {
		if (parent.disposed || parent.botplay
			|| parent.field.isInGameOver
			|| RenderingMode.enabled || parent.paused) {
			return;
		}

		code = minimize(code);

		var keyData = keyMap[code];
		if (keyData == null) {
			return;
		}

		var index = keyData[0];
		var lane = keyData[1];

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[lane];
			if (strumline.playerHitsToCheck[index]) {
				strumline.playerHitsToCheck[index] = false;
				strumline.release(index);
			}
		}

		parent.onKeyRelease.dispatch(code);
	}

	function mousePress(x:Float, y:Float, mouseButton:MouseButton) {
		if (mouseButton != MouseButton.LEFT) return;
		parent.pause();
	}

	// This is here to prevent invalid array index error because I chose to have an indexed two-dimensional array instead of a map. Another dumb yet smart microoptimization just in case lol
	inline function minimize(code:Int) {
		if (code > 0x40000000) {
			code -= 0x40000000;
			code += 0x1000;
		}
		return code;
	}

	function dispose() {
		removeEvents();

		while (keyMap.pop() != null) {}
		keyMap = null;
		receptorIds = null;
		strumline = null;
		strumlinePlayable = null;
	}
}