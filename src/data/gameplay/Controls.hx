package data.gameplay;

import input2action.*;
import input2action.util.NestedArray;

/**
	The controls of the fnf engine.
	This allows for easy keybind managing for it.
**/
@:publicFields
class Controls {
	var handle:ControlsHandle;
	var config:ActionConfig;

	function new() {
		reload();
	}

	function reload() {
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
				gamepad: NestedArray.fromNestedArrayItem(controls.ui.up)
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
				keyboard: cast NestedArray.fromNestedArrayItem(controls.ui.accept),
				gamepad: cast NestedArray.fromNestedArrayItem(controls.ui.accept)
			},
			{
				action: Action.UI_BACK,
				keyboard: cast NestedArray.fromNestedArrayItem(controls.ui.back),
				gamepad: cast NestedArray.fromNestedArrayItem(controls.ui.back)
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

		handle = new ControlsHandle(config);
	}

	public function bindTo(actions:ActionMap) {
		handle.bindTo(config, actions);
	}

	public function unBind() {
		handle.unBind();
	}
}

@:publicFields
class ControlsHandle {
	var i2a:Input2Action;
	var kb:KeyboardAction;
	var gp:GamepadAction;

	function new(config:ActionConfig) {
		i2a = new Input2Action();
		i2a.registerKeyboardEvents(lime.app.Application.current.window);
	}

	public function bindTo(config:ActionConfig, actions:ActionMap) {
		if(kb != null){
			i2a.removeKeyboard(kb);
		}
		kb = new KeyboardAction(config, actions);
		i2a.addKeyboard(kb);

		//gp = new GamepadAction(config, actions);
		//i2a.addGamepad(Main.current.gamepad, actions);
	}

	public function unBind() {
		i2a.removeKeyboard(kb);

		// i2a.removeGamepad();
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