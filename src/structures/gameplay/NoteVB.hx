package structures.gameplay;

/**
 * Note virtual buffer to check the range of note "elements" that need to be rendered,
 * in order to do more complex optimization tricks like "greedy note merging".
 * The fake note overlap really helps solidify things, since you
 * don't normally render more than a million sprites anyway.
 * @since Development
**/
@:publicFields
class NoteVB {
	/**
	 * 3 dimensional note lengths, for convenience.
	**/
	var noteLength(default, null):Array<Array<Int>>;

	/**
	 * 3 dimensional sustain lengths, for convenience.
	**/
	var sustainLength(default, null):Array<Array<Int>>;

	/**
	 * This array and the one below are not meant to be touched. They are just a small virtual buffer meant to grow continuously if the rendered note count ever reaches above `length`.
	 * And yes, they are 3 dimensional so they're easy to make note jack optimizations out of.
	**/
	var sustains(default, null):Array<Array<Array<VirtualSustain>>>;

	var notes(default, null):Array<Array<Array<VirtualNote>>>;

	/**
	 * Initializes the virtual note and sustain buffer.
	**/
	function new(lanes:Int, indexes:Int) {
		notes = [];
		sustains = [];
		noteLength = [];
		sustainLength = [];
		for (lane in 0...lanes) {
			notes[lane] = [];
			sustains[lane] = [];
			noteLength[lane] = [];
			sustainLength[lane] = [];
			for (idx in 0...indexes) {
				notes[lane][idx] = [];
				sustains[lane][idx] = [];
				noteLength[lane][idx] = 0;
				sustainLength[lane][idx] = 0;
			}
		}
	}

	/**
	 * @param note The virtual note you want to add.
	**/
	inline function addNote(note:VirtualNote) {
		var ref = note.ref;
		var lane = ref.type;
		notes[lane][ref.index][
			noteLength[note.ref.type][ref.index]
		] = note;
		noteLength[note.ref.type][ref.index]++;
	}

	/**
	 * @param note The virtual note you want to add.
	**/
	inline function addSustain(sustain:VirtualSustain, note:VirtualNote) {
		var ref = note.ref;
		var lane = ref.type;
		sustains[note.ref.type][ref.index][
			sustainLength[note.ref.type][ref.index]
		] = sustain;
		sustainLength[note.ref.type][ref.index]++;
	}

	function clear() {
    	for (i in 0...noteLength.length)
			for (j in 0...noteLength[i].length)
				noteLength[i][j] = 0;

		for (i in 0...sustainLength.length)
			for (j in 0...sustainLength[i].length)
				sustainLength[i][j] = 0;
	}
}

/**
 * Virtual note that acts like a pre-render of a the note element. 52-byte class.
 * @since Development
**/
@:publicFields
class VirtualNote {
	// the amount of same notes within a line, combined (8 bytes)
	var notesInOne:Int64;

	// the initial alpha of the note (8 bytes)
	var initialAlpha:Float;

	// the alpha of same notes within a line, combined (8 bytes)
	var addedAlpha:Float;

	// the scale of the note (8 bytes)
	var scale:Float;

	// the refrence to the note (8 bytes)
	var ref:MetaNote;

	// helpers (put these where convenient)
	inline static function toSigned16(u:Int):Int {
		var v = u & 0xFFFF;
		// if high bit set, subtract 0x10000 (65536) to sign-extend
		return (v & 0x8000) != 0 ? (v - 0x10000) : v;
	}

	inline static function toUint16(s:Int):Int {
		return s & 0xFFFF;
	}

	// position (4 bytes)
	var xy:Int;
	var x(get, set):Int;
	var y(get, set):Int;

	inline function get_x():Int {
		return toSigned16(xy & 0xFFFF);
	}

	inline function set_x(value:Int):Int {
		var u = toUint16(value);
		xy = (xy & 0xFFFF0000) | u;
		return value;
	}

	inline function get_y():Int {
		return toSigned16((xy >> 16) & 0xFFFF);
	}

	inline function set_y(value:Int):Int {
		var u = toUint16(value);
		xy = (xy & 0x0000FFFF) | (u << 16);
		return value;
	}

	// size (4 bytes)
	var wh:Int;
	var w(get, set):Int; // width
	var h(get, set):Int; // height

