package data.chart;

/**
	The note from the chart.
	Written by SomeGuyWhoLovesCoding, fixed and tweaked by Dimensionscape.
**/
#if !debug
@:noDebug
#end
@:publicFields
abstract MetaNote(Int64) from Int64 to Int64 {
	/**
		The position's bit mask.
	**/
	static var POSITION_MASK:Int64 = Int64.fromFloat(2199023255551);

	/**
		Construct a meta note.
		@param position The note's position.
		@param duration The note's duration.
		@param index The note's index.
		@param type The note's type.
		@param lane The note's lane.
	**/
	inline function new(position:Int64, duration:Int, index:Int, type:Int, lane:Int) {
		this = (position << 23) | (duration << 10) | (index << 6) | (type << 2) | lane;
	}

	/**
		The note's position. 41 bits so it fits the 10 microsecond granularity.
		Assigns the note's visual representation of the hold note with the length.
	**/
	var position(get, never):Int64;

	/**
		The note's hold duration. 13 bits. 5ms granularity.
		Assigns its visual representation of the hold note.
	**/
	var duration(get, never):Int;

	/**
		The note's index. 4 bits.
		Where the note should spawn at.
	**/
	var index(get, never):Int;

	/**
		The note's type. 4 bits.
		What type the note should be, if a notetype index is set.
	**/
	var type(get, never):Int;

	/**
		The note's strumline lane. 2 bits.
		Specifies the position of the note it's assigned to.
	**/
	var lane(get, never):Int;

	/**
		Get the note's position.
		Assigns the note's visual representation of the hold note with the length.
	**/
	inline function get_position():Int64 {
		return (this >> 23) & POSITION_MASK; // Mask 41 bits
	}

	/**
		Get the note's hold duration.
		Assigns its visual representation of the hold note.
	**/
	inline function get_duration():Int {
		return ((this.low:Int) >> 10) & 0x1FFF; // Mask 13 bits
	}

	/**
		Get the note's index.
		Specifies the position of the note it's assigned to.
	**/
	inline function get_index():Int {
		return ((this.low:Int) >> 6) & 0xF; // Mask 4 bits
	}

	/**
		Get the note's type.
		What type the note should be, if a notetype index is set.
	**/
	inline function get_type():Int {
		return ((this.low:Int) >> 2) & 0xF; // Mask 4 bits
	}

	/**
		Get the note's strumline lane.
		Where the note should spawn at.
	**/
	inline function get_lane():Int {
		return (this.low:Int) & 0x3; // Get the last 2 bits for lane
	}

	/**
		Get the underlying type.
	**/
	inline function toNumber():Int64 {
		return this;
	}
}