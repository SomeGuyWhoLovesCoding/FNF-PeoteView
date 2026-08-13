package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import system.MenuInput;

@:publicFields
class StoryMenu implements MenuInput {
	static var display(default, null):CustomDisplay;

	var chaptersAvailable(default, null):Array<Int> = [];

	var active(default, null):Bool;
	var opened(default, null):Bool;

	var nav(default, null):Navigation = new Navigation();

	var actions(default, null):ActionMap;

	function new() {}

	static function init(disp:CustomDisplay):Void {
		display = disp;
	}

	function update(deltaTime:Float) {}

	function open() {
		active = opened = true;
	}

	function close() {
		opened = false;
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown)
			return;
		close();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown)
			return;
		nav.scroll(1);
		nav.resetIfOver(chaptersAvailable.length);
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown)
			return;
		nav.scroll(-1);
		nav.resetIfUnder(chaptersAvailable.length - 1);
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown)
			return;
	}

	function shutDown() {
		active = false;
	}

	function dispose() {}

	// --- Routed input (MenuInput) ---

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