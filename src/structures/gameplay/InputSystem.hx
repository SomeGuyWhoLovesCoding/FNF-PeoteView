package structures.gameplay;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;

/**
	The input system for the playfield.
	This class handles the input for the playfield, including key presses, releases, and mouse clicks.
	It maps key codes to receptor IDs and manages the strumline for different mania modes.
	But! It is very important to note that this class is integrated onto the playfield.
	@since Development
**/
@:publicFields
class InputSystem {
	var parent:PlayField;

	function new(mania:Int, parent:PlayField) {
		this.parent = parent;
		Tools.forSync(addEvents);
	}

	function addEvents() {
		var window = lime.app.Application.current.window;
		#if !android
		window.onKeyDown.add(press);
		window.onKeyUp.add(release);
		#end
		Main.current.mouseDown = mousePress;
	}

	function removeEvents() {
		var window = lime.app.Application.current.window;
		#if !android
		window.onKeyDown.remove(press);
		window.onKeyUp.remove(release);
		#end
		Main.current.mouseDown = null;
	}

	var _index = 0;
	var _lane = 0;

	function detectIndexLaneFromKey(code:KeyCode) {
		if (parent == null)
			return false;
		var noteSystem = parent.noteSystem;
		if (noteSystem == null)
			return false;
		var strumlines = noteSystem.strumlines;
		if (strumlines == null)
			return false;

		for (i in 0...strumlines.length) {
			var strumline = strumlines[i];
			if (!strumline.playable)
				continue;
			var foundIndex = false;
			for (j in 0...strumline.length) {
				if (code == strumline.keybinds[j] || code == strumline.keybindsTwo[j]) {
					_index = j;
					foundIndex = true;
					break;
				}
			}
			if (foundIndex) {
				_lane = i;
				return true;
			}
		}

		return false;
	}

	function press(code:KeyCode, mod:KeyModifier) {
		var field = parent.field;
		var isInGameOver = field.isInGameOver;
		var controls = SaveData.state.controls;
		var game = controls.game;
		var ui = controls.ui;

		if (gameCondition(code))
			return;

		if (parent.disposed || parent.botplay || isInGameOver || RenderingMode.enabled || parent.paused) {
			return;
		}

		if (!detectIndexLaneFromKey(code))
			return;

		#if linc_luajit_funkinview
		parent.funkinviewlua.callFunction('keyPress', _index, _lane);
		#end

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[_lane];
			var receptor = strumline.receptors[_index];
			if (!receptor.playerHitToCheck) {
				receptor.playerHitToCheck = true;
				strumline.press(_index);
			}
		}

		parent.onKeyPress.dispatch(code);

		#if linc_luajit_funkinview
		parent.funkinviewlua.callFunction('keyPressPost', _index, _lane);
		parent.funkinviewlua.callFunction('postKeyPress', _index, _lane); // alternative syntax
		#end
	}

	function release(code:KeyCode, mod:KeyModifier) {
		if (parent.disposed || parent.botplay || parent.field.isInGameOver || RenderingMode.enabled || parent.paused) {
			return;
		}

		if (!detectIndexLaneFromKey(code))
			return;

		#if linc_luajit_funkinview
		parent.funkinviewlua.callFunction('keyRelease', _index, _lane);
		#end

		var noteSystem = parent.noteSystem;

		if (noteSystem != null) {
			var strumline = noteSystem.strumlines[_lane];
			var receptor = strumline.receptors[_index];
			if (receptor.playerHitToCheck) {
				receptor.playerHitToCheck = false;
				strumline.release(_index);
			}
		}

		parent.onKeyRelease.dispatch(code);

		#if linc_luajit_funkinview
		parent.funkinviewlua.callFunction('keyReleasePost', _index, _lane);
		parent.funkinviewlua.callFunction('postKeyRelease', _index, _lane); // alternative syntax
		#end
	}

	function gameCondition(keyCode:KeyCode) {
		var returnValue = false;
		var game = SaveData.state.controls.game;

		var field = parent.field;
		var isInGameOver = field.isInGameOver;

		if (parent.ready && isInGameOver) {
			field.endGameOver(keyCode == SaveData.state.controls.ui.back);
			return true;
		}

		if (parent.ready && keyCode == game.pause && !parent.songEnded) {
			if (!parent.paused)
				parent.pause();
			return true;
		}

		if (parent.ready && !parent.botplay && !isInGameOver && !parent.songEnded && !parent.paused && keyCode == game.reset && !RenderingMode.enabled) {
			parent.gameOver(Chart.header, 1);
			return true;
		}

		return false;
	}

	function mousePress(x:Float, y:Float, mouseButton:MouseButton) {
		if (mouseButton != MouseButton.LEFT)
			return;
		parent.pause();
	}

	function dispose() {
		removeEvents();
	}
}
