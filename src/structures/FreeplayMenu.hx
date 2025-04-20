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
	static var songTextCharGroup(default, null):Array<Array<Actor>> = [];

	var curSelected(default, null):Int = 0;

	var actions(default, null):ActionMap;

	function new() {
		var songs:Array<String> = ["assets/songs/god-eater", "assets/songs/termination", "assets/songs/spam", "assets/songs/unpredictable-6",
		"assets/songs/god-eater", "assets/songs/termination", "assets/songs/spam", "assets/songs/unpredictable-6",
		"assets/songs/god-eater", "assets/songs/termination", "assets/songs/spam", "assets/songs/unpredictable-6",
		"assets/songs/god-eater", "assets/songs/termination", "assets/songs/spam", "assets/songs/unpredictable-6"];

		songTextCharGroup = [
			for (i in 0...8) [
				for (i in 0...20) {
					var spr = new Actor(display, "alphabetText", 0, 0, 24, "", false);
					spr.c.aF = 0.0;
					addAlphabetCharElement(spr);
					spr;
				}
			]
		];

		for (i in 0...songs.length) {
			var path = songs[i];

			var header = ChartSystem.parseHeader(path);
			songsAvailable.push(header);
		}

		actions = [
			Controls.Action.UI_UP => { action: up },
			Controls.Action.UI_DOWN => { action: down },
			Controls.Action.UI_BACK => { action: back },
			Controls.Action.UI_ACCEPT => { action: enter }
		];
	}

	private function addAlphabetCharElement(spr:Actor) {
		songTextsBuf.addElement(spr);
	}

	static function init(disp:CustomDisplay):Void {
		display = disp;

		if (songTextsBuf == null) {
			songTextsBuf = new Buffer<Actor>(256, 64, false);
			songTextsProg = new Program(songTextsBuf);
			songTextsProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("alphabetSheet");
			TextureSystem.setTexture(songTextsProg, "alphabetSheet", "alphabetSheet");
		}
	}

	var alphaLerp:Float = 0.0;
	var yLerp:Float = 0.0;
	var xLerp:Float = 0.0;

	function update(deltaTime:Float) {
		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, Math.min(deltaTime * 0.015, 1.0));
		yLerp = Tools.lerp(yLerp, -curSelected * 112, Math.min(deltaTime * 0.015, 1.0));
		xLerp = Tools.lerp(xLerp, 90 - (curSelected * 32), Math.min(deltaTime * 0.015, 1.0));

		var startSelected = curSelected - 8;
		if (startSelected < 0) {
			startSelected = 0;
		}

		var endSelected = 8;
		if (startSelected >= 8) {
			endSelected = startSelected;
		}

		for (i in startSelected...endSelected) {
			var song = songsAvailable[i];
			var title = song.title;

			var x:Float = 45;

			for (j in 0...20) {
				if (j >= title.length) {
					break;
				}

				var char = title.charAt(j).toLowerCase();

				switch (char)
				{
					case '?':
						char = 'question';
					case '&':
						char = 'ampersand';
					case '<':
						char = 'less';
					case '"':
						char = 'quote';
					case ' ':
						x += 20;
						continue;
				}

				if (i >= 17) char = '.';

				var spr = songTextCharGroup[i][j];
				spr.playAnimation('$char bold instance 1', true);
				spr.x = (x + 50) + (xLerp + (32 * i));
				spr.y = yLerp + (112 * i) + 360;

				switch (char)
				{
					case "'" | '“' | '”' | '*' | '^' | '"' | '-':
						spr.y += spr.h;
					case '+':
						spr.y += spr.h * .25;
				}

				spr.c.aF = (i == curSelected ? 1 : 0.5) * alphaLerp;
				songTextsBuf.updateElement(spr);

				x += spr.w + 2;
			}
		}
	}

	function open() {
		active = opened = true;
		Main.current.popupFreeplayMenu();

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

	function enter(isDown:Bool, param:Int) {
		if (!isDown) return;
		Main.songChosen = songsAvailable[curSelected].dir;
		Main.switchState(GAMEPLAY);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		var window = Main.current.fakeWindow;
		var mouseInside = window.isMouseInsideApp();
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

		display.color = 0x00000000;
		display.removeProgram(songTextsProg);

		active = false;
	}

	function dispose() {
		close();
		shutDown();
	}
}