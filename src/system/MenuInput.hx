package system;

import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import input2action.ActionMap;

interface MenuInput {
	var actions(default, null):ActionMap;

	function onKeyDown(key:KeyCode, modifier:KeyModifier):Bool;
	function onKeyUp(key:KeyCode, modifier:KeyModifier):Bool;
	function onMouseDown(x:Float, y:Float, button:MouseButton):Bool;
	function onMouseUp(x:Float, y:Float, button:MouseButton):Bool;
	function onMouseMove(x:Float, y:Float):Bool;
	function onMouseWheel(deltaX:Float, deltaY:Float, mode:MouseWheelMode):Bool;
}