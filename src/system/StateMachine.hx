package system;

import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.Window;
import input2action.ActionMap;
import Main;

/**
	Central game-state manager.
	State changes are queued and applied at a safe point (the start of the next
	application frame, via `beginFrame()`), so they never happen in the middle of
	input event dispatch. A single "focused" menu (if any) receives all routed
	keyboard/mouse input through permanent window listeners registered once here.
**/
class StateMachine {
	static inline var MAX_QUEUED = 32;

	var window:Window;
	var controls:Controls;
	var queued:Array<StateSelection>;
	public var current(default, null):StateSelection;
	var focus:MenuInput;
	var focusRequest:MenuInput;
	var focusPending:Bool;
	var disposed:Bool;
	var mouseBridge:(Float, Float, MouseButton) -> Void;

	/** Implemented by Main: build the state object for `newState`. */
	public var createState:StateSelection -> MenuInput;

	/** Implemented by Main: tear down the current state object. */
	public var destroyState:StateSelection -> Void;

	public function new(window:Window, controls:Controls) {
		this.window = window;
		this.controls = controls;
		this.current = NONE;
		this.queued = [];
		this.focus = null;
		this.focusRequest = null;
		this.focusPending = false;
		this.disposed = false;
		this.createState = null;
		this.destroyState = null;

		window.onKeyDown.add(onKeyDown);
		window.onKeyUp.add(onKeyUp);
		window.onMouseUp.add(onMouseUp);
		window.onMouseMove.add(onMouseMove);
		window.onMouseWheel.add(onMouseWheel);
	}

	public function dispose() {
		if (disposed) return;
		disposed = true;
		window.onKeyDown.remove(onKeyDown);
		window.onKeyUp.remove(onKeyUp);
		window.onMouseUp.remove(onMouseUp);
		window.onMouseMove.remove(onMouseMove);
		window.onMouseWheel.remove(onMouseWheel);
		queued = [];
		focusRequest = null;
		focusPending = false;
		focus = null;
	}

	/**
		Queue a state change. A transition to the current state is still applied
		(dispose + recreate), matching the original behaviour (e.g. restarting
		the gameplay state from the pause screen). Returns false if the queue is
		full or the machine is disposed.
	**/
	public function switchState(newState:StateSelection):Bool {
		if (disposed) return false;
		if (queued.length >= MAX_QUEUED) return false;
		queued.push(newState);
		return true;
	}

	/**
		Queue a change of focused menu input. Applied at the safe point. Passing
		null clears the focus and stops routing input to any menu.
	**/
	public function setFocus(target:MenuInput) {
		if (disposed) return;
		focusRequest = target;
		focusPending = true;
	}

	/**
		Apply queued state changes and focus changes. Called once at the start of
		every application frame, before any state logic runs. Returns true if any
		state transition was applied this frame.
	**/
	public function beginFrame():Bool {
		if (disposed) return false;

		var transitions = queued;
		queued = [];
		for (newState in transitions) {
			doSwitch(newState);
		}

		if (focusPending) {
			var request = focusRequest;
			focusRequest = null;
			focusPending = false;
			applyFocus(request);
		}

		return transitions.length > 0;
	}

	function doSwitch(newState:StateSelection) {
		var oldState = current;

		safe(() -> {
			if (destroyState != null) destroyState(oldState);
		});

		var built = null;
		safe(() -> {
			if (createState != null) built = createState(newState);
		});

		current = newState;

		// Any focus request queued before the transition is stale (its target may
		// have been disposed). The new state's own focus target is applied instead.
		focusRequest = null;
		focusPending = false;
		applyFocus(built);
	}

	function applyFocus(target:MenuInput) {
		if (disposed) return;

		focus = target;

		if (target != null) {
			if (target.actions != null) {
				safe(() -> controls.setMode(target.mode, target.actions));
			} else {
				safe(() -> controls.unBind());
			}
			mouseBridge = (x, y, button) -> safeBool(() -> target.onMouseDown(x, y, button));
			Main.current.mouseDown = mouseBridge;
		} else {
			// Don't unbind input2action here: the playfield/pause screen manage
			// their own bindings, and a deferred rebind from them (e.g. the pause
			// screen's haxe.Timer.delay(addEvents, 1) after closing the options
			// menu) could race this frame-boundary call and clobber fresh bindings.
			// Any stale menu binding left behind is rendered harmless by each
			// menu's `active`/`disposed` guards on its action handlers.
			if (Main.current.mouseDown == mouseBridge) {
				Main.current.mouseDown = null;
			}
			mouseBridge = null;
		}
	}

	function onKeyDown(key:KeyCode, modifier:KeyModifier) {
		if (focus != null) {
			safeBool(() -> focus.onKeyDown(key, modifier));
		}
	}

	function onKeyUp(key:KeyCode, modifier:KeyModifier) {
		if (focus != null) {
			safeBool(() -> focus.onKeyUp(key, modifier));
		}
	}

	function onMouseUp(x:Float, y:Float, button:MouseButton) {
		if (focus != null) {
			safeBool(() -> focus.onMouseUp(x, y, button));
		}
	}

	function onMouseMove(x:Float, y:Float) {
		if (focus != null) {
			safeBool(() -> focus.onMouseMove(x, y));
		}
	}

	function onMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode) {
		if (focus != null) {
			safeBool(() -> focus.onMouseWheel(deltaX, deltaY, mode));
		}
	}

	function safe(fn:Void -> Void) {
		try {
			fn();
		} catch (e) {
			trace("StateMachine error: " + e);
		}
	}

	function safeBool(fn:Void -> Bool) {
		try {
			return fn();
		} catch (e) {
			trace("StateMachine error: " + e);
			return false;
		}
	}
}