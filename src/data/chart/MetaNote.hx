package data.chart;

#if !debug
@:noDebug
#end
@:publicFields
abstract MetaNote(Int64) from Int64 to Int64 {
	// Masks and shifts matching C++ layout
	static var SHIFT_POSITION = 0;   // 30 bits: bits 0-29
	static var SHIFT_DURATION = 30;  // 16 bits: bits 30-45
	static var SHIFT_INDEX    = 46;  // 8 bits: bits 46-53
	static var SHIFT_TYPE     = 54;  // 7 bits: bits 54-60
	static var SHIFT_FLAG     = 61;  // 1 bit: bit 61
	static var SHIFT_MISSED   = 62;  // 1 bit: bit 62
	static var SHIFT_HELD     = 63;  // 1 bit: bit 63

	static var POSITION_MASK = 0x3FFFFFFF; // 30 bits
	static var DURATION_MASK = 0xFFFF;     // 16 bits
	static var INDEX_MASK    = 0xFF;       // 8 bits
	static var TYPE_MASK     = 0x7F;       // 7 bits

	// Constructor
	inline function new(position:Int64, duration:Int, index:Int, type:Int, flag:Bool = false, missed:Bool = false, held:Bool = false) {
		this =
			((position & POSITION_MASK) << SHIFT_POSITION) |
			(Int64.ofInt(duration & DURATION_MASK) << SHIFT_DURATION) |
			(Int64.ofInt(index & INDEX_MASK) << SHIFT_INDEX) |
			(Int64.ofInt(type & TYPE_MASK) << SHIFT_TYPE) |
			(Int64.ofInt(flag ? 1 : 0) << SHIFT_FLAG) |
			(Int64.ofInt(missed ? 1 : 0) << SHIFT_MISSED) |
			(Int64.ofInt(held ? 1 : 0) << SHIFT_HELD);
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
		return (this >> SHIFT_POSITION) & POSITION_MASK;
	}

	inline function get_duration():Int {
		return ((this >> SHIFT_DURATION) & DURATION_MASK).low;
	}
	
	inline function get_index():Int {
		return ((this >> SHIFT_INDEX) & INDEX_MASK).low;
	}
	
	inline function get_type():Int {
		return ((this >> SHIFT_TYPE) & TYPE_MASK).low;
	}
	
	inline function get_flag():Bool {
		return ((this >> SHIFT_FLAG) & 1) != 0;
	}
	
	inline function get_missed():Bool {
		return ((this >> SHIFT_MISSED) & 1) != 0;
	}
	
	inline function get_held():Bool {
		return ((this >> SHIFT_HELD) & 1) != 0;
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

	// Time conversion - IMPORTANT: position is in 1/4 nanosecond ticks
	// 1 second = 4,000,000,000 ticks
	// 1 millisecond = 4,000,000 ticks
	static var TICKS_PER_SECOND:Int64 = Tools.betterInt64FromFloat(4000000000);
	static var TICKS_PER_MS:Int64 = 4000000;
	static var TICKS_PER_MS_FLOAT:Float = 4000000.0;
	
	// Convert song time (ms) to position ticks
	inline static function floatToMetaNotePosition(f:Float):Int64 {
		return Tools.betterInt64FromFloat(f * TICKS_PER_MS_FLOAT);
	}

	// Convert position ticks to song time (ms)
	inline static function metaNotePositionToSongTime(pos:Int64):Float {
		var isNegative = pos < 0;
		var absPos = isNegative ? -pos : pos;

		var scaled:Int64 = absPos / 4000000;
		var remainder:Int64 = absPos % 4000000;

		var result = Tools.int64ToFloat(scaled) + Tools.int64ToFloat(remainder) / TICKS_PER_MS_FLOAT;

		return isNegative ? -result : result;
	}

	inline static function intToMetaNoteDuration(i:Int):Int64 {
		return Int64.ofInt(i) * TICKS_PER_MS;
	}

	inline static function floatDurationToInt(i:Float):Int {
		return Std.int(i / TICKS_PER_MS_FLOAT);
	}

	inline function toNumber():Int64 return this;
}