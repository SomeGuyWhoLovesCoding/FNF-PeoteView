package elements;

/**
	CustomDisplay is a custom class that extends Display.
	It adds a few extra properties to the Display class (such as scroll, scale, and fov), and most importantly, automatic framebuffer support for rotating support.
**/
@:publicFields
class CustomDisplay extends Display {
	var scroll(default, null):Point = {x: 0, y: 0};

	var scale(default, set):Float = 1;

	inline function set_scale(value:Float) {
		if (value != scale) {
			scale = value;
			zoom = value * fov;
			update();
		}
		return value;
	}

	var fov(default, set):Float = 1;

	inline function set_fov(value:Float) {
		if (value != fov) {
			fov = value;
			zoom = fov * scale;
			update();
		}
		return value;
	}

	function new(x:Int, y:Int, w:Int, h:Int, c:Color) {
		super(x, y, w, h, c);

		scroll.update = update;
	}

	function update() {
		var scrollShiftMult = zoom - scale;
		xOffset = -scroll.x - ((Main.INITIAL_WIDTH >> 1) * scrollShiftMult);
		yOffset = -scroll.y - ((Main.INITIAL_HEIGHT >> 1) * scrollShiftMult);
	}

	function renderFB() {
		// TODO: Implement this
	}

	function shake(x:Float, y:Float) {
		if (x == 0) return;
		var shakeX = Math.random() * (x * 16);
		xOffset += shakeX;
		if (y == 0) return;
		var shakeY = Math.random() * (x * 16);
		yOffset += shakeY;
	}
}