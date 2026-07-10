package data.chart;

/**
 * This is the source of the single note element at the chart format.
 * It's that small. 8 byte chart format.
 * @since Development
 */
#if !debug
@:noDebug
#end
@:publicFields
abstract MetaNote(MetaNoteImpl) from MetaNoteImpl to MetaNoteImpl {
	// Masks and shifts matching C++ layout
	static var SHIFT_POSITION = 0;   // 48 bits: bits 0-47
	static var SHIFT_DURATION = 48;  // 16 bits: bits 49-63
	static var SHIFT_INDEX    = 64;  // 8 bits:  bits 64-71
	static var SHIFT_TYPE     = 72;  // 8 bits:  bits 72-79

	static var POSITION_MASK = Int64.sub(Int64.shl(Int64.ofInt(1), 48), Int64.ofInt(1)); 
	static var DURATION_MASK = 0xFFFF;    // 16 bits
	static var INDEX_MASK    = 0xFF;       // 8 bits
	static var TYPE_MASK     = 0xFF;       // 8 bits

	// Constructor
	inline function new(position:Int64, duration:Int, index:Int, type:Int) {
		// Pack into the low 64 bits
		var high:Int64 = (position & POSITION_MASK) | (Int64.ofInt(duration & DURATION_MASK) << SHIFT_DURATION);
		
		// Pack into the high 64 bits
		var low:Int = ((index >> (SHIFT_INDEX-64)) & INDEX_MASK) // upper 9 bits of duration
		              | ((type & TYPE_MASK) << (SHIFT_TYPE-64));      // type at bits 9-15
		
		this = new MetaNoteImpl(high, low); // Adjust parameter order if your library expects (low, high)
	}

	// Immutable core fields
	var position(get, never):Int64;
	var duration(get, never):Int;
	var index(get, never):Int;
	var type(get, never):Int;

	// Getters
	inline function get_position():Int64 {
		return (this.high & POSITION_MASK);
	}

	inline function get_duration():Int {
		return ((this.high >> SHIFT_DURATION) & DURATION_MASK).low;
	}

	inline function get_index():Int {
		return ((this.low >> SHIFT_INDEX-64) & INDEX_MASK);
	}

	inline function get_type():Int {
		return ((this.low >> SHIFT_TYPE-64) & TYPE_MASK);
	}

	// Time conversion - IMPORTANT: position is in 100 nanosecond ticks
	// 1 second = 100,000,000 ticks
	// 1 millisecond = 100,000 ticks
	// duration unit is 1ms, stored as ms integer in metanote position
	static var TICKS_PER_SECOND:Int64 = Tools.betterInt64FromFloat(100000000);
	static var TICKS_PER_MS:Int64 = 100000;
	static var TICKS_PER_MS_FLOAT:Float = 100000.0;

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

	// duration field is in 0.5ms units — convert to/from ticks accordingly
	inline static function intToMetaNoteDuration(i:Int):Int64 {
		return Int64.ofInt(i) * TICKS_PER_MS;
	}

	inline static function floatDurationToInt(i:Float):Int {
		return Std.int(i / TICKS_PER_MS_FLOAT);
	}
}

/**
 * The underlying struct implementation of the MetaNote class, to be specific.
 */
#if cpp
@:unreflective
#end
@:struct
class MetaNoteImpl {
	public var high:Int64;
	public var low:#if cpp cpp.UInt16 #elseif hl hl.UI16 #else Int #end;

	public inline function new(high, low) {
		this.high = high;
		this.low = low;
	}
}
