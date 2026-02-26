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

	var disposed(default, null):Bool = true;

	var chapter(default, null):String;

	function new(parent:FreeplayMenu, chapterName:String) {
		this.parent = parent;
		chapter = chapterName;
	}

	function reload(chapterName:String) {
		if (songTextsBuf == null) {
			songTextsBuf = new Buffer<Actor>(140, 0, false);
			songTextsProg = new Program(songTextsBuf);
			songTextsProg.blendEnabled = true;
			songTextsProg.blendSrc = songTextsProg.blendSrcAlpha = BlendFactor.ONE;
			songTextsProg.blendDst = songTextsProg.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

			var tex = TextureSystem.getTexture("alphabetSheet");
			TextureSystem.setTexture(songTextsProg, "alphabetSheet", "alphabetSheet");
		}

		if (songIconsBuf == null) {
			songIconsBuf = new Buffer<HealthBarSprite>(8, 0, false);
			songIconsProg = new Program(songIconsBuf);
			songIconsProg.blendEnabled = true;
			songIconsProg.blendSrc = songIconsProg.blendSrcAlpha = BlendFactor.ONE;
			songIconsProg.blendDst = songIconsProg.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

			var tex = TextureSystem.getTexture("hbTex");
			HealthBarSprite.init(songIconsProg, "hbTex", tex);
		}

		if (!disposed) unload();

		chapter = chapterName;

		var chapterData:ChapterData = haxe.Json.parse(sys.io.File.getContent(Paths.asset('assets/data/chapters/$chapter/data.json')));
		var songs:Array<ChapterSong> = chapterData.songs;

		for (i in 0...songs.length) {
			var song = songs[i];
			songsAvailable.push(song);
		}

		songTextCharGroup = [
			for (i in 0...7) [
				for (i in 0...20) {
					var spr = new Actor(display, null, "alphabetText", 0, 0, 24, "", false);
					spr.c.aF = 0.0;
					spr.c.luminanceF = 0.0;
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
				icon.c.luminanceF = 0.0;
				songIconsBuf.addElement(icon);
				icon;
			}
		];

		disposed = false;
	}

	function unload() {
		songTextsBuf.clear();
		songIconsBuf.clear();
		songsAvailable.splice(0, songsAvailable.length);
		while (songTextCharGroup.length != 0) {
			var elements = songTextCharGroup.pop();
			while (elements.length != 0) {
				var elem = elements.pop();
				if (elem != null) {
					elem.dispose();
					elem = null;
				}
			}
			//songTextCharGroup = null; big mistake. do not nullify these. They are persistent across the whole front menu.
		}
		songIconGroup.splice(0, songIconGroup.length);
		//songIconGroup = null;
		disposed = true;
	}

	var alphaLerp:Float = 0.0;
	var curSelectedLerp:Float = 0.0;
	var xLerp:Float = 0.0;
	var xLerpPrev:Float = 0.0;

	var firstFrameToAnimate:Bool = true;
	var framesElapsed:Int64 = 0;
	var durationRemaining:Float = 0;
	var canAdvanceFrame:Bool = false;

	// Took this from https://github.com/CCobaltDev/FNF-Horizon-Engine/blob/rewrite/source/horizon/objects/Alphabet.hx#L83 and extended it to work with the vanilla alphabet
	// edit: deepseek did this same approach as with InputSystem.hx
	static var charCorrectionMap:Map<String, String> = [
		"?" => "question",
		"&" => "ampersand",
		"<" => "less",
		'"' => "quote",
		"'" => "apostrophe",
		"•" => "bullet",
		"," => "comma",
		"!" => "exclamation",
		"/" => "forward slash",
		"\\" => "back slash",
		"¿" => "inverted question",
		"¡" => "inverted exclamation",
		"." => "period",
		"-" => "-",
		"+" => "+",
		" " => "_", // Hidden space (This is space for a reason, and it's hidden. If the sprite wasn't even created for it, the pooling won't even run correctly.)
	];

	// --- Render helpers ---

	inline function calcRatio(deltaTime:Float):Float {
		var ratio = Math.min(deltaTime * 0.015, 1);
		if (ratio == 1) ratio = (1 / lime.app.Application.current.window.frameRate) * 0.015;
		return ratio;
	}

	inline function handleShutdown() {
		parent.shutDown();
		curSelectedLerp = parent.nav.value();
		alphaLerp = 0.0;
		xLerp = 20 - (parent.nav.value() * 20);
		xLerpPrev = xLerp;
	}

	inline function updateTimers(deltaTime:Float) {
		durationRemaining -= deltaTime;
		if (durationRemaining < 0) canAdvanceFrame = true;
	}

	inline function updateLerps(ratio:Float) {
		var curSelected = parent.nav.value();
		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelected, ratio);
		xLerp = Tools.lerp(xLerp, 20 - (curSelected * 20), ratio);
	}

	inline function calcIncrementBest():Int {
		return songsAvailable.length > 7
			? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 7))
			: 0;
	}

	inline function resolveChar(title:String, j:Int):String {
		if (j >= 17) return '.';
		var char = title.charAt(j).toLowerCase();
		if (charCorrectionMap.exists(char)) return charCorrectionMap[char];
		return char;
	}

	inline function advanceAnimFrame(spr:Actor) {
		if (!canAdvanceFrame) return;
		framesElapsed++;
		canAdvanceFrame = false;
		durationRemaining = spr.frameDurationMs;
	}

	inline function positionCharSprite(spr:Actor, char:String, x:Float, k:Int) {
		spr.x = (x + 50) + (xLerp + (20 * k));
		spr.y = (-curSelectedLerp * 156) + (156 * k) + 320;
		switch (char) {
			case '-':
				spr.y += spr.h;
			case 'comma' | '_' | 'period':
				spr.y += 47;
			case '+':
				spr.y += spr.h * .25;
		}
	}

	// Returns the iconX anchor (x position of the last visible character).
	function updateSongText(i:Int, incrementBest:Int):Float {
		var curSelected = parent.nav.value();
		var k = i + incrementBest;
		if (k < 0 || k >= songsAvailable.length) return 0.0;

		var l = curSelected - incrementBest;
		var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
		var song = songsAvailable[kClamped];
		var title = song.title;
		var grp = songTextCharGroup[i];

		var x:Float = 20;
		var iconX:Float = 0.0;

		for (j in 0...20) {
			var char = resolveChar(title, j);
			var isInvalidCharacter = j >= title.length || title.charAt(j).toLowerCase() == ' ';

			var spr = grp[j];

			advanceAnimFrame(spr);
			spr.playAnimation('$char bold instance 1', false);
			spr.frameIndex = Int64.toInt(framesElapsed % Std.int(Math.max(spr.endingFrameIndex - spr.startingFrameIndex, 1)));
			spr.changeFrame();

			positionCharSprite(spr, char, x, k);

			var alpha = isInvalidCharacter ? 0.0 : (i == l ? 1.0 : 0.5) * alphaLerp;
			spr.c.aF = alpha;
			spr.c.luminanceF = alpha;
			songTextsBuf.updateElement(spr);
			spr.updateBuffer();

			if (j == Math.min(title.length - 1, 17)) {
				iconX = spr.x;
			}

			if (isInvalidCharacter) {
				x += 28; // From https://github.com/ShadowMario/FNF-PsychEngine/blob/main/source/objects/Alphabet.hx#L211
			} else {
				x += spr.firstFrameWidth + 2;
			}
		}

		return iconX;
	}

	function updateSongIcon(i:Int, incrementBest:Int, iconX:Float) {
		var curSelected = parent.nav.value();
		var k = i + incrementBest;
		if (k < 0 || k >= songsAvailable.length) return;

		var l = curSelected - incrementBest;
		var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
		var song = songsAvailable[kClamped];

		var icon = songIconGroup[i];
		icon.changeID(Tools.fromIconGridXMLCharacter(song.icon)[0]);
		var alpha = (i == l ? 1.0 : 0.5) * alphaLerp;
		icon.c.aF = alpha;
		icon.c.luminanceF = alpha;
		icon.x = iconX + ((icon.w * 0.35) + 12);
		icon.y = ((-curSelectedLerp * 156) + (156 * k) + 320) - 30; // https://github.com/ShadowMario/FNF-PsychEngine/blob/main/source/objects/HealthIcon.hx#L22
		songIconsBuf.updateElement(icon);
	}

	function render(deltaTime:Float) {
		var ratio = calcRatio(deltaTime);

		if (!parent.opened && alphaLerp < 0.1 / 256) {
			handleShutdown();
			return;
		}

		updateTimers(deltaTime);
		updateLerps(ratio);

		var incrementBest = calcIncrementBest();

		for (i in 0...7) {
			var iconX = updateSongText(i, incrementBest);
			updateSongIcon(i, incrementBest, iconX);
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
		if (songTextsProg.isIn(display)) {
			display.removeProgram(songTextsProg);
		}

		if (songIconsProg.isIn(display)) {
			display.removeProgram(songIconsProg);
		}
	}
}
