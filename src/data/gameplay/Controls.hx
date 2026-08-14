package data.gameplay;

import input2action.*;
import input2action.util.NestedArray;

/**
	The controls of the fnf engine.
	This allows for easy keybind managing for it.
	@since Development
**/
@:publicFields
class Controls {
	var handle:ControlsHandle;
	var config:ActionConfig;
	var active:Bool = false;

	function new() {
		handle = new ControlsHandle();
		reload();
	}

	public function reload() {
		var controls = SaveData.state.controls;

		config = [
			{
				action: Action.UI_LEFT,
				keyboard: NestedArray.fromNestedArrayItem(controls.ui.left),
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.left)
			},
			{
				action: Action.UI_DOWN,
				keyboard: NestedArray.fromNestedArrayItem(controls.ui.down),
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.down)
			},
			{
				action: Action.UI_UP,
				keyboard: NestedArray.fromNestedArrayItem(controls.ui.up),
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.up)
			},
			{
				action: Action.UI_RIGHT,
				keyboard: NestedArray.fromNestedArrayItem(controls.ui.right),
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.right)
			},
			{
				action: Action.UI_ACCEPT,
				keyboard: NestedArray.fromNestedArrayItem(controls.ui.accept),
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.accept)
			},
			{
				action: Action.UI_BACK,
				keyboard: NestedArray.fromNestedArrayItem(controls.ui.back),
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.back)
			},
			{
				action: Action.GAME_PAUSE,
				keyboard: NestedArray.fromNestedArrayItem(controls.game.pause),
				gamepad: NestedArray.fromNestedArrayItem(controls.game.pause)
			},
			{
				action: Action.GAME_RESET,
				keyboard: NestedArray.fromNestedArrayItem(controls.game.reset),
				gamepad: NestedArray.fromNestedArrayItem(controls.game.reset)
			},
			{
				action: Action.GAME_DEBUG,
				keyboard: NestedArray.fromNestedArrayItem(controls.game.debug),
				gamepad: NestedArray.fromNestedArrayItem(controls.game.debug)
			}
		];

		// Rebuild every mode layout with the fresh config. The single shared
		// Input2Action keeps its window listeners; only the cached KeyboardAction
		// instances are recreated so a keybind change takes effect everywhere.
		handle.rebuild(config);
	}

	/**
		Activate the input layout for `mode`. The single shared `Input2Action`
		swaps to (and caches) that mode's `KeyboardAction`; all other modes are
		inactive. One mode is active at any time.
	**/
	public function setMode(mode:ControlsMode, actions:ActionMap) {
		active = true;
		handle.setMode(mode, actions);
	}

	public function unBind() {
		if (!active) return;
		handle.unBind();
		active = false;
	}

	inline function unbinded() {
		return handle.unbinded();
	}
}

@:publicFields
class ControlsHandle {
	// One Input2Action shared by every mode so window key events are registered
	// exactly once. Switching modes only swaps which KeyboardAction is active.
	static var i2a:Input2Action;
	var config:ActionConfig;
	var kb:KeyboardAction;

	function new() {
		if (i2a == null) {
			i2a = new Input2Action();
			i2a.registerKeyboardEvents(lime.app.Application.current.window);
		}
	}

	/** Refresh the layout config after a keybind change. */
	function rebuild(newConfig:ActionConfig) {
		config = newConfig;
		unBind();
	}

	/**
		Make `mode` the single active layout. A fresh `KeyboardAction` is created
		on every activation so no stuck key state survives a mode switch: a key
		released after its action was yanked mid-press would otherwise read as a
		repeat next time and swallow the press (the "two presses" bug).
	**/
	function setMode(mode:ControlsMode, actions:ActionMap) {
		unBind();
		kb = new KeyboardAction(config, actions);
		i2a.addKeyboard(kb);
	}

	function unBind() {
		if (kb != null) {
			i2a.removeKeyboard(kb);
			kb = null;
		}
	}

	inline function unbinded() {
		return i2a.activeKeyboardActions.length == 0;
	}
}

enum abstract Action(String) to String {
	var UI_LEFT = "L";
	var UI_DOWN =  "D";
	var UI_UP = "U";
	var UI_RIGHT = "R";
	var UI_ACCEPT = "A";
	var UI_BACK = "B";
	var GAME_PAUSE = "P";
	var GAME_RESET = "X";
	var GAME_DEBUG = "C";
}