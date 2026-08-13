package system;

import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import input2action.ActionMap;

/**
	Base class for every menu/state object that can receive routed input.
	Provides the shared `actions`, `active`, `opened` and `disposed` state plus
	default no-op lifecycle and input handlers. Subclasses override what they need.
	@since Development
**/
@:publicFields
class MenuInput {
	var actions(default, null):ActionMap;
	var active(default, null):Bool = false;
	var opened(default, null):Bool = false;
	var disposed(default, null):Bool = false;

	function update(deltaTime:Float) {}

	function render(deltaTime:Float) {}

	function open() {
		opened = active = true;
	}

	function close() {
		opened = false;
	}

	function shutDown() {
		active = false;
	}

	function dispose() {
		disposed = true;
	}

	public function onKeyDown(key:KeyCode, modifier:KeyModifier):Bool {
		return false;
	}

	public function onKeyUp(key:KeyCode, modifier:KeyModifier):Bool {
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

	public function onMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode):Bool {
		return false;
	}
}