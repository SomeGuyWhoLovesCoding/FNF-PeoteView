package structures;

import haxe.ds.StringMap;

/**
	Freeplay-style alphabet list (scroll + selection highlight).
	Used by freeplay song titles and options controls mania (1K–16K).
	@since 0.94
**/
@:publicFields
class FreeplayAlphabet {
	static var songTextsBuf(default, null):Buffer<Actor>;
	static var songTextsProg(default, null):CustomProgram;
	static var songTextCharGroup(default, null):Array<Array<Actor>> = [];

	static var spriteAnimState:Map<Actor, SpriteAnimState> = new Map();

	var host(default, null):IAlphabetScrollHost;
	var display(default, null):CustomDisplay;

	var _currentDeltaTime:Float = 0.0;

	private static var _charCorrectionMapOG:Map<String, String> = [
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
		" " => "_",
	];
	static var charCorrectionMap:FakeStringMap<String> = new FakeStringMap<String>();

	function new(host:IAlphabetScrollHost, display:CustomDisplay) {
		//charCorrectionMap.initFromStringMap(_charCorrectionMapOG);
		for (key in _charCorrectionMapOG.keys()) {
            charCorrectionMap.set(key, _charCorrectionMapOG.get(key));
        }
		this.host = host;
		this.display = display;
	}

	function ensurePrograms() {
		if (songTextsBuf != null) return;

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

	function reload() {
		ensurePrograms();
		unloadChars();

		songTextCharGroup = [
			for (i in 0...7) [
				for (i in 0...20) {
					var spr = Actor.create(display, null, "alphabetText", 0, 0, 24, "", false);
					spr.color.aF = 0.0;
					spr.color.luminanceF = 0.0;
					songTextsBuf.addElement(spr);
					spriteAnimState.set(spr, new SpriteAnimState(0, 0.0, ""));
					spr;
				}
			]
		];
	}

	function unload() {
		if (songTextsBuf == null) return;
		unloadChars();
		songTextsBuf.clear();
	}

	function unloadChars() {
		while (songTextCharGroup.length != 0) {
			var elements = songTextCharGroup.pop();
			while (elements.length != 0) {
				var elem = elements.pop();
				if (elem != null) {
					spriteAnimState.remove(elem);
					elem.dispose();
				}
			}
		}
	}

	function setDeltaTime(deltaTime:Float) {
		_currentDeltaTime = deltaTime;
	}

	function resolveChar(title:String, j:Int):String {
		var char = j >= 17 ? "." : title.charAt(j).toLowerCase();
		if (charCorrectionMap.exists(char)) return charCorrectionMap.get(char);
		return char;
	}

	inline function advanceAnimFrame(spr:Actor, animName:String) {
		var state = spriteAnimState.get(spr);
		if (state == null) {
			state = new SpriteAnimState(0, 0.0, "");
			spriteAnimState.set(spr, state);
		}

		if (state.lastAnim != animName) {
			spr.playAnimation('$animName bold instance 1', false);
			state.lastAnim = animName;
			state.frames = 0;
			state.duration = spr.frameDurationMs;
		}

		state.duration -= _currentDeltaTime;
		if (state.duration <= 0) {
			state.frames++;
			state.duration = spr.frameDurationMs;
		}

		spr.frameIndex = Int64.toInt(state.frames % Std.int(Math.max(spr.endingFrameIndex - spr.startingFrameIndex, 1)));
		spr.changeFrame();
	}

	inline function positionCharSprite(spr:Actor, char:String, x:Float, k:Int) {
		spr.x = (x + 50) + (host.xLerp + (20 * k));
		spr.y = (-host.curSelectedLerp * 156) + (156 * k) + 320;
		switch (char) {
			case '-':
				spr.y += spr.h;
			case 'comma' | '_' | 'period':
				spr.y += 47;
			case '+':
				spr.y += spr.h * .25;
		}
	}

	function calcItemAlpha(k:Int):Float {
		var dist = Math.abs(k - (host.curSelectedLerp - 0.1));
		return 0.5 + (0.5 * Math.max(0.0, 1.0 - dist));
	}

	function updateRowText(i:Int, incrementBest:Int):Float {
		var k = i + incrementBest;
		if (k < 0 || k >= host.alphabetListLength()) return 0.0;

		var kClamped = Math.floor(Math.min(Math.max(k, 0), host.alphabetListLength() - 1));
		var title = host.alphabetItemTitle(kClamped);
		var grp = songTextCharGroup[i];

		var x:Float = 20;
		var iconX:Float = 0.0;

		for (j in 0...20) {
			var char = resolveChar(title, j);
			var isInvalidCharacter = j >= title.length || title.charAt(j).toLowerCase() == ' ';

			var spr = grp[j];

			advanceAnimFrame(spr, char);
			positionCharSprite(spr, char, x, k);

			var alpha = isInvalidCharacter ? 0.0 : calcItemAlpha(k) * host.alphaLerp;
			spr.color.aF = alpha;
			spr.color.luminanceF = alpha;

			if (j == Math.min(title.length - 1, 17)) {
				iconX = spr.x;
			}

			if (isInvalidCharacter) {
				x += 28;
			} else {
				x += spr.firstFrameWidth + 2;
			}
		}

		return iconX;
	}

	function updateBuffer() {
		songTextsBuf.update();
	}

	function addPrograms() {
		if (!songTextsProg.isIn(display)) {
			display.addProgram(songTextsProg);
		}
	}

	function shutDown() {
		if (songTextsProg != null && songTextsProg.isIn(display)) {
			display.removeProgram(songTextsProg);
		}
	}
}

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