package menus;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.KeyModifier;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import handler.MenuInput;

@:publicFields
class StoryMenu extends MenuInput {
	static var display(default, null):CustomDisplay;

	var chaptersAvailable(default, null):Array<Int> = [];

	var nav(default, null):Navigation = new Navigation();

	function new() {
		actions = [
			Controls.Action.UI_UP => {action: up},
			Controls.Action.UI_DOWN => {action: down},
			Controls.Action.UI_BACK => {action: back},
			Controls.Action.UI_ACCEPT => {action: enter}
		];
		mode = ControlsMode.STORY;
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;
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
}