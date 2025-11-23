package data.gameplay;

/*@:publicFields
class AccuracyVariables {
	static inline var INCREMENT:Int128 = 10000;
	static inline var ZERO:Int128 = 0;
}*/

@:publicFields
abstract Accuracy(Array<Int128>) {
	var left(get, never):Int128;

	inline function get_left() {
		return this[0];
	}

	var right(get, never):Int128;

	inline function get_right() {
		return this[1];
	}

	inline function increment(value:Int128, missed:Bool = false, count:Int128) {
		if (!missed) this[0] += value * count;
		this[1] += count;
	}

	function new() {
		this = [0, 0];
	}

	function toString():String {
		var denominator = right == Int128.ofInt(0) ? Int128.ofInt(10000) : right;
		var calc = left / denominator;

		var str = Std.string(Int128.toInt(calc));
		if (str.length < 3) str = StringTools.lpad(str, "0", 3); // ensure at least 3 digits

		var firstHalf = str.substr(0, str.length - 2);
		var secondHalf = str.substr(str.length - 2, 2);

		return '${firstHalf.length == 0 ? "0" : firstHalf}.${secondHalf}%';
	}
}