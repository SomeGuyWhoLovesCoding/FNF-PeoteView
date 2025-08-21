package structures.gameplay;

import lime.media.AudioBuffer;
import lime.media.AudioSource;

/**
	The countdown display.
	Inspired from defective engine's countdown class.
	@since Development
**/
#if !debug
@:noDebug
#end
@:publicFields
class CountdownDisplay {
	/**
		The countdown display's underlying buffer.
	**/
	static var buffer:Buffer<UISprite>;

	/**
		The countdown display's underlying program.
	**/
	static var program:Program;

	/**
		The countdown display's underlying display reference.
	**/
	static var display:Display;

	/**
		The countdown display's sprite.
		This is held on by the buffer that actually gets rendered by the program's display.
	**/
	private var sprite:UISprite;

	/**
		The countdown display's sound suffix.
	**/
	static var suffix:String = "";

	/**
		The countdown display's sound cache.
	**/
	static var cached:Array<AudioSource> = [for (i in 0...4) null];

	static function setupSounds(suffix:String = "") {
		CountdownDisplay.suffix = suffix;
		for (i in 0...cached.length) {
			cached[i] = new AudioSource(AudioBuffer.fromFile('assets/countdown/${3 - i}${suffix != "" ? '-$suffix' : ''}.ogg'));
		}
	}

	static function init(atDisplay:Display) {
		if (buffer == null) {
			buffer = new Buffer<UISprite>(1);
			program = new Program(buffer);
			program.blendEnabled = true;

			var tex = TextureSystem.getTexture("uiTex");
			UISprite.init(program, "uiTex", tex);
		}
		display = atDisplay;
		display.addProgram(program);
	}

	/**
		Constructs a countdown display from chart.
	**/
	function new() {
		sprite = new UISprite();
		sprite.type = COUNTDOWN_POPUP;
		sprite.changeID(0);

		_screenCenter();

		sprite.alpha = 0.0;

		buffer.addElement(sprite);
	}

	/**
		Ticks the countdown.
		@param id The countdown's tick index.
	**/
	function countdownTick(id:Int) {
		if (id != -1) {
			var snd = cached[id];
			if (snd != null) {
				snd.play();
			}
		}

		if (id != 0) {
			var idBelowZero = id < 0;
			sprite.changeID(idBelowZero ? 0 : id - 1);
			sprite.alpha = idBelowZero ? 0.0 : 1.0;

			_screenCenter();

			buffer.updateElement(sprite);
		}
	}

	/**
		Updates the countdown.
		@param deltaTime The time since the last frame.
	**/
	function update(deltaTime:Float) {
		if (sprite.alpha != 0) {
			var a = sprite.alpha;
			var multVal = (a * 0.5) * (deltaTime * 0.0145);
			var alphaBoundCheck = a - multVal;

			if (alphaBoundCheck < 0) {
				sprite.alpha = 0;
			} else {
				sprite.alpha -= multVal;
			}

			buffer.updateElement(sprite);
		}
	}

	/**
		Disposes the countdown display.
	**/
	function dispose() {
		buffer.clear();
		display.removeProgram(program);
		sprite = null;
		GC.run();
	}

	/**
		Positions the countdown display at the center of the screen.
	**/
	inline function _screenCenter() {
		sprite.x = (Main.INITIAL_WIDTH - sprite.w) * 0.5;
		sprite.y = (Main.INITIAL_HEIGHT - sprite.h) * 0.5;
	}
}