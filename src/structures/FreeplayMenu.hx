package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;

/**
	The freeplay submenu.
	This is where you can select the song you want to play.
	And this is the menu with the alphabet text that appears on the screen which scrolls by the mouse or the up or down key.
	It is responsible for rendering the freeplay menu and updating it based on the player's input.
	@since Development
**/
@:publicFields
class FreeplayMenu {
	static var display(default, null):CustomDisplay;

	var active(default, null):Bool;
	var opened(default, null):Bool;

	var freeplayScreen(default, null):FreeplayScreen;

	var nav(default, null):Navigation = new Navigation();

	var actions(default, null):ActionMap;

	function new() {
		freeplayScreen = new FreeplayScreen(this, 'chapter1');

		actions = [
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_BACK => { action: back },
			Controls.Action.UI_ACCEPT => { action: enter }
		];
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;
	}

	function render(deltaTime:Float) {
		freeplayScreen.render(deltaTime);
	}

	function open() {
		Main.current.popupFreeplayMenu();

		opened = active = true;

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);

			Main.current.mouseDown = mousePress;
			window.onMouseWheel.add(moveMouse);
		}, 1);

		if (freeplayScreen.disposed) {
			freeplayScreen.reload(freeplayScreen.chapter);
		}
		freeplayScreen.addPrograms();
	}

	function reload(newChapter:String) {
		nav.reset();
		freeplayScreen.reload(newChapter);
	}

	function close() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		Main.current.mouseDown = null;
		window.onMouseWheel.remove(moveMouse);

		opened = false;

		haxe.Timer.delay(function() {
			var mm = Main.current.mainMenu;
			if (mm != null) {
				MainMenu.selectedAlpha = 1.0;
				mm.addEvents();
			}
		}, 1);
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();
		Main.current.playCancelSound();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		nav.scroll(1);
		nav.resetIfOver(freeplayScreen.songsAvailable.length);
		Main.current.playScrollSound();
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		nav.scroll(-1);
		nav.resetIfUnder(freeplayScreen.songsAvailable.length - 1);
		Main.current.playScrollSound();
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
		Main.songChosen = freeplayScreen.songsAvailable[nav.value()].dir;
		Main.switchState(GAMEPLAY);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		switch (button) {
			case LEFT:
				enter(true, 0);
			case RIGHT:
				back(true, 0);
			default:
		}
	}

	function moveMouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		nav.scroll(-Math.floor(y));
		nav.resetIfBoth(freeplayScreen.songsAvailable.length, freeplayScreen.songsAvailable.length - 1);
		Main.current.playScrollSound();
	}

	function shutDown() {
		freeplayScreen.shutDown();

		active = false;
		Main.current.removeFreeplayMenu();
	}

	function dispose() {
		close();
		freeplayScreen.unload();

		active = false;
		Main.current.removeFreeplayMenu();
	}
}
