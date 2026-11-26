package underlying.data.chart;

/**
 * This is the source of the single note element at the chart format.
 * It's that small. 12 byte chart format (96 bits):
 *   [0..47]  position (100ns ticks)
 *   [48..71] duration (1ms ticks, 24-bit)
 *   [72..81] index (column within the strumline, 10-bit)
 *   [82..89] type (notetype, 8-bit)
 *   [90..95] lane (strumline id, 6-bit)
 * The lane is stored ON the note — the chart editor needs a per-note
 * lane property, and the format is the minimum element size that fits
 * these fields while staying 4-byte aligned.
 * @since Development
 */
@:publicFields
abstract MetaNote(MetaNoteImpl) from MetaNoteImpl to MetaNoteImpl {
	// Masks and shifts matching the C++ layout
	// first8: [0..47] position, [48..63] duration's LOW 16 bits
	static var SHIFT_POSITION = 0; // 48 bits: bits 0-47
	static var SHIFT_DURATION = 48; // low 16 bits: bits 48-63 (high 8 in last4)
	static var SHIFT_INDEX = 8; // 10 bits: last4 bits 8-17
	static var SHIFT_TYPE = 18; // 8 bits:  last4 bits 18-25
	static var SHIFT_LANE = 26; // 6 bits:  last4 bits 26-31
	static var SHIFT_DURATION_HIGH = 0; // high 8 bits of duration: last4 bits 0-7

	static var POSITION_MASK:Int64 = Int64.sub(Int64.shl(Int64.ofInt(1), 48), Int64.ofInt(1));
	static var DURATION_LOW_MASK:Int = 0xFFFF; // 16 bits of first8
	static var DURATION_HIGH_MASK:Int = 0xFF; // 8 bits of last4
	static var INDEX_MASK:Int = 0x3FF; // 10 bits
	static var TYPE_MASK:Int = 0xFF; // 8 bits
	static var LANE_MASK:Int = 0x3F; // 6 bits
	static var DURATION_MAX:Int = 0xFFFFFF; // 24-bit field, 16,777,215 ms

	// Constructor
	inline function new(position:Int64, duration:Int, index:Int, type:Int, lane:Int = -1) {
		// Pack into the low 64 bits
		var high:Int64 = (position & POSITION_MASK)
			| (Int64.ofInt(duration & DURATION_LOW_MASK) << SHIFT_DURATION);

		// Pack into the high 32 bits. lane defaults to the routing the
		// type implies (type 0 -> strumline 0 opponent, else 1 player) —
		// callers that KNOW the lane pass it explicitly.
		var laneVal:Int = (lane < 0) ? (type == 0 ? 0 : 1) : lane;
		var low:Int = (duration >>> 16) & DURATION_HIGH_MASK
			| ((index & INDEX_MASK) << SHIFT_INDEX)
			| ((type & TYPE_MASK) << SHIFT_TYPE)
			| ((laneVal & LANE_MASK) << SHIFT_LANE);

		this = new MetaNoteImpl(high, low);
	}

	// Immutable core fields
	var position(get, never):Int64;
	var duration(get, never):Int;
	var index(get, never):Int;
	var type(get, never):Int;
	var lane(get, never):Int;

	// Getters
	inline function get_position():Int64 {
		return (this.high & POSITION_MASK);
	}

	inline function get_duration():Int {
		return (Std.int((this.high >> SHIFT_DURATION).low) & DURATION_LOW_MASK)
			| ((this.low & DURATION_HIGH_MASK) << 16);
	}

	inline function get_index():Int {
		return (this.low >> SHIFT_INDEX) & INDEX_MASK;
	}

	inline function get_type():Int {
		return (this.low >> SHIFT_TYPE) & TYPE_MASK;
	}

	inline function get_lane():Int {
		return (this.low >> SHIFT_LANE) & LANE_MASK;
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

		//BOTTLENECK: mid Int64 division + modulo per note-time conversion; heavy when called per note per frame | FIX: single Float divide (ticks are 48-bit, no usable precision lost) or fixed-point with precomputed reciprocal
		var scaled:Int64 = absPos / TICKS_PER_MS;
		var remainder:Int64 = absPos % TICKS_PER_MS;

		var result = Tools.int64ToFloat(scaled) + Tools.int64ToFloat(remainder) / TICKS_PER_MS_FLOAT;

		return isNegative ? -result : result;
	}

	// duration field is in 1ms units — convert to/from ticks accordingly
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
	public var low:#if cpp cpp.UInt32 #elseif hl hl.UI32 #else Int #end;

	public inline function new(high, low) {
		this.high = high;
		this.low = low;
	}

	// v3.9.2: in-place field rewrite for the pooled window-note cache.
	// A pooled MetaNote is RE-SET to a newly entered note's packed fields
	// instead of being re-allocated — steady-state note-window handling
	// performs ZERO allocations on any target. Untyped args on purpose:
	// same signature shape as new(), call sites pass Int64/UInt32.
	public inline function set(high, low) {
		this.high = high;
		this.low = low;
	}
}
