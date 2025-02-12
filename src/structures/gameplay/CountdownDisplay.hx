package structures.gameplay;

/**
	The countdown display.
	Inspired from defective engine's countdown class.
**/
#if !debug
@:noDebug
#end
@:publicFields
class CountdownDisplay {
	/**
		The countdown display's underlying buffer.
	**/
	var buffer:Buffer<UISprite>;

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
	static var cached:Vector<Sound> = new Vector<Sound>(4);

	static function setupSounds(suffix:String = "") {
		CountdownDisplay.suffix = suffix;
		for (i in 0...cached.length) {
			(cached[i] = new Sound()).fromFile('assets/countdown/${3 - i}${suffix != "" ? '-$suffix' : ''}.wav');
		}
	}

	/**
		Constructs a countdown display from chart.
		@param buffer The buffer you want to add your countdown display at.
	**/
	function new(buffer:Buffer<UISprite>) {
		this.buffer = buffer;

		sprite = new UISprite();
		sprite.type = COUNTDOWN_POPUP;
		sprite.changeID(0);

		_screenCenter();

		sprite.c.aF = 0.0;

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
			sprite.c.aF = idBelowZero ? 0.0 : 1.0;

			_screenCenter();

			buffer.updateElement(sprite);
		}
	}

	/**
		Updates the countdown.
		@param deltaTime The time since the last frame.
	**/
	function update(deltaTime:Float) {
		if (sprite.c.aF != 0) {
			var a = sprite.c.aF;
			var multVal = (a * 0.5) * (deltaTime * 0.0145);
			var alphaBoundCheck = a - multVal;

			if (alphaBoundCheck < 0) {
				sprite.c.aF = 0;
			} else {
				sprite.c.aF -= multVal;
			}

			buffer.updateElement(sprite);
		}
	}

	/**
		Disposes the countdown display.
	**/
	function dispose() {
		buffer.removeElement(sprite);
		sprite = null;
		GC.run();
	}

	inline function _screenCenter() {
		sprite.x = (Main.INITIAL_WIDTH - sprite.w) * 0.5;
		sprite.y = (Main.INITIAL_HEIGHT - sprite.h) * 0.5;
	}
}