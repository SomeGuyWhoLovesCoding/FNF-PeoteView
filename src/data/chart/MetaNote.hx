package data.chart;

#if !debug
@:noDebug
#end
@:publicFields
abstract MetaNote(Int64) from Int64 to Int64 {
	// Masks and shifts
	static var SHIFT_POSITION = 24;
	static var SHIFT_DURATION = 12;
	static var SHIFT_INDEX    = 8;
	static var SHIFT_TYPE     = 3;
	static var SHIFT_FLAG     = 2;
	static var SHIFT_MISSED   = 1;
	static var SHIFT_HELD     = 0;

	static var POSITION_MASK = (Int64.shl(Int64.ofInt(1), 40) - Int64.ofInt(1));
	static var DURATION_MASK = 0xFFF; // 12 bits
	static var INDEX_MASK    = 0xF;   // 4 bits
	static var TYPE_MASK     = 0x1F;  // 5 bits

	static var POSITION_OVERFLOWHANDLEVALUE = metaNotePositionToSongTime(POSITION_MASK+1, false);

	// Constructor
	inline function new(position:Int64, duration:Int, index:Int, type:Int, flag:Bool = false, missed:Bool = false, held:Bool = false) {
		this =
			((position & POSITION_MASK) << SHIFT_POSITION) |
			(Int64.ofInt(duration & DURATION_MASK) << SHIFT_DURATION) |
			(Int64.ofInt(index & INDEX_MASK)    << SHIFT_INDEX)    |
			(Int64.ofInt(type & TYPE_MASK)     << SHIFT_TYPE)     |
			(Int64.ofInt(flag   ? 1 : 0) << SHIFT_FLAG) |
			(Int64.ofInt(missed ? 1 : 0) << SHIFT_MISSED) |
			Int64.ofInt(held    ? 1 : 0);
	}

	// Immutable core fields
	var position(get, never):Int64;
	var duration(get, never):Int;
	var index(get, never):Int;
	var type(get, never):Int;

	// Mutable booleans
	var flag(get, set):Bool;
	var missed(get, set):Bool;
	var held(get, set):Bool;

	// Getters
	inline function get_position():Int64 {
		var pos:Int64 = ((this >> SHIFT_POSITION) & POSITION_MASK);
		return pos;
	}

	inline function get_duration():Int {
		var v:Int64 = (this >> SHIFT_DURATION) & Int64.ofInt(DURATION_MASK);
		return v.low;
	}
	inline function get_index():Int {
		var v:Int64 = (this >> SHIFT_INDEX) & Int64.ofInt(INDEX_MASK);
		return v.low;
	}
	inline function get_type():Int {
		var v:Int64 = (this >> SHIFT_TYPE) & Int64.ofInt(TYPE_MASK);
		return v.low;
	}
	inline function get_flag():Bool {
		return (((this >> SHIFT_FLAG) & Int64.ofInt(1)).low != 0);
	}
	inline function get_missed():Bool {
		return (((this >> SHIFT_MISSED) & Int64.ofInt(1)).low != 0);
	}
	inline function get_held():Bool {
		return ((this & Int64.ofInt(1)).low != 0);
	}

	// Setters
	inline function set_flag(value:Bool):Bool {
		var mask:Int64 = Int64.ofInt(1) << SHIFT_FLAG;
		this = (this & ~mask) | (Int64.ofInt(value ? 1 : 0) << SHIFT_FLAG);
		return value;
	}

	inline function set_missed(value:Bool):Bool {
		var mask:Int64 = Int64.ofInt(1) << SHIFT_MISSED;
		this = (this & ~mask) | (Int64.ofInt(value ? 1 : 0) << SHIFT_MISSED);
		return value;
	}

	inline function set_held(value:Bool):Bool {
		var mask:Int64 = Int64.ofInt(1) << SHIFT_HELD;
		this = (this & ~mask) | (Int64.ofInt(value ? 1 : 0) << SHIFT_HELD);
		return value;
	}

	//// NUMBER CONVERSION FUNCTIONS
	inline static function floatToMetaNotePosition(f:Float):Int64 {
		return Tools.betterInt64FromFloat(f * 20000);
	}

	inline static function metaNotePositionToSongTime(pos:Int64, __overflowHandle:Bool = true):Float {
		var isNegative = pos < 0;
		var absPos = isNegative ? -pos : pos;

		var scaled:Int64 = absPos / 20000;
		var remainder:Int64 = absPos % 20000;

		var result = Tools.int64ToFloat(scaled) + Tools.int64ToFloat(remainder) / 20000;

		return isNegative ? -result : result;
	}

	inline static function intToMetaNoteDuration(i:Int):Int64 {
		return floatToMetaNotePosition(i * 4);
	}

	inline static function floatDurationToInt(i:Float):Int {
		return Std.int(i / 4);
	}

	// Underlying value
	inline function toNumber():Int64 return this;
}