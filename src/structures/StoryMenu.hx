package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import elements.actor.sparrow.Actor;

@:publicFields
class StoryMenu {
	static var display(default, null):CustomDisplay;

	var chaptersAvailable(default, null):Array<Int> = [];

	var active(default, null):Bool;
	var opened(default, null):Bool;

	var curSelected(default, null):Int = 0;

	function new() {
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;
	}

	function update(deltaTime:Float) {
	}

	function open() {
		active = opened = true;
	}

	function close() {
		opened = false;
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected++;
		if (curSelected >= chaptersAvailable.length) {
			curSelected = 0;
		}
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected--;
		if (curSelected < 0) {
			curSelected = chaptersAvailable.length - 1;
		}
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
	}

	function shutDown() {
		active = false;
	}

	function dispose() {
	}
}