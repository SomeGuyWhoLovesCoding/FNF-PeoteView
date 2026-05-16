package elements;

/**
	CustomDisplay is a custom class that extends RotatableDisplay.
	It adds a few extra properties to the Display class (such as scroll, scale, and fov), and most importantly, automatic rotating support at the vertex level,
	as described in RotatableDisplay.
	@since Development
**/
@:publicFields
class CustomDisplay extends RotatableDisplay {
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

	var r(get, set):Float;

	inline function get_r() {
		return this.rotation;
	}

	inline function set_r(value:Float) {
		return this.rotation = value;
	}

	override function set_rotation(deg:Float):Float {
		var result = super.set_rotation(deg);
		update();
		return result;
	}

	function new(x:Int, y:Int, w:Int, h:Int, c:Color) {
		super(x, y, w, h, c);

		scroll.update = update;
	}

	function update() {
		var scrollShiftMult = zoom - scale;

		// Rotate the scroll offset by the display angle
		var scrollX = scroll.x;
		var scrollY = scroll.y;
		var rotatedScrollX = uCos.value * scrollX - uSin.value * scrollY;
		var rotatedScrollY = uSin.value * scrollX + uCos.value * scrollY;

		xOffset = -rotatedScrollX - ((Main.INITIAL_WIDTH  >> 1) * scrollShiftMult);
		yOffset = -rotatedScrollY - ((Main.INITIAL_HEIGHT >> 1) * scrollShiftMult);

		uCenter.value = [((Main.VARIABLE_WIDTH  >> 1) - xOffset) / zoom, ((Main.VARIABLE_HEIGHT >> 1) - yOffset) / zoom];
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