	inline function get_w():Int {
		return toSigned16(wh & 0xFFFF);
	}

	inline function set_w(value:Int):Int {
		var u = toUint16(value);
		wh = (wh & 0xFFFF0000) | u;
		return value;
	}

	inline function get_h():Int {
		return toSigned16((wh >> 16) & 0xFFFF);
	}

	inline function set_h(value:Int):Int {
		var u = toUint16(value);
		wh = (wh & 0x0000FFFF) | (u << 16);
		return value;
	}

	// once preparation is done, this stuff is used (4 bytes)
	var tm:Int;
	var greedyMergeType(get, set):Int;
	var greedyMergeAlphaMultiplier(get, set):Int;

	inline function get_greedyMergeType():Int {
		return toSigned16(xy & 0xFFFF);
	}

	inline function set_greedyMergeType(value:Int):Int {
		var u = toUint16(value);
		tm = (tm & 0xFFFF0000) | u;
		return value;
	}

	inline function get_greedyMergeAlphaMultiplier():Int {
		return toSigned16((tm >> 16) & 0xFFFF);
	}

	inline function set_greedyMergeAlphaMultiplier(value:Int):Int {
		var u = toUint16(value);
		tm = (tm & 0x0000FFFF) | (u << 16);
		return value;
	}

	inline function new(x:Int, y:Int, w:Int, h:Int) {
		this.x = x;
		this.y = y;
		this.w = w;
		this.h = h;
	}
}

/**
 * Virtual sustain that acts like a pre-render of a the sustain element. 76-byte class since there's a reference in it.
 * @since Development
**/
@:publicFields
class VirtualSustain {
	// the alpha of sustain (8 bytes)
	var alpha:Float;

	// the scale of the sustain (8 bytes)
	var scale:Float;

	// the speed of the sustain (8 bytes)
	var speed:Float;

	// the duration of the sustain (4 bytes)
	var length:Int;

	// the reference to the sustain (40 bytes)
	var ref:VirtualNote;

	// the rotation of the sustain (8 bytes)
	var r:Float;

	// helpers (put these where convenient)
	inline static function toSigned16(u:Int):Int {
		var v = u & 0xFFFF;
		// if high bit set, subtract 0x10000 (65536) to sign-extend
		return (v & 0x8000) != 0 ? (v - 0x10000) : v;
	}

	inline static function toUint16(s:Int):Int {
		return s & 0xFFFF;
	}

	// position (4 bytes)
	var xy:Int;
	var x(get, set):Int;
	var y(get, set):Int;

	inline function get_x():Int {
		return toSigned16(xy & 0xFFFF);
	}

	inline function set_x(value:Int):Int {
		var u = toUint16(value);
		xy = (xy & 0xFFFF0000) | u;
		return value;
	}

	inline function get_y():Int {
		return toSigned16((xy >> 16) & 0xFFFF);
	}

	inline function set_y(value:Int):Int {
		var u = toUint16(value);
		xy = (xy & 0x0000FFFF) | (u << 16);
		return value;
	}

	// size (4 bytes)
	var wh:Int;
	var w(get, set):Int; // width
	var h(get, set):Int; // height

	inline function get_w():Int {
		return toSigned16(wh & 0xFFFF);
	}

	inline function set_w(value:Int):Int {
		var u = toUint16(value);
		wh = (wh & 0xFFFF0000) | u;
		return value;
	}

	inline function get_h():Int {
		return toSigned16((wh >> 16) & 0xFFFF);
	}

	inline function set_h(value:Int):Int {
		var u = toUint16(value);
		wh = (wh & 0x0000FFFF) | (u << 16);
		return value;
	}

	/**
	 * This function anchors the sustain directly to the parent.
	 * `c` = Center
	 * @param cX Center X.
	 * @param cY Center Y.
	 * @param index Index. 
	 */
	inline public function followNote(cX:Int, cY:Int, id:Int) {
		var offset = Sustain.offsets[id];
		x = cX + (Math.floor(offset[0] * scale) >> 1);
		y = cY + (Math.floor(offset[1] * scale) >> 1);
	}

	inline function new(x:Int, y:Int, w:Int, h:Int) {
		this.x = x;
		this.y = y;
		this.w = w;
		this.h = h;
	}
}