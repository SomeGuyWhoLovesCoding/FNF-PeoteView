package structures;

import input2action.ActionMap;
import lime.ui.KeyCode;
import lime.ui.MouseButton;
import lime.ui.MouseWheelMode;
import elements.actor.sparrow.Actor;
import data.chart.Header;
import data.gameplay.ChapterData.ChapterSong;

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

	static var songTextsBuf(default, null):Buffer<Actor>;
	static var songTextsProg(default, null):Program;

	static var songIconsBuf(default, null):Buffer<HealthBarSprite>;
	static var songIconsProg(default, null):Program;

	var songsAvailable(default, null):Array<ChapterSong> = [];
	static var songTextCharGroup(default, null):Array<Array<Actor>> = [];
	static var songIconGroup(default, null):Array<HealthBarSprite> = [];

	var curSelected(default, null):Int = 0;
	var alreadySelected:Bool = false;

	var actions(default, null):ActionMap;

	function new() {
		var chapterData:ChapterData = haxe.Json.parse(sys.io.File.getContent("assets/data/chapters/chapter1/data.json"));
		var songs:Array<ChapterSong> = chapterData.songs;

		for (i in 0...songs.length) {
			var song = songs[i];
			songsAvailable.push(song);
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
			songTextsBuf = new Buffer<Actor>(32, 32, false);
			songTextsProg = new Program(songTextsBuf);
			songTextsProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("alphabetSheet");
			TextureSystem.setTexture(songTextsProg, "alphabetSheet", "alphabetSheet");
		}

		if (songIconsBuf == null) {
			songIconsBuf = new Buffer<HealthBarSprite>(32, 32, false);
			songIconsProg = new Program(songIconsBuf);
			songIconsProg.blendEnabled = true;

			var tex = TextureSystem.getTexture("hbTex");
			HealthBarSprite.init(songIconsProg, "hbTex", tex);
		}

		songTextCharGroup = [
			for (i in 0...7) [
				for (i in 0...20) {
					var spr = new Actor(display, "alphabetText", 0, 0, 24, "", false);
					spr.c.aF = 0.0;
					songTextsBuf.addElement(spr);
					spr;
				}
			]
		];

		songIconGroup = [
			for (i in 0...7) {
				var icon = new HealthBarSprite();
				icon.type = HEALTH_ICON;
				icon.c.aF = 0.0;
				songIconsBuf.addElement(icon);
				icon;
			}
		];
	}

	var alphaLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var xLerp:Float = 0.0;
	var xLerpPrev:Float = 0.0;

	function update(deltaTime:Float) {
		var ratio = Math.min(deltaTime * 0.015, 1);
		if (ratio == 1) ratio = (1/lime.app.Application.current.window.frameRate) * 0.015; // When loading the freeplay menu the first time it gets stuck at 1.0 for a single frame

		//Sys.println('$ratio, $alphaLerp');
		if (!opened && alphaLerp < 0.1/256) {
			shutDown();
			curSelectedLerp = curSelected;
			xLerp = 20 - (curSelected * 20);
			xLerpPrev = xLerp;
			alphaLerp = 0.0;
			return;
		}

		alphaLerp = Tools.lerp(alphaLerp, opened ? 1.0 : 0.0, ratio);
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelected, ratio);
		xLerp = Tools.lerp(xLerp, 20 - (curSelected * 20), ratio);

		var incrementBest = Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 7));

		for (i in 0...7) {
			if (songsAvailable.length <= 7 && i <= songsAvailable.length) continue;

			var k = i + incrementBest;
			var l = curSelected - incrementBest;
			var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
			var song = songsAvailable[kClamped];
			var title = song.title;
			var grp = songTextCharGroup[i];

			var x:Float = 20;
			var iconX:Float = 0.0;

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

				if (spr.frameIndex == 0) {
					spr.playAnimation('$char bold instance 1', true);
				}

				if (Math.floor(xLerp) != Math.floor(xLerpPrev) || firstFrameToAnimate) {
					var ogFrameIndex = spr.frameIndex;
					var ogFrameTime = spr.frameTimeRemaining;
					spr.playAnimation('$char bold instance 1', true);
					spr.frameIndex = ogFrameIndex;
					spr.frameTimeRemaining = ogFrameTime;
					firstFrameToAnimate = false;
				}

				spr.x = (x + 50) + (xLerp + (20 * k));
				spr.y = (-curSelectedLerp * 156) + (156 * k) + 320;

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

				spr.c.aF = isInvalidCharacter ? 0.0 : (i == l ? 1.0 : 0.5) * alphaLerp;
				songTextsBuf.updateElement(spr);
				spr.update(deltaTime);

				if (j == title.length - 1) {
					iconX = spr.x;
				}

				x += spr.firstFrameWidth + 2;
			}

			var icon = songIconGroup[i];
			icon.changeID(Tools.fromIconGridXMLCharacter(song.icon)[0]);
			icon.c.aF = (i == l ? 1.0 : 0.5) * alphaLerp;
			icon.x = iconX + ((icon.w * 0.35) + 12);
			icon.y = ((-curSelectedLerp * 156) + (156 * k) + 320) - 30; // https://github.com/ShadowMario/FNF-PsychEngine/blob/main/source/objects/HealthIcon.hx#L22
			songIconsBuf.updateElement(icon);
		}

		xLerpPrev = xLerp;
	}

	function open() {
		Main.current.popupFreeplayMenu();

		opened = active = true;
		alphaLerp = 0.0;

		haxe.Timer.delay(() -> {
			var window = lime.app.Application.current.window;
			Main.current.controls.bindTo(actions);
			
			window.onMouseDown.add(mousePress);
			window.onMouseWheel.add(moveCategory_mouse);
		}, 1);

		if (!songTextsProg.isIn(display)) {
			display.addProgram(songTextsProg);
		}

		if (!songIconsProg.isIn(display)) {
			display.addProgram(songIconsProg);
		}

		Sys.println("Freeplay menu opened");
	}

	function close() {
		var window = lime.app.Application.current.window;
		Main.current.controls.unBind();
		window.onMouseDown.remove(mousePress);
		window.onMouseWheel.remove(moveCategory_mouse);

		opened = false;

		Sys.println("Freeplay menu closed");
	}

	function back(isDown:Bool, param:Int) {
		if (!isDown) return;
		close();

		var mm = Main.current.mainMenu;
		if (mm != null) {
			MainMenu.selectedAlpha = 1.0;
			mm.addEvents();
		}
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
		if (!isDown || alreadySelected) return;
		Main.songChosen = songsAvailable[curSelected].dir;
		alreadySelected = true;
		Main.switchState(GAMEPLAY);
	}

	function mousePress(x:Float = 0.0, y:Float = 0.0, button:MouseButton) {
		if (alreadySelected) return;
		if (button == LEFT) {
			enter(true, 0);
			alreadySelected = true;
		}
		if (button != RIGHT) return;
		close();

		var mm = Main.current.mainMenu;
		if (mm != null) {
			MainMenu.selectedAlpha = 1.0;
			mm.addEvents();
		}
	}

	function moveCategory_mouse(x:Float, y:Float, mouseWheelMode:MouseWheelMode) {
		curSelected -= Math.floor(y);

		if (curSelected >= songsAvailable.length) {
			curSelected = 0;
		}
		if (curSelected < 0) {
			curSelected = songsAvailable.length - 1;
		}
	}

	function shutDown() {
		//if (!songTextsProg.isIn(display) || !songIconsProg.isIn(display)) return;

		display.color = 0x00000000;
		display.removeProgram(songTextsProg);
		display.removeProgram(songIconsProg);

		active = false;
		firstFrameToAnimate = true;
		Main.current.removeFreeplayMenu();
		Sys.println("Freeplay menu shut down");
	}

	function dispose() {
		close();
		shutDown();
	}

	var firstFrameToAnimate:Bool = true;
}
