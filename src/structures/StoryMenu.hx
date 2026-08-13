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

	function new() {
		persistent = true;
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;
	}

	override function update(deltaTime:Float) {}

	function open() {
		active = opened = true;
		Main.current.stateMachine.pushSubstate(this);
	}

	function close() {
		if (!opened)
			return;
		opened = false;
		Main.current.stateMachine.popSubstate();
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