package structures;

/**
	Freeplay-style alphabet list (scroll + selection highlight).
	Used by freeplay song titles and options controls mania (1K-16K).
	Now a truly instanced class with isolated state.
	@since 0.94
**/
@:publicFields
class FreeplayAlphabet {
	// Instance-specific fields
	var songTextsBuf:Buffer<Actor>;
	var songTextsProg:CustomProgram;
	var songTextCharGroup:Array<Array<Actor>> = [];
	var songTextAnimStateGroup:Array<Array<SpriteAnimState>> = [];
	var titleCharCache:Map<String, TitleCharInfo> = new Map();

	var host:IAlphabetScrollHost;
	var display(default, null):CustomDisplay;
	var _currentDeltaTime:Float = 0.0;
	var isDisposed:Bool = false;

	static var ALPHABET_CHARACTER_LIMIT = 24; // This is a final limit.

	// Static shared resources (read-only, no state)
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

	// Static shared read-only map (immutable after init)
	private static var charCorrectionMap:FakeStringMap<String> = new FakeStringMap<String>();
	private static var staticInitDone:Bool = false;

	function new(host:IAlphabetScrollHost, display:CustomDisplay) {
		// Initialize static resources once
		if (!staticInitDone) {
			for (key in _charCorrectionMapOG.keys()) {
				charCorrectionMap.set(key, _charCorrectionMapOG.get(key));
			}
			staticInitDone = true;
		}

		this.host = host;
		this.display = display;
		this.isDisposed = false;
	}

	function ensurePrograms() {
		if (isDisposed)
			return;
		if (songTextsBuf != null)
			return;

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
		if (isDisposed)
			return;

		ensurePrograms();
		unloadChars();

		// Create instance-specific character sprites
		songTextCharGroup = [
			for (i in 0...7) [
				for (j in 0...ALPHABET_CHARACTER_LIMIT) {
					var spr = Actor.create(display, null, "alphabetText", 0, 0, 24, "", false);
					spr.color.aF = 0.0;
					spr.color.luminanceF = 0.0;

					songTextsBuf.addElement(spr);
					spr;
				}
			]
		];
		songTextAnimStateGroup = [
			for (i in 0...7) [
				for (j in 0...ALPHABET_CHARACTER_LIMIT) {
					new SpriteAnimState(0, 0.0, "");
				}
			]
		];
	}

	function unload() {
		if (isDisposed)
			return;
		unloadChars();
	}

	function dispose() {
		if (isDisposed)
			return;

		isDisposed = true;

		// First remove from display
		shutDown();

		// Clear all character sprites and their references
		unloadChars();

		// Clear the buffer - this releases all Actor references
		if (songTextsBuf != null) {
			songTextsBuf = null;
		}

		// Clear arrays to release all references
		songTextCharGroup = null;
		songTextAnimStateGroup = null;
		titleCharCache.clear();
		titleCharCache = null;

		// Null out all references
		songTextsProg = null;
		host = null;
		display = null;
	}

	// Also add a destructor-like method to ensure cleanup
	function finalize() {
		if (!isDisposed) {
			dispose();
		}
	}

	public function unloadChars() {
		if (isDisposed)
			return;
		while (songTextCharGroup.length != 0) {
			var elements = songTextCharGroup.pop();
			while (elements.length != 0) {
				var elem = elements.pop();
				if (elem != null) {
					songTextsBuf.removeElement(elem);
					elem.dispose();
				}
			}
		}
		while (songTextAnimStateGroup.length != 0) {
			var states = songTextAnimStateGroup.pop();
			while (states.length != 0) {
				states.pop();
			}
		}
	}

	function setDeltaTime(deltaTime:Float) {
		if (isDisposed)
			return;
		_currentDeltaTime = deltaTime;
	}

	function resolveChar(title:String, j:Int):String {
		//BOTTLENECK: high per-frame per-char lowercase string alloc + hash map lookup for every alphabet char (7 rows x 24 chars) | FIX: pre-normalize titles once and cache resolved char strings per title
		var char = j >= ALPHABET_CHARACTER_LIMIT - 3 ? "." : title.charAt(j).toLowerCase();
		var corrected = charCorrectionMap.get(char);
		return corrected != null ? corrected : char;
	}

	function getTitleCharInfo(title:String):TitleCharInfo {
		var info = titleCharCache.get(title);
		if (info == null) {
			info = buildTitleCharInfo(title);
			titleCharCache.set(title, info);
		}
		return info;
	}

