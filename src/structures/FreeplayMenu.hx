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
		var songs:Array<String> = [for (i in 0...200) "assets/songs/god-eater"];

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

	static function init(disp:CustomDisplay):Void {
		display = disp;

		if (songTextsBuf == null) {
			songTextsBuf = new Buffer<Actor>(256, 64, false);
			songTextsProg = new Program(songTextsBuf);
			songTextsProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("alphabetSheet");
			TextureSystem.setTexture(songTextsProg, "alphabetSheet", "alphabetSheet");
		}

		songTextCharGroup = [
			for (i in 0...8) [
				for (i in 0...20) {
					var spr = new Actor(display, "alphabetText", 0, 0, 24, "", false);
					spr.playAnimation('a bold instance 1', true);
					spr.c.aF = 0.0;
					songTextsBuf.addElement(spr);
					spr;
				}
			]
		];
	}

	var alphaLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var xLerp:Float = 0.0;

	var alphaLerpWontBeZeroWhenLaunchingFreeplayForTheFirstTime:Bool; // This is a flag to check if the alphaLerp is 0.0 when launching freeplay for the first time. Cuz fuck you.

	function update(deltaTime:Float) {
		var ratio = Math.min(deltaTime * 0.015, 1.0);

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, ratio);

		if (!alphaLerpWontBeZeroWhenLaunchingFreeplayForTheFirstTime && alphaLerp != 0.0) {
			alphaLerpWontBeZeroWhenLaunchingFreeplayForTheFirstTime = true;
			alphaLerp = 0.0;
		}

		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelected, ratio);
		xLerp = Tools.lerp(xLerp, 30 - (curSelected * 24), ratio);

		if (!opened && alphaLerp == 0.0) {
			shutDown();
			return;
		}

		var incrementBest = Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 8));

		for (i in 0...8) {
			var k = i + incrementBest;
			var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
			var song = songsAvailable[kClamped];
			var title = song.title;
			var grp = songTextCharGroup[i];

			var x:Float = 45;

			for (j in 0...20) {
				var char = title.charAt(j).toLowerCase();

				var isInvalidCharacter = j >= title.length || char == ' ';

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
					case "'":
						char = 'apostrophe';
					case '•':
						char = 'bullet';
					case ',':
						char = 'comma';
					case '!':
						char = 'exclamation';
					case '/':
						char = 'forward slash';
					case '\\':
						char = 'back slash';
					case '¿':
						char = 'inverted question';
					case '¡':
						char = 'inverted exclamation';
					case '.':
						char = 'period';
					case "“":
						char = 'start quote';
					case ' ':
						char = '_'; // NOTE: This is space for a reason, and it's hidden. If the sprite wasn't even created for it, the pooling won't even run correctly.
				}

				if (j >= 17) char = '.';

				var spr = grp[j];
				spr.playAnimation('$char bold instance 1', true, false);
				spr.x = (x + 50) + (xLerp + (24 * k));
				spr.y = (-curSelectedLerp * 130) + (130 * k) + 320;

				switch (char)
				{
					case '-':
						spr.y += spr.h;
					case 'comma':
						spr.y += 47;
					case '_':
						spr.y += 46;
					case '+':
						spr.y += spr.h * .25;
				}

				spr.c.aF = isInvalidCharacter ? 0.0 : (i == (curSelected - incrementBest) ? 1.0 : 0.5) * alphaLerp;
				songTextsBuf.updateElement(spr);

				x += spr.w + 2;
			}
		}
	}

	function open() {
		Main.current.popupFreeplayMenu();

		active = opened = true;

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);
			
			window.onMouseDown.add(mousePress);
			window.onMouseWheel.add(moveCategory_mouse);
		}, 1);

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