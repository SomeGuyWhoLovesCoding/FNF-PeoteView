package handler;

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
@:access(input2action.KeyboardAction)
@:access(input2action.InputState)
class ControlsHandle {
	// One Input2Action shared by every mode so window key events are registered
	// exactly once. Switching modes only swaps which KeyboardAction is active.
	static var i2a:Input2Action;
	var config:ActionConfig;
	var modeToActions:Map<ControlsMode, ActionMap>;
	var modeToKeyboardAction:Map<ControlsMode, KeyboardAction>;
	var kb:KeyboardAction;

	function new() {
		if (i2a == null) {
			i2a = new Input2Action();
			i2a.registerKeyboardEvents(lime.app.Application.current.window);
		}
		modeToActions = new Map();
		modeToKeyboardAction = new Map();
	}

	/** Rebuild every cached mode layout after a keybind change. */
	function rebuild(newConfig:ActionConfig) {
		config = newConfig;
		unBind();

		var fresh = new Map<ControlsMode, KeyboardAction>();
		for (mode in modeToActions.keys()) {
			var actions = modeToActions.get(mode);
			if (actions == null) continue;
			fresh.set(mode, new KeyboardAction(newConfig, actions));
		}
		modeToKeyboardAction = fresh;
	}

	/**
		Cache the mode's layout (rebuilding its KeyboardAction lazily if the mode
		is new), then make it the single active one.
	**/
	function setMode(mode:ControlsMode, actions:ActionMap) {
		// The KeyboardAction constructor copies the action closures into its own
		// InputState, so a cached action keeps dispatching to whichever menu
		// provided `actions` on the FIRST setMode call for this mode. Menus are
		// disposed and recreated on every state entry with a fresh ActionMap, so
		// the cached closures would target a dead instance and silently swallow
		// input. Rebuild whenever the actions map reference changes.
		var stale = modeToActions.get(mode) != actions;
		modeToActions.set(mode, actions);
		unBind();

		var next = modeToKeyboardAction.get(mode);
		if (next == null || stale) {
			next = new KeyboardAction(config, actions);
			modeToKeyboardAction.set(mode, next);
		}
		kb = next;
		i2a.addKeyboard(kb);
	}

	function unBind() {
		if (kb != null) {
			// Synthesize key releases for any held keys. A mode switch can yank
			// the active KeyboardAction out of i2a mid-press (e.g. opening the
			// options menu from the pause screen), which loses the keyUp event
			// and leaves isDown stuck. Reusing that cached action would then read
			// the next press as a key repeat and swallow it ("two presses" bug).
			for (k in 0...KeyboardAction.MAX_USABLE_KEYCODES) {
				if (kb.inputState.isDown(k))
					kb.inputState.callUpActions(k, 0, true);
			}
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