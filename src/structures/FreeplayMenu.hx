package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import elements.actor.sparrow.Actor;

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

	var curSelected(default, null):Int = 0;

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
		//Sys.println('Fuck you');
		display = disp;
	}

	function update(deltaTime:Float) {
		freeplayScreen.update(deltaTime);
	}

	function open() {
		Main.current.popupFreeplayMenu();
		//trace("Events removed");

		opened = active = true;

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);

			window.onMouseDown.add(mousePress);
			window.onMouseWheel.add(moveCategory_mouse);
		}, 1);

		freeplayScreen.addPrograms();

		/*try {
			throw("Freeplay menu opened");
		} catch (e) {
			trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));
		}*/
		trace("Freeplay menu opened");
	}

	function close() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseDown.remove(mousePress);
		window.onMouseWheel.remove(moveCategory_mouse);

		opened = false;

		haxe.Timer.delay(function() {
			var mm = Main.current.mainMenu;
			if (mm != null) {
				MainMenu.selectedAlpha = 1.0;
				mm.addEvents();
			}
		}, 1);

		trace("Freeplay menu closed");
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected++;
		if (curSelected >= freeplayScreen.songsAvailable.length) {
			curSelected = 0;
		}
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected--;
		if (curSelected < 0) {
			curSelected = freeplayScreen.songsAvailable.length - 1;
		}
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
		Sys.println('Song is loading now!');
		Main.songChosen = freeplayScreen.songsAvailable[curSelected].dir;
		Main.switchState(GAMEPLAY);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		//Sys.println("Fuck you game");
		if (button == LEFT) {
			enter(true, 0);
			return;
		}
		close();
	}

	function moveCategory_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		curSelected -= Math.floor(y);

		if (curSelected >= freeplayScreen.songsAvailable.length) {
			curSelected = 0;
		}
		if (curSelected < 0) {
			curSelected = freeplayScreen.songsAvailable.length - 1;
		}
	}

	function shutDown() {
		freeplayScreen.shutDown();

		active = false;
		Main.current.removeFreeplayMenu();
		Sys.println("Freeplay menu shut down");
	}

	function dispose() {
		close();
		shutDown();
	}
}
