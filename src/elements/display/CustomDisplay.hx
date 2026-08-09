package elements.display;

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

	var centerArr:Array<Float>;

	var shakeX:Float = 0;
	var shakeY:Float = 0;

	function new(x:Int, y:Int, w:Int, h:Int, c:Color) {
		super(x, y, w, h, c);
		centerArr = [0.0, 0.0];
		scroll.update = update;
	}

	function update() {
		if (zoom <= 0)
			return; // doesn't prevent crash happening from after the trace "6" which is the `Main` `resize` function but that doesn't matter anymore anyway

		var scrollShiftMult = zoom - scale;

		var scrollX = scroll.x;
		var scrollY = scroll.y;
		var rotatedScrollX = uSin.value.x * scrollX - uSin.value.y * scrollY;
		var rotatedScrollY = uSin.value.y * scrollX + uSin.value.x * scrollY;

		xOffset = -rotatedScrollX - ((Main.INITIAL_WIDTH >> 1) * scrollShiftMult) + shakeX;
		yOffset = -rotatedScrollY - ((Main.INITIAL_HEIGHT >> 1) * scrollShiftMult) + shakeY;

		// FIX: Reuse the pre-allocated array
		centerArr[0] = ((Main.VARIABLE_WIDTH >> 1) - xOffset) / zoom;
		centerArr[1] = ((Main.VARIABLE_HEIGHT >> 1) - yOffset) / zoom;
		uCenter.value = centerArr;
	}

	function shake(x:Float, y:Float) {
		// FIX: Store shake values to be applied in update()
		if (x != 0)
			shakeX = (Math.random() - 0.5) * (x * 16);
		if (y != 0)
			shakeY = (Math.random() - 0.5) * (y * 16);
	}

	// FIX: Pre-allocate shake point
	static var shakePoint:Point = {x: 0, y: 0};

	function shakeValue(x:Float, y:Float):Point {
		if (x == 0 || y == 0) {
			shakePoint.x = 0;
			shakePoint.y = 0;
			return shakePoint;
		}
		shakePoint.x = (Math.random() - 0.5) * (x * 16);
		shakePoint.y = (Math.random() - 0.5) * (y * 16);
		return shakePoint;
	}
}
