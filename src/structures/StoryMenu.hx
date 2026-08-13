package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;

@:publicFields
class StoryMenu extends GameState {
	static var display(default, null):CustomDisplay;

	var chaptersAvailable(default, null):Array<Int> = [];

	var active(default, null):Bool;
	var opened(default, null):Bool;

	var nav(default, null):Navigation = new Navigation();

	var popRequested:Bool = false;

	function new() {
		persistent = true;
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;
	}

	override function update(deltaTime:Float) {
		// Same contract as the other menus: close() only flips `opened`;
		// the state pops itself on the first update after closing.
		if (!opened && !popRequested) {
			popRequested = true;
			Main.current.stateMachine.popSubstate();
		}
	}

	function open() {
		active = opened = true;
		popRequested = false;
		Main.current.stateMachine.pushSubstate(this);
	}

	function close() {
		if (!opened)
			return;
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

	override function dispose() {
		super.dispose();
	}
}