package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import elements.actor.sparrow.Actor;
import data.chart.Header;

/**
	The freeplay submenu.
	This is where you can select the song you want to play.
	And this is the menu with the alphabet text that appears on the screen which scrolls by the mouse or the up or down key.
**/
@:publicFields
class FreeplayMenu {
	static var display(default, null):CustomDisplay;

	var active(default, null):Bool;
	var opened(default, null):Bool;

	static var songTextsBuf(default, null):Buffer<Actor>;
	static var songTextsProg(default, null):Program;

	var songsAvailable(default, null):Array<Header> = [];
	static var songTextChars(default, null):Array<Actor> = [];

	var curSelected(default, null):Int = 0;

	var actions(default, null):ActionMap;

	function new() {
		var songs:Array<String> = ["god-eater", "termination"];
		for (i in 0...songs.length) {
			var path = songs[i];
			songsAvailable.push(ChartSystem.parseHeader('assets/songs/$path'));

			var spr = new Actor(display, "alphabetText", 0, 0, 24, "", false);
			spr.playAnimation('', true);
			spr.x = 20;
			spr.y = 20 + (spr.h * i);
			spr.c.aF = 0.0;
			addAlphabetCharElement(spr);
		}

		actions = [
			Controls.Action.UI_LEFT => { action: left },
			Controls.Action.UI_RIGHT => { action: right },
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_BACK => { action: back },
			Controls.Action.UI_ACCEPT => { action: enter }
		];
	}

	private function addAlphabetCharElement(spr:Actor) {
		songTextChars.push(spr);
		songTextsBuf.addElement(spr);
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;

		if (songTextsBuf == null) {
			songTextsBuf = new Buffer<Actor>(26);
			songTextsProg = new Program(songTextsBuf);
			songTextsProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("alphabetSheet");
			TextureSystem.setTexture(songTextsProg, "alphabetSheet", "alphabetSheet");
		}
	}

	var alphaLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, Math.min(deltaTime * 0.015, 1.0));

		for (i in 0...songTextChars.length) {
			var char = songTextChars[i];
			var originalC = char.c;
			if (i == curSelected) char.c = Color.WHITE;
			else char.c = Color.GREY2;
			char.c.aF = alphaLerp;
			if (originalC != char.c) songTextsBuf.updateElement(char);
		}
	}

	function open() {
		active = opened = true;
		Main.current.popupFreeplayMenu();

		try {
			for (i in 0...songTextChars.length) {
				var char = songTextChars[i];
				if (i == curSelected) char.c = Color.WHITE;
				else char.c = Color.GREY2;
				char.c.aF = 0.0;
				songTextsBuf.addElement(char);
			}

			alphaLerp = 0.0;
		} catch (e) {}

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);
			
			window.onMouseDown.add(mousePress);
			window.onMouseWheel.add(moveCategory_mouse);
		}, 200);

		if (!songTextsProg.isIn(display)) {
			display.addProgram(songTextsProg);
		}
	}

	function close() {
		var mm = Main.current.mainMenu;

		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseDown.remove(mousePress);
		window.onMouseWheel.remove(moveCategory_mouse);

		if (mm != null) {
			MainMenu.selectedAlpha = 1.0;
			mm.addEvents();
		}

		opened = false;
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();
	}

	function down(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected++;
		if (curSelected >= songsAvailable.length) {
			curSelected = 0;
		}
	}

	function up(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected--;
		if (curSelected < 0) {
			curSelected = songsAvailable.length - 1;
		}
	}

	function left(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected = 0;
		curSelected--;
		if (curSelected < 0) {
			curSelected = songsAvailable.length - 1;
		}
	}

	function right(isDown:Bool, param:Int) {
		if (!isDown) return;
		curSelected = 0;
		curSelected++;
		if (curSelected >= songsAvailable.length) {
			curSelected = 0;
		}
	}

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
		Main.songChosen = songsAvailable[curSelected].dir;
		Main.switchState(GAMEPLAY);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		var window = Main.current.fakeWindow;
		var mouseInside = !window.isMouseInsideApp();
		if (button == LEFT && mouseInside) enter(true, 0);
		if (button != RIGHT || mouseInside) return;
		close();
	}

	function moveCategory_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		var window = Main.current.fakeWindow;
		if (!window.isMouseInsideApp()) return;

		curSelected -= Math.floor(y);

		if (curSelected >= songsAvailable.length) {
			curSelected = 0;
		}
		if (curSelected < 0) {
			curSelected = songsAvailable.length - 1;
		}
	}

	function shutDown() {
		if (!songTextsProg.isIn(display)) return;

		for (i in 0...songTextChars.length) {
			var char = songTextChars[i];
			char.c.aF = 0.0;
			songTextsBuf.removeElement(char);
		}

		display.color = 0x00000000;
		display.removeProgram(songTextsProg);

		active = false;
	}

	function dispose() {
		close();
		shutDown();

		if (opened) {
			while (songTextChars.length != 0) {
				var char = songTextChars.pop();
				songTextsBuf.removeElement(char);
				char = null;
			}
		}
	}
}