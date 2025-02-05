package structures;

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
	var strumline:Array<Array<Vector<Float>>>;
	var strumlinePlayable:Array<Bool>;
	var strumlineIndexes:Vector<Int>;

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

				strumline = [[Vector.fromArrayCopy([0, 50, 1.05])], [Vector.fromArrayCopy([0, 678, 1.05])]];

			case 2:
				receptorIds = Vector.fromArrayCopy([0, 3]);

				strumline = [
					[for (i in 0...2) Vector.fromArrayCopy([receptorIds[i], 50 + (111 * i), 1.0])],
					[for (i in 0...2) Vector.fromArrayCopy([receptorIds[i], 678 + (111 * i), 1.0])]
				];

			case 3:
				receptorIds = Vector.fromArrayCopy([0, 2, 3]);

				strumline = [
					[for (i in 0...3) Vector.fromArrayCopy([receptorIds[i], 50. + (104 * i), 0.95])],
					[for (i in 0...3) Vector.fromArrayCopy([receptorIds[i], 678. + (104 * i), 0.95])]
				];

			case 5:
				receptorIds = Vector.fromArrayCopy([1, 2, 3, 3, 4]);
				strumline = [
					[for (i in 0...5) Vector.fromArrayCopy([receptorIds[i], 50 + (97 * i), 0.9])],
					[for (i in 0...5) Vector.fromArrayCopy([receptorIds[i], 678 + (97 * i), 0.9])]
				];

			case 6:
				receptorIds = Vector.fromArrayCopy([0, 1, 3, 0, 2, 3]);
				strumline = [
					[for (i in 0...6) Vector.fromArrayCopy([receptorIds[i], 50 + (83 * i), 0.83])],
					[for (i in 0...6) Vector.fromArrayCopy([receptorIds[i], 676 + (83 * i), 0.83])]
				];

			case 7:
				receptorIds = Vector.fromArrayCopy([0, 1, 3, 2, 0, 2, 3]);
				strumline = [
					[for (i in 0...7) Vector.fromArrayCopy([receptorIds[i], 50 + (75 * i), 0.77])],
					[for (i in 0...7) Vector.fromArrayCopy([receptorIds[i], 668 + (75 * i), 0.77])]
				];

			case 8:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 2, 3]);
				strumline = [
					[for (i in 0...8) Vector.fromArrayCopy([receptorIds[i], 50 + (70 * i), 0.68])],
					[for (i in 0...8) Vector.fromArrayCopy([receptorIds[i], 663 + (70 * i), 0.68])]
				];

			case 9:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 2, 0, 1, 2, 3]);
				strumline = [
					[for (i in 0...9) Vector.fromArrayCopy([receptorIds[i], 50 + (56 * i), 0.64])],
					[for (i in 0...9) Vector.fromArrayCopy([receptorIds[i], 655 + (56 * i), 0.64])]
				];

			case 10:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 1, 2, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...10) Vector.fromArrayCopy([receptorIds[i], 47 + (53 * i), 0.59])],
					[for (i in 0...10) Vector.fromArrayCopy([receptorIds[i], 645 + (53 * i), 0.59])]
				];

			case 11:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 3, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...11) Vector.fromArrayCopy([receptorIds[i], 44 + (50 * i), 0.57])],
					[for (i in 0...11) Vector.fromArrayCopy([receptorIds[i], 639 + (50 * i), 0.57])]
				];

			case 12:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 1, 0, 3, 2, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...12) Vector.fromArrayCopy([receptorIds[i], 40 + (47 * i), 0.4777])],
					[for (i in 0...12) Vector.fromArrayCopy([receptorIds[i], 631 + (47 * i), 0.4777])]
				];

			case 13:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 1, 0, 2, 3, 2, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...13) Vector.fromArrayCopy([receptorIds[i], 38 + (42 * i), 0.432])],
					[for (i in 0...13) Vector.fromArrayCopy([receptorIds[i], 628 + (42 * i), 0.432])]
				];

			case 14:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 3, 0, 2, 3, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...14) Vector.fromArrayCopy([receptorIds[i], 36 + (41 * i), 0.42])],
					[for (i in 0...14) Vector.fromArrayCopy([receptorIds[i], 627 + (41 * i), 0.42])]
				];

			case 15:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 3, 2, 0, 2, 3, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...15) Vector.fromArrayCopy([receptorIds[i], 34 + (39 * i), 0.405])],
					[for (i in 0...15) Vector.fromArrayCopy([receptorIds[i], 626 + (39 * i), 0.405])]
				];

			case 16:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]);

				strumline = [
					[for (i in 0...16) Vector.fromArrayCopy([receptorIds[i], 30 + (37 * i), 0.375])],
					[for (i in 0...16) Vector.fromArrayCopy([receptorIds[i], 626 + (37 * i), 0.375])]
				];

			default:
				receptorIds = Vector.fromArrayCopy([0, 1, 2, 3]);

				strumline = [
					[for (i in 0...4) Vector.fromArrayCopy([receptorIds[i], 50 + (112 * i), 1.0])],
					[for (i in 0...4) Vector.fromArrayCopy([receptorIds[i], 680 + (112 * i), 1.0])]
				];

		}

		strumlinePlayable = [false, true];

		strumlineIndexes = new Vector<Int>(strumline.length);

		for (i in 0...strumline.length) {
			parent.numOfReceptors += strumline[i].length;
			if (i != 0) strumlineIndexes[i] = strumline[i-1].length;
			else strumlineIndexes[i] = 0;
		}

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
		if (parent.ready && code == SaveData.state.controls.game.pause
			&& !parent.songEnded) {
			if (!parent.paused) parent.pause();
			else if (parent.field.isInGameOver) parent.field.endGameOver();
			return;
		}

		if (parent.ready && !parent.botplay
			&& !parent.field.isInGameOver && !parent.songEnded
			&& !parent.paused && code == SaveData.state.controls.game.reset) {
			parent.gameOver(parent.chart, 1);
			return;
		}

		if (parent.ready && parent.field.isInGameOver && !parent.songEnded) {
			// Yoooooo
			parent.field.endGameOver(
				code == SaveData.state.controls.ui.back ? true :
				code == SaveData.state.controls.ui.accept ? false : false
			);
			return;
		}

		if (parent.disposed || parent.botplay || RenderingMode.enabled || parent.paused) return;

		if (!exists(code)) {
			return;
		}

		var map = get(code);
		var lane = map[1];
		var index = map[0] + strumlineIndexes[lane];

		var noteSystem = parent.noteSystem;

		if (noteSystem.playerHitsToCheck[index]) {
			return;
		}

		var rec = noteSystem.getReceptor(index);

		if (!rec.playable) {
			return;
		}

		noteSystem.playerHitsToCheck[index] = true;

		var noteToHit = noteSystem.notesToHit[index];
		noteSystem.hitDetectNote(noteToHit, rec, index);

		parent.onKeyPress.dispatch(code);
	}

	function release(code:KeyCode, mod:KeyModifier) {
		if (parent.disposed || parent.botplay || RenderingMode.enabled || parent.paused && parent.ready) return;

		if (!exists(code)) {
			return;
		}

		var map = get(code);
		var lane = map[1];
		var index = map[0] + strumlineIndexes[lane];

		var noteSystem = parent.noteSystem;

		noteSystem.playerHitsToCheck[index] = false;

		var rec = noteSystem.getReceptor(index);

		if (!rec.playable) {
			return;
		}

		var sustainToRelease = noteSystem.sustainsToHold[index];
		noteSystem.releaseDetectSustain(sustainToRelease, rec, index);

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
		strumlineIndexes = null;
	}
}