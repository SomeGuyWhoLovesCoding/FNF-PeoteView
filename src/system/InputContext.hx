package system;

import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	A single screen's claim on the global input events.
	Each optional field, when set, is a handler for that event type.
	`InputRouter` binds the window events exactly once and forwards each event
	to the topmost context that has a handler for it, so screens register by
	`push()`/`pop()` instead of adding/removing listeners on the window.
**/
class InputContext {
	public var keyDown:KeyCode->KeyModifier->Void;
	public var keyUp:KeyCode->KeyModifier->Void;
	public var mouseDown:Float->Float->MouseButton->Void;
	public var mouseUp:Float->Float->MouseButton->Void;
	public var mouseMove:Float->Float->Void;
	public var mouseWheel:Float->Float->MouseWheelMode->Void;

	public function new() {}
}