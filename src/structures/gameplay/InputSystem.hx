package structures.gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;

/**
	The input system for the playfield.
	This is an internal structure and should only be used inside of the playfield NOT to be touched with.
	Warning: 70% of inside this class is very messy.
**/
@:publicFields
class InputSystem {
	var map:Map<KeyCode, Vector<Int>>;
	var receptorIds:Vector<Int>;
	var strumline:Array<Float>;
	var strumlinePlayable:Array<Bool>;

	var parent:PlayField;

	function new(mania:Int, parent:PlayField) {
		this.parent = parent;

		map = [];

		reloadKeybinds(mania);

		// This shit is fucking unbearable as FUCK
		// It's why it's in its own class
		switch (mania) {
			case 1:
				receptorIds = Vector.fromArrayCopy([0]);
				strumline = [0, 1.05];

			case 2:
				receptorIds = Vector.fromArrayCopy([0, 3]);
				strumline = [111, 1.0];

			case 3:
				receptorIds = Vector.fromArrayCopy([0, 2, 3]);
				strumline = [104, 0.95];

			case 5:
				receptorIds = Vector.fromArrayCopy([1, 2, 3, 3, 4]);
				strumline = [97, 0.9];

			case 6:
				receptorIds = Vector.fromArrayCopy([0, 1, 3, 0, 2, 3]);
				strumline = [83, 0.83];

			case 7:
				receptorIds = Vector.fromArrayCopy([0, 1, 3, 2, 0, 2, 3]);
				strumline = [75, 0.77];

			case 8:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 2, 3]);
				strumline = [70, 0.68];

			case 9:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 2, 0, 1, 2, 3]);
				strumline = [56, 0.64];

			case 10:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 1, 2, 0, 1, 2, 3]);

				strumline = [53, 0.59];

			case 11:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 3, 0, 1, 2, 3]);

				strumline = [50, 0.57];

			case 12:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 1, 0, 3, 2, 0, 1, 2, 3]);

				strumline = [47, 0.4777];

			case 13:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 1, 0, 2, 3, 2, 0, 1, 2, 3]);

				strumline = [42, 432];

			case 14:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 3, 0, 2, 3, 0, 1, 2, 3]);

				strumline = [41, 0.42];

			case 15:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 3, 2, 0, 2, 3, 0, 1, 2, 3]);

				strumline = [39, 0.405];

			case 16:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]);

				strumline = [37, 0.375];

			default:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3]);

				strumline = [112, 1.0];

		}

		strumlinePlayable = [false, true];

		haxe.Timer.delay(addEvents, 1); // Just for a single millisecond the event doesn't get added until next frame
	}

	function reloadKeybinds(mania:Int = 4) {
		map.clear();

		var keybinds = SaveData.state.controls.game.keybindArray[mania - 1];
		for (i in 0...keybinds.length) {
			var keybind = keybinds[i];
			for (j in 0...keybind.length)
				map[keybind[j]] = Vector.fromArrayCopy([i, 1]);
		}
	}

	function addEvents() {
		var window = lime.app.Application.current.window;
		window.onKeyDown.add(press);
		window.onKeyUp.add(release);
		window.onMouseDown.add(mousePress);
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		window.onKeyDown.remove(press);
		window.onKeyUp.remove(release);
		window.onMouseDown.remove(mousePress);
	}

	inline function exists(keyCode:KeyCode) {
		return untyped map.exists(keyCode);
	}

	inline function get(keyCode:KeyCode) {
		return untyped map.get(keyCode);
	}

	function press(code:KeyCode, mod:KeyModifier) {
		var field = parent.field;
		var isInGameOver = field.isInGameOver;
		var controls = SaveData.state.controls;
		var game = controls.game;
		var ui = controls.ui;

		if (parent.ready && code == game.pause
			&& !parent.songEnded) {
			if (!parent.paused) parent.pause();
			else if (isInGameOver && field.endedGameOver) field.endGameOver();
			return;
		}

		if (parent.ready && !parent.botplay
			&& !isInGameOver && !parent.songEnded
			&& !parent.paused && code == game.reset) {
			parent.gameOver(parent.chart, 1);
			return;
		}

		if (parent.ready && isInGameOver
			|| (code == ui.back ||
				code == ui.accept)) {
			// Yoooooo
			field.endGameOver(code == ui.back);
			return;
		}

		if (parent.disposed || parent.botplay
			|| isInGameOver
			|| RenderingMode.enabled || parent.paused) {
			return;
		}

		if (!exists(code)) {
			return;
		}

		var map = get(code);
		var lane = map[1];
		var index = map[0];

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[lane];
			if (!strumline.playerHitsToCheck[index]) {
				strumline.playerHitsToCheck[index] = true;
				strumline.press(index);
			}
		}

		parent.onKeyPress.dispatch(code);
	}

	function release(code:KeyCode, mod:KeyModifier) {
		if (parent.disposed || parent.botplay
			|| parent.field.isInGameOver
			|| RenderingMode.enabled || parent.paused) {
			return;
		}

		if (!exists(code)) {
			return;
		}

		var map = get(code);
		var lane = map[1];
		var index = map[0];

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
		if (mouseButton != LEFT || !Main.current.fakeWindow.isMouseInsideApp()) return;
		parent.pause();
	}

	function dispose() {
		removeEvents();

		map.clear();
		map = null;
		receptorIds = null;
		strumline = null;
		strumlinePlayable = null;
	}
}