	function buildTitleCharInfo(title:String):TitleCharInfo {
		var chars:Array<String> = [];
		var animKeys:Array<String> = [];
		var rawChars:Array<String> = [];
		for (j in 0...ALPHABET_CHARACTER_LIMIT) {
			var raw = title.charAt(j).toLowerCase();
			chars[j] = resolveChar(title, j);
			rawChars[j] = raw;
			animKeys[j] = chars[j] + " bold instance 1";
		}
		return new TitleCharInfo(title.length, chars, animKeys, rawChars);
	}

	inline function advanceAnimFrame(spr:Actor, animName:String, animKey:String, state:SpriteAnimState) {
		if (isDisposed || spr == null || state == null)
			return;

		if (state.lastAnim != animName) {
			//BOTTLENECK: mid per-char per-frame string interpolation + playAnimation() call even when the anim is unchanged (checked only after the call) | FIX: compare state.lastAnim first; precompute the anim name string
			spr.playAnimation(animKey, false);
			state.lastAnim = animName;
			state.frames = 0;
			state.duration = spr.frameDurationMs;
			state.frameDurationMs = spr.frameDurationMs;
			state.rangeFrames = Std.int(Math.max(spr.endingFrameIndex - spr.startingFrameIndex, 1));
		}

		state.duration -= _currentDeltaTime;
		if (state.duration <= 0) {
			state.frames++;
			state.duration = state.frameDurationMs;
		}

		spr.frameIndex = state.frames % state.rangeFrames;
		spr.changeFrame();
	}

	inline function positionCharSprite(spr:Actor, char:String, x:Float, k:Int) {
		if (isDisposed || spr == null)
			return;

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
		if (isDisposed)
			return 0.0;
		// Use the host's independent values
		var dist = Math.abs(k - (host.curSelectedLerp - 0.1));
		return 0.5 + (0.5 * Math.max(0.0, 1.0 - dist));
	}

	function updateRowText(i:Int, incrementBest:Int):Float {
		if (isDisposed || host == null)
			return 0.0;

		var k = i + incrementBest;
		if (k < 0 || k >= host.alphabetListLength())
			return 0.0;

		var kClamped = Math.floor(Math.min(Math.max(k, 0), host.alphabetListLength() - 1));
		var title = host.alphabetItemTitle(kClamped);

		if (i >= songTextCharGroup.length)
			return 0.0;
		var grp = songTextCharGroup[i];
		if (grp == null)
			return 0.0;
		var states = songTextAnimStateGroup[i];
		if (states == null)
			return 0.0;

		var info = getTitleCharInfo(title);

		var x:Float = 20;
		var iconX:Float = 0.0;

		//BOTTLENECK: high 7 rows x 24 chars re-updated every frame: map gets, anim Int64 math, per-char sprite property writes | FIX: only update moving/visible chars; batch property writes and reuse per-char state
		for (j in 0...ALPHABET_CHARACTER_LIMIT) {
			if (j >= grp.length)
				break;

			var spr = grp[j];
			if (spr == null)
				continue;

			var char = info.chars[j];
			var isInvalidCharacter = j >= info.titleLength || info.rawChars[j] == ' ';

			advanceAnimFrame(spr, char, info.animKeys[j], states[j]);
			positionCharSprite(spr, char, x, k);

			// Use host's alphaLerp for fade in/out
			var alpha = isInvalidCharacter ? 0.0 : calcItemAlpha(k) * host.alphaLerp;
			spr.color.aF = alpha;
			spr.color.luminanceF = alpha;

			if (j == Math.min(info.titleLength - 1, ALPHABET_CHARACTER_LIMIT - 3)) {
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

	/** Expose the underlying buffer so callers can do `alphabet.buffer.update()` directly. **/
	var buffer(get, never):Buffer<Actor>;

	inline function get_buffer():Buffer<Actor> {
		return songTextsBuf;
	}

	function addPrograms() {
		if (isDisposed)
			return;

		if (songTextsProg != null && !songTextsProg.isIn(display)) {
			display.addProgram(songTextsProg);
		}
	}

	public function setHost(host:IAlphabetScrollHost) {
		this.host = host;
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
	var frameDurationMs:Float;
	var rangeFrames:Int;

	function new(f:Int, dur:Float, lA:String) {
		frames = f;
		duration = dur;
		lastAnim = lA;
		frameDurationMs = 0.0;
		rangeFrames = 1;
	}
}

@:publicFields
private class TitleCharInfo {
	var titleLength:Int;
	var chars:Array<String>;
	var animKeys:Array<String>;
	var rawChars:Array<String>;

	function new(len:Int, c:Array<String>, a:Array<String>, r:Array<String>) {
		titleLength = len;
		chars = c;
		animKeys = a;
		rawChars = r;
	}
}
