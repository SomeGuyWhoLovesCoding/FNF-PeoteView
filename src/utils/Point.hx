package utils;

/**
	* 2 dimensional point class with the update callback.
	* @since Development
**/
#if cpp
@:unreflective
#end
@:structInit
@:publicFields
class Point {
	@:optional var update:Void->Void;
	@:optional var isSmooth:Bool;

	@:optional var xLerp(default, null):Float;
	var x(default, set):Float;

	inline function set_x(value:Float) {
		if (value != x) {
			if (!isSmooth) x = value;
			else {
				xLerp = value;
				x = Tools.lerp(x, xLerp, 0.875);
			}
			if (update != null) update();
		}
		return value;
	}

	@:optional var yLerp(default, null):Float;
	var y(default, set):Float;

	inline function set_y(value:Float) {
		if (value != y) {
			if (!isSmooth) y = value;
			else {
				yLerp = value;
				y = Tools.lerp(y, yLerp, 0.875);
			}
			if (update != null) update();
		}
		return value;
	}
}
