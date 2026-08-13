package structures.options;

import lime.ui.MouseButton;

/**
	Implemented by the options sub-displays that own mouse interaction
	(drag-to-scroll lists). The OptionsMenu forwards routed mouse events to
	the host of the currently active category; nothing registers raw window
	listeners anymore.
**/
interface OptionsInputHost {
	function mousePress(x:Float, y:Float, button:MouseButton):Void;
	function mouseRelease(x:Float, y:Float, button:MouseButton):Void;
	function mouseDrag(x:Float, y:Float):Void;
}