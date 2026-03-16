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
	static var songTextsProg(default, null):CustomProgram;

	static var songIconsBuf(default, null):Buffer<HealthBarSprite>;
	static var songIconsProg(default, null):CustomProgram;

	var songsAvailable(default, null):Array<ChapterSong> = [];
	static var songTextCharGroup(default, null):Array<Array<Actor>> = [];
	static var songIconGroup(default, null):Array<HealthBarSprite> = [];

	var parent(default, null):FreeplayMenu;

	var disposed(default, null):Bool = true;

	var chapter(default, null):String;

	// Per-sprite animation state: tracks frame counter, timing, and last played animation name.
	static var spriteAnimState:Map<Actor, SpriteAnimState> = new Map();

	function new(parent:FreeplayMenu, chapterName:String) {
		this.parent = parent;
		chapter = chapterName;
	}

	function reload(chapterName:String) {
		if (songTextsBuf == null) {
			songTextsBuf = new Buffer<Actor>(16, 16);
			songTextsProg = new CustomProgram(songTextsBuf);

			var texName = "alphabetSheet";
			var tex = TextureSystem.getTexture(texName);
			TextureSystem.setTexture(songTextsProg, texName, texName);

			if (Main.current.upscale) {
				songTextsProg.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER);
				songTextsProg.setColorFormula('
					iconPixel(${texName}_ID, vTexCoord, vec2(spriteW, 0.0), vec2(spriteH, 0.0)) * color
				');
			}
		}

		if (songIconsBuf == null) {
			songIconsBuf = new Buffer<HealthBarSprite>(8, 8);
			songIconsProg = new CustomProgram(songIconsBuf);

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
					var spr = Actor.create(display, null, "alphabetText", 0, 0, 24, "", false);
					spr.color.aF = 0.0;
					spr.color.luminanceF = 0.0;
					songTextsBuf.addElement(spr);
					// Initialise per-sprite animation state.
					spriteAnimState.set(spr, new SpriteAnimState(0, 0.0, ""));
					spr;
				}
			]
		];

		songIconGroup = [
			for (i in 0...7) {
				var icon = new HealthBarSprite();
				icon.type = HEALTH_ICON;
				icon.alpha = 0.0;
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
					spriteAnimState.remove(elem); // Clean up per-sprite state to avoid leaking Actor refs.
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

	var curSelectedTarget:Float = 0.0;

	var firstFrameToAnimate:Bool = true;

	// Stored so advanceAnimFrame can reference it without threading deltaTime all the way down.
	var _currentDeltaTime:Float = 0.0;

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
		var ratio = Math.max(Math.min(deltaTime * 0.015, 1), 0.00001);
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

	inline function updateLerps(ratio:Float) {
		var curSelected = parent.nav.value();
		alphaLerp = Tools.lerp(alphaLerp, parent.opened ? 1.0 : 0.0, ratio);
		if (!parent.isDragging) {
			curSelectedTarget = curSelected;
		}
		curSelectedLerp = Tools.lerp(curSelectedLerp, curSelectedTarget, ratio);
		xLerp = 20 - (curSelectedLerp * 20);
	}

	inline function calcIncrementBest():Int {
		return songsAvailable.length > 7
			? Math.floor(Math.min(Math.max(curSelectedLerp - 3, 0), songsAvailable.length - 7))
			: 0;
	}

	function resolveChar(title:String, j:Int):String {
		var char = j >= 17 ? "." : title.charAt(j).toLowerCase();
		if (charCorrectionMap.exists(char)) return charCorrectionMap[char];
		return char;
	}

	/**
		Advances the animation frame for a single sprite using its own independent state.
		Skips `playAnimation` when the animation name hasn't changed to avoid resetting frameIndex.
	**/
	inline function advanceAnimFrame(spr:Actor, animName:String) {
		var state = spriteAnimState.get(spr);
		if (state == null) {
			// Safety fallback: should have been created in reload(), but guard anyway.
			state.frames = 0;
			state.duration = 0.0;
			state.lastAnim = "";
			spriteAnimState.set(spr, state);
		}

		// Only call playAnimation when the anim name actually changes, so frameIndex isn't reset every tick.
		if (state.lastAnim != animName) {
			spr.playAnimation('$animName bold instance 1', false);
			state.lastAnim = animName;
			// Reset frame counter so the new animation starts from the beginning.
			state.frames = 0;
			state.duration = spr.frameDurationMs;
		}

		// Tick this sprite's own timer.
		state.duration -= _currentDeltaTime;
		if (state.duration <= 0) {
			state.frames++;
			state.duration = spr.frameDurationMs;
		}

		spr.frameIndex = Int64.toInt(state.frames % Std.int(Math.max(spr.endingFrameIndex - spr.startingFrameIndex, 1)));
		spr.changeFrame();
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

	inline function calcItemAlpha(k:Int):Float { // this was also from claude.ai
		var dist = Math.abs(k - (curSelectedLerp - 0.1));
		return 0.5 + (0.5 * Math.max(0.0, 1.0 - dist));
	}

	// Returns the iconX anchor (x position of the last visible character).
	function updateSongText(i:Int, incrementBest:Int):Float {
		var curSelected = parent.nav.value();
		var k = i + incrementBest;
		if (k < 0 || k >= songsAvailable.length) return 0.0;

		var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
		var song = songsAvailable[kClamped];
		var title = song.title;
		var grp = songTextCharGroup[i];

		var x:Float = 20;
		var iconX:Float = 0.0;
		var j:Int = 0;

		for (j in 0...20) {
			var char = resolveChar(title, j);
			var isInvalidCharacter = j >= title.length || title.charAt(j).toLowerCase() == ' ';

			var spr = grp[j];

			// Each sprite now advances independently — no shared frame counter or timer.
			advanceAnimFrame(spr, char);

			positionCharSprite(spr, char, x, k);

			var alpha = isInvalidCharacter ? 0.0 : calcItemAlpha(k) * alphaLerp;
			spr.color.aF = alpha;
			spr.color.luminanceF = alpha;
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

		var kClamped = Math.floor(Math.min(Math.max(k, 0), songsAvailable.length - 1));
		var song = songsAvailable[kClamped];

		var icon = songIconGroup[i];
		icon.changeID(Tools.fromIconGridXMLCharacter(song.icon)[0]);
		var alpha = calcItemAlpha(k) * alphaLerp;
		icon.alpha = alpha;
		icon.x = iconX + ((icon.w * 0.35) + 12);
		icon.y = ((-curSelectedLerp * 156) + (156 * k) + 320) - 30; // https://github.com/ShadowMario/FNF-PsychEngine/blob/main/source/objects/HealthIcon.hx#L22
		//icon.w = 150 * 4;
		//icon.h = 150 * 4;
		icon.texW = 150;
		icon.texH = 150;
		songIconsBuf.updateElement(icon);
	}

	function render(deltaTime:Float) {
		var ratio = calcRatio(deltaTime);

		if (!parent.opened && alphaLerp < 0.1 / 256) {
			handleShutdown();
			return;
		}

		// Store deltaTime so advanceAnimFrame can use it without an extra parameter.
		_currentDeltaTime = deltaTime;

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

/** Per-sprite animation state used by `spriteAnimState`. **/
@:publicFields
private class SpriteAnimState {
	var frames:Int;
	var duration:Float;
	var lastAnim:String;

	function new(f:Int, dur:Float, lA:String) {
		frames = f;
		duration = dur;
		lastAnim = lA;
	}
}
