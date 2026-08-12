package system;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import lime.ui.Window;

/**
	Singleton owner of every window input event.

	This replaces the old compromise where menus/screens each added and removed
	their own handlers on `window.onMouseDown` / `window.onMouseUp` and the
	singleton `Main.mouseDown` slot. That pattern was the source of the silent
	menus crashes: a screen mutating lime's listener array (`.remove()`) while
	lime was iterating it during dispatch.

	The router binds the six window events exactly once at startup and *never*
	removes them. Screens instead push an `InputContext` when they open and
	pop it when they close. Dispatch walks the context stack top-down and hands
	the event to the first context that has a handler for it, then stops.
**/
class InputRouter {
	var window:Window;
	var contexts:Array<InputContext> = [];

	public function new(window:Window) {
		this.window = window;

		window.onKeyDown.add((code, mod) -> dispatch(ctx -> ctx.keyDown != null, ctx -> ctx.keyDown(code, mod)));
		window.onKeyUp.add((code, mod) -> dispatch(ctx -> ctx.keyUp != null, ctx -> ctx.keyUp(code, mod)));
		window.onMouseDown.add((x, y, button) -> dispatch(ctx -> ctx.mouseDown != null, ctx -> ctx.mouseDown(x, y, button)));
		window.onMouseUp.add((x, y, button) -> dispatch(ctx -> ctx.mouseUp != null, ctx -> ctx.mouseUp(x, y, (button : MouseButton))));
		window.onMouseMove.add((x, y) -> dispatch(ctx -> ctx.mouseMove != null, ctx -> ctx.mouseMove(x, y)));
		window.onMouseWheel.add((x, y, mode) -> dispatch(ctx -> ctx.mouseWheel != null, ctx -> ctx.mouseWheel(x, y, mode)));
	}

	/** Register a context. Safe to call repeatedly; a context is only stored once. */
	public function push(context:InputContext):Void {
		if (context == null)
			return;
		if (contexts.indexOf(context) == -1)
			contexts.push(context);
	}

	/** Unregister a context. Safe to call at any time, even during a dispatch. */
	public function pop(context:InputContext):Void {
		if (context == null)
			return;
		contexts.remove(context);
	}

	function dispatch(hasHandler:InputContext->Bool, call:Dynamic):Void {
		// iterate a snapshot so a handler may freely push/pop contexts mid-dispatch
		var snap = contexts.copy();
		for (i in snap.length - 1 ... -1) {
			var ctx = snap[i];
			if (hasHandler(ctx)) {
				call(ctx);
				return;
			}
		}
	}
}