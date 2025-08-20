package structures;

import data.gameplay.ChapterData.ChapterSong;

/**
	The freeplay submenu's screen.
	This exists due to an architectural change on the original `FreeplayMenu` code and is where the song text and selection go.
	@since Development
**/
@:publicFields
class FreeplayScreen {
	private static var display(get, never):CustomDisplay;

	inline private static function get_display() {
		return FreeplayMenu.display;
	}

	static var songTextsBuf(default, null):Buffer<Actor>;
	static var songTextsProg(default, null):Program;

	static var songIconsBuf(default, null):Buffer<HealthBarSprite>;
	static var songIconsProg(default, null):Program;

	var songsAvailable(default, null):Array<ChapterSong> = [];
	static var songTextCharGroup(default, null):Array<Array<Actor>> = [];
	static var songIconGroup(default, null):Array<HealthBarSprite> = [];

    var parent(default, null):FreeplayMenu;

    function new(parent:FreeplayMenu, chapterName:String) {
        this.parent = parent;
        reload(chapterName);
    }

    function reload(chapterName:String) {
        var chapterData:ChapterData = haxe.Json.parse(sys.io.File.getContent("assets/data/chapters/chapter1/data.json"));
		var songs:Array<ChapterSong> = chapterData.songs;

        while (songsAvailable.length != 0) songsAvailable.pop();

		for (i in 0...songs.length) {
			var song = songs[i];
			songsAvailable.push(song);
		}
    
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

	var firstFrameToAnimate:Bool = true;

	function update(deltaTime:Float) {
		if (parent.alreadySelected) {
			alphaLerp = 0.0;
			curSelectedLerp = parent.curSelected;
			xLerp = 20 - (parent.curSelected * 20);
			Sys.println('WHYYY ${parent.active}');
			return;
		}

		var ratio = Math.min(deltaTime * 0.015, 1);
		if (ratio == 1) ratio = (1/lime.app.Application.current.window.frameRate) * 0.015; // When loading the freeplay menu the first time it gets stuck at 1.0 for a single frame

		//Sys.println('$ratio, $alphaLerp');
		if (!parent.opened && alphaLerp < 0.1/256) {
			shutDown();
			curSelectedLerp = parent.curSelected;
			xLerp = 20 - (parent.curSelected * 20);
			xLerpPrev = xLerp;
			alphaLerp = 0.0;
			return;
		}

		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedLerp = Tools.lerp(curSelectedLerp, parent.curSelected, ratio);
		xLerp = Tools.lerp(xLerp, 20 - (parent.curSelected * 20), ratio);

		var incrementBest = Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 7));

		for (i in 0...7) {
			if (songsAvailable.length <= 7 && i <= songsAvailable.length) continue;

			var k = i + incrementBest;
			var l = parent.curSelected - incrementBest;
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

    function addPrograms() {
        if (!songTextsProg.isIn(display)) {
			display.addProgram(songTextsProg);
		}

		if (!songIconsProg.isIn(display)) {
			display.addProgram(songIconsProg);
		}
    }

    function shutDown() {
		if (!songTextsProg.isIn(display) || !songIconsProg.isIn(display)) return;

		display.color = 0x00000000;
		display.removeProgram(songTextsProg);
		display.removeProgram(songIconsProg);
		firstFrameToAnimate = true;
    }
}