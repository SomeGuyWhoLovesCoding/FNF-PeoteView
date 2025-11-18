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
	var sounds:Array<AudioSource> = [];

	/**
		The countdown display's conductor (for actual decoupled countdown logic).
	**/
	var conductor:Conductor;

	function setupSounds(suffix:String = "") {
		CountdownDisplay.suffix = suffix;
		for (i in 0...4) {
			sounds.push(new AudioSource(AudioBuffer.fromFile('assets/countdown/${3 - i}${suffix != "" ? '-$suffix' : ''}.ogg')));
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

		// Setup a separate conductor used solely for the countdown.
		var timeSig = Chart.header.timeSig;
		conductor = new Conductor(Chart.header.bpm, timeSig[0], timeSig[1]);

		// Initialize its offsets so it uses a clean musical timeline (no latency compensation)
		conductor.offset = 0; // countdown should ignore playback latency

		// Start it at the countdown start position (exact -crochet * 4.5).
		conductor.time = 0;
	}

	/**
		Ticks the countdown.
		@param id The countdown's tick index.
	**/
	function countdownTick(id:Int) {
		if (id != -1) {
			var snd = sounds[id];
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
		var a = sprite.alpha;
		var ratio = Math.min((deltaTime * 0.00725), 1);
		sprite.alpha = Tools.fixElementAlphaFromFadingLerp(Tools.lerp(sprite.alpha, 0, ratio));
		buffer.updateElement(sprite);
	}

	/**
		Disposes the countdown display.
	**/
	function dispose() {
		buffer.clear();
		display.removeProgram(program);
		sprite = null;
		while (sounds.pop() != null) {}
		conductor = null;
	}

	/**
		Positions the countdown display at the center of the screen.
	**/
	inline function _screenCenter() {
		sprite.x = (Main.INITIAL_WIDTH - sprite.w) * 0.5;
		sprite.y = (Main.INITIAL_HEIGHT - sprite.h) * 0.5;
	}
}