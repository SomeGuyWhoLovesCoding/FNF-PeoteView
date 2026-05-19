package data.chart;

#if !debug
@:noDebug
#end
@:publicFields
abstract MetaNote(Int64) from Int64 to Int64 {
	// Masks and shifts matching C++ layout
	static var SHIFT_POSITION = 0;   // 30 bits: bits 0-31
	static var SHIFT_DURATION = 32;  // 16 bits: bits 32-47
	static var SHIFT_INDEX    = 48;  // 8 bits: bits 48-55
	static var SHIFT_TYPE     = 56;  // 8 bits: bits 56-63

	static var POSITION_MASK = 0xFFFFFFFF; // 32 bits
	static var DURATION_MASK = 0xFFFF;     // 16 bits
	static var INDEX_MASK    = 0xFF;       // 8 bits
	static var TYPE_MASK     = 0xFF;       // 8 bits

	// Constructor
	inline function new(position:Int64, duration:Int, index:Int, type:Int) {
		this =
			((position & POSITION_MASK) << SHIFT_POSITION) |
			(Int64.ofInt(duration & DURATION_MASK) << SHIFT_DURATION) |
			(Int64.ofInt(index & INDEX_MASK) << SHIFT_INDEX) |
			(Int64.ofInt(type & TYPE_MASK) << SHIFT_TYPE);
	}

	// Immutable fields
	var position(get, never):Int64;
	var duration(get, never):Int;
	var index(get, never):Int;
	var type(get, never):Int;

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

	//// NUMBER CONVERSION FUNCTIONS

	// Time conversion - IMPORTANT: position is in 1/16 nanosecond ticks
	// 1 second = 16,000,000,000 ticks
	// 1 millisecond = 16,000,000 ticks
	static var TICKS_PER_SECOND:Int64 = Tools.betterInt64FromFloat(4000000000);
	static var TICKS_PER_MS:Int64 = 16000000;
	static var TICKS_PER_MS_FLOAT:Float = 16000000.0;
	static var DURATION_TICKS_PER_MS:Int64 = 16000000;
	static var DURATION_TICKS_PER_MS_FLOAT:Float = 16000000.0;
	
	// Convert song time (ms) to position ticks
	inline static function floatToMetaNotePosition(f:Float):Int64 {
		return Tools.betterInt64FromFloat(f * TICKS_PER_MS_FLOAT);
	}

	// Convert position ticks to song time (ms)
	inline static function metaNotePositionToSongTime(pos:Int64):Float {
		var isNegative = pos < 0;
		var absPos = isNegative ? -pos : pos;

		var scaled:Int64 = absPos / TICKS_PER_MS;
		var remainder:Int64 = absPos % TICKS_PER_MS;

		var result = Tools.int64ToFloat(scaled) + Tools.int64ToFloat(remainder) / TICKS_PER_MS_FLOAT;

		return isNegative ? -result : result;
	}

	inline static function intToMetaNoteDuration(i:Int):Int64 {
		return Int64.ofInt(i) * DURATION_TICKS_PER_MS;
	}

	inline static function floatDurationToInt(i:Float):Int {
		return Std.int(i / DURATION_TICKS_PER_MS_FLOAT);
	}

	inline function toNumber():Int64 return this;
}