package system;

import lime.ui.Window;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import data.gameplay.Controls;

/**
	Central state machine.

	It owns the *only* window input listeners in the app (registered once at
	boot and never added/removed again, which removes the class of crashes
	caused by mutating Lime's listener arrays while Lime is dispatching).

	All state transitions (`switchState`, `pushSubstate`, `popSubstate`) are
	queued and applied at the start of the next frame. This makes them safe
	to request from inside an input handler or an update loop, and removes
	the old `haxe.Timer.delay(1)` "get off the dispatch stack" hacks.

	The active input chain is the topmost substate first, then the current
	state. Every handler is wrapped in try/catch so a single broken handler
	logs its error instead of taking down the whole app.

	input2action bindings are derived from the stack: the topmost substate's
	`actions` are bound, falling back to the current state's. States never
	bind or unbind themselves.
**/
@:publicFields
class StateMachine {
	public var current(default, null):GameState;
	public var substates(default, null):Array<GameState> = [];

	static inline var MAX_QUEUED_COMMANDS = 64;

	var controls:Controls;
	var queue:Array<Void->Void> = [];

	public function new(controls:Controls) {
		this.controls = controls;
	}

	/**
		Registers the machine's window listeners. Called exactly once at boot.
		Never call this again; listeners are never removed.
	**/
	public function init(window:Window) {
		#if !android
		window.onKeyDown.add(onKeyDown);
		window.onKeyUp.add(onKeyUp);
		window.onMouseDown.add(onMouseDown);
		window.onMouseUp.add(onMouseUp);
		window.onMouseMove.add(onMouseMove);
		window.onMouseWheel.add(onMouseWheel);
		#end
	}

	// ---------------------------------------------------------------
	// Queued commands — safe to call from anywhere, applied next frame.
	// ---------------------------------------------------------------

	public function switchState(state:GameState) {
		if (state == null)
			return;
		queue.push(() -> doSwitch(state));
	}

	public function pushSubstate(state:GameState) {
		if (state == null)
			return;
		queue.push(() -> doPush(state));
	}

	public function popSubstate() {
		queue.push(doPop);
	}

	// ---------------------------------------------------------------
	// Frame loop
	// ---------------------------------------------------------------

	public function update(deltaTime:Float) {
		drainQueue();

		if (current != null && !current.disposed)
			safe(() -> current.update(deltaTime));

		for (sub in substates)
			if (sub != null && !sub.disposed)
				safe(() -> sub.update(deltaTime));
	}

	public function render(deltaTime:Float) {
		if (current != null && !current.disposed)
			safe(() -> current.render(deltaTime));

		for (sub in substates)
			if (sub != null && !sub.disposed)
				safe(() -> sub.render(deltaTime));
	}

	// ---------------------------------------------------------------
	// Command execution
	// ---------------------------------------------------------------

	function drainQueue() {
		var processed = 0;
		while (queue.length > 0) {
			var command = queue.shift();
			safe(command);
			if (++processed > MAX_QUEUED_COMMANDS) {
				Sys.println('[ StateMachine ] Queue overflow — ${queue.length} commands dropped');
				queue = [];
				break;
			}
		}
	}

	function doSwitch(state:GameState) {
		if (state == null || state == current)
			return;

		if (current != null) {
			safe(() -> current.dispose());
			current = null;
		}

		// Tear down the whole substate stack. Persistent singletons (menus)
		// are popped without disposal — they get reused later.
		while (substates.length > 0) {
			var sub = substates.pop();
			if (sub != null && !sub.persistent)
				safe(() -> sub.dispose());
		}

		current = state;
		safe(() -> current.create());
		rebind();
		TextureSystem.processQueue();
	}

	function doPush(state:GameState) {
		if (state == null || substates.indexOf(state) != -1 || state == current)
			return;

		substates.push(state);
		safe(() -> state.create());
		rebind();
	}

	function doPop() {
		if (substates.length == 0)
			return;

		var sub = substates.pop();
		if (sub != null && !sub.persistent)
			safe(() -> sub.dispose());
		rebind();

		var parent = substates.length > 0 ? substates[substates.length - 1] : current;
		if (parent != null && !parent.disposed && sub != null)
			safe(() -> parent.onSubstateClosed(sub));
	}

	// ---------------------------------------------------------------
	// Input dispatch — topmost substate first, then the current state.
	// ---------------------------------------------------------------

	function onKeyDown(code:KeyCode, mod:KeyModifier):Bool {
		for (i in substates.length - 1...-1) {
			var sub = substates[i];
			if (sub != null && !sub.disposed && safeBool(() -> sub.onKeyDown(code, mod)))
				return true;
		}
		if (current != null && !current.disposed)
			return safeBool(() -> current.onKeyDown(code, mod));
		return false;
	}

	function onKeyUp(code:KeyCode, mod:KeyModifier):Bool {
		for (i in substates.length - 1...-1) {
			var sub = substates[i];
			if (sub != null && !sub.disposed && safeBool(() -> sub.onKeyUp(code, mod)))
				return true;
		}
		if (current != null && !current.disposed)
			return safeBool(() -> current.onKeyUp(code, mod));
		return false;
	}

	function onMouseDown(x:Float, y:Float, button:MouseButton):Bool {
		for (i in substates.length - 1...-1) {
			var sub = substates[i];
			if (sub != null && !sub.disposed && safeBool(() -> sub.onMouseDown(x, y, button)))
				return true;
		}
		if (current != null && !current.disposed)
			return safeBool(() -> current.onMouseDown(x, y, button));
		return false;
	}

	function onMouseUp(x:Float, y:Float, button:MouseButton):Bool {
		for (i in substates.length - 1...-1) {
			var sub = substates[i];
			if (sub != null && !sub.disposed && safeBool(() -> sub.onMouseUp(x, y, button)))
				return true;
		}
		if (current != null && !current.disposed)
			return safeBool(() -> current.onMouseUp(x, y, button));
		return false;
	}

	function onMouseMove(x:Float, y:Float):Bool {
		for (i in substates.length - 1...-1) {
			var sub = substates[i];
			if (sub != null && !sub.disposed && safeBool(() -> sub.onMouseMove(x, y)))
				return true;
		}
		if (current != null && !current.disposed)
			return safeBool(() -> current.onMouseMove(x, y));
		return false;
	}

	function onMouseWheel(x:Float, y:Float, mode:MouseWheelMode):Bool {
		for (i in substates.length - 1...-1) {
			var sub = substates[i];
			if (sub != null && !sub.disposed && safeBool(() -> sub.onMouseWheel(x, y, mode)))
				return true;
		}
		if (current != null && !current.disposed)
			return safeBool(() -> current.onMouseWheel(x, y, mode));
		return false;
	}

	// ---------------------------------------------------------------
	// Binding — always reflects the top of the stack.
	// ---------------------------------------------------------------

	function rebind() {
		var target = substates.length > 0 ? substates[substates.length - 1] : current;
		if (target != null && target.actions != null) {
			controls.bindTo(target.actions);
		} else {
			controls.unBind();
		}
	}

	// ---------------------------------------------------------------
	// Error containment — a broken handler logs, never crashes.
	// ---------------------------------------------------------------

	function safe(fn:Void->Void) {
		try {
			fn();
		} catch (e) {
			Sys.println('[ StateMachine ] Uncaught error: $e');
			Sys.println(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
		}
	}

	function safeBool(fn:Void->Bool):Bool {
		try {
			return fn();
		} catch (e) {
			Sys.println('[ StateMachine ] Uncaught error: $e');
			Sys.println(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
			return false;
		}
	}
}