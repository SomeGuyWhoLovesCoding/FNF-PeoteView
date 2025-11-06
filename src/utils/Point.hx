package utils;

/**
	2 dimensional point class with the update callback.
**/
#if cpp
@:unreflective
#end
@:structInit
@:publicFields
class Point {
	@:optional var update:Void->Void;

	var x(default, set):Float;

	inline function set_x(value:Float) {
		if (value != x) {
			x = value;
			if (update != null) update();
		}
		return value;
	}

	var y(default, set):Float;

	inline function set_y(value:Float) {
		if (value != y) {
			y = value;
			if (update != null) update();
		}
		return value;
	}
}
