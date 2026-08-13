package system;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import input2action.ActionMap;

/**
	Base class for every game state and substate.

	Lifecycle is driven entirely by the `StateMachine`:
	- `create()`   — called once, right after the machine installs the state (switch or push).
	- `update()`   — called every frame while the state is installed.
	- `render()`   — called every frame while the state is installed.
	- `dispose()`  — called once when the machine removes the state for good.

	Input is *routed*, never registered. The machine owns the only window
	listeners and forwards events through the active chain (topmost substate
	first, then the current state). A handler returns `true` to consume the
	event and stop propagation; returning `false` lets it fall through.

	States that want keyboard navigation through input2action expose an
	`actions` map. The machine derives the active binding from the state
	stack, so states never call `Controls.bindTo`/`unBind` themselves.

	`persistent` marks singletons (menus) that survive a state switch: they
	are popped off the stack but not disposed.
**/
@:publicFields
class GameState {
	/** Set by `dispose()`; fully writable so states can pre-set it in their own dispose body. */
	public var disposed:Bool = false;

	/** Singletons (menus) survive `switchState`; normal states are disposed. */
	public var persistent(default, null):Bool = false;

	/** input2action bindings used while this state is the active input target. */
	public var actions:ActionMap;

	// ---------------------------------------------------------------
	// Lifecycle
	// ---------------------------------------------------------------

	public function create():Void {}

	public function update(deltaTime:Float):Void {}

	public function render(deltaTime:Float):Void {}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
	}

	/** Called when the state below this substate was popped off the stack. */
	public function onSubstateClosed(sub:GameState):Void {}

	// ---------------------------------------------------------------
	// Routed input. Return `true` to consume the event.
	// ---------------------------------------------------------------

	public function onKeyDown(code:KeyCode, mod:KeyModifier):Bool {
		return false;
	}

	public function onKeyUp(code:KeyCode, mod:KeyModifier):Bool {
		return false;
	}

	public function onMouseDown(x:Float, y:Float, button:MouseButton):Bool {
		return false;
	}

	public function onMouseUp(x:Float, y:Float, button:MouseButton):Bool {
		return false;
	}

	public function onMouseMove(x:Float, y:Float):Bool {
		return false;
	}

	public function onMouseWheel(x:Float, y:Float, mode:MouseWheelMode):Bool {
		return false;
	}
}