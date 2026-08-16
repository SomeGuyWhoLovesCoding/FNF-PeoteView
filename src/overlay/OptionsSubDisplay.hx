package overlay;

import lime.ui.MouseButton;
import overlay.AlphabetScrollHost;

/**
	Common base for the per-category sub-displays inside the options menu.
	Mouse events are routed here by `OptionsMenu` (the single machine focus),
	replacing the previous per-display direct window listener registration.
	@since Development
**/
@:publicFields
class OptionsSubDisplay extends AlphabetScrollHost {
	function update(deltaTime:Float):Void {}

	public function onMouseDown(x:Float, y:Float, button:MouseButton):Bool {
		return false;
	}

	public function onMouseUp(x:Float, y:Float, button:MouseButton):Bool {
		return false;
	}

	public function onMouseMove(x:Float, y:Float):Bool {
		return false;
	}
}