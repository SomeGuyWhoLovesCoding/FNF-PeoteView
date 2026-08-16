package rhythm;

/**
 * Note virtual buffer to check the range of note "elements" that need to be rendered,
 * in order to do an optimization trick like "ambient note occlusion" for you, with some visual tricks.
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
		notes[lane][ref.index][noteLength[note.ref.type][ref.index]] = note;
		noteLength[note.ref.type][ref.index]++;
	}

	/**
	 * @param note The virtual note you want to add.
	**/
	inline function addSustain(sustain:VirtualSustain, note:VirtualNote) {
		var ref = note.ref;
		var lane = ref.type;
		sustains[note.ref.type][ref.index][sustainLength[note.ref.type][ref.index]] = sustain;
		sustainLength[note.ref.type][ref.index]++;
	}

	// BOTTLENECK: low per-frame full re-scan+zero of all lane×index length arrays (2×256×2 writes) even when few notes are active | FIX: track touched (lane,index) slots and only clear those
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
 * This object is the POD of the note element. 56-byte class.
 * @since Development
**/
#if cpp
@:unreflective
#end
@:publicFields
@:struct
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

	// the global index branching down to the note (8 bytes)
	// note: this had to be implemented as a result of a flaw that had to be fixed in the new judgement implementation on the way.
	var globalIndex:Int64;

	// the note diff relative to strum time (4 bytes)
	var diff:Int;

	// the current strum position
	var Sxy:Int;
	var Sx(get, set):Int;
	var Sy(get, set):Int;

	// helpers (put these where convenient)
	inline static function toSigned16(u:Int):Int {
		var v = u & 0xFFFF;
		// if high bit set, subtract 0x10000 (65536) to sign-extend
		return (v & 0x8000) != 0 ? (v - 0x10000) : v;
	}

	inline static function toUint16(s:Int):Int {
		return s & 0xFFFF;
	}

	inline function get_Sx():Int {
		return toSigned16(Sxy & 0xFFFF);
	}

	inline function set_Sx(value:Int):Int {
		var u = toUint16(value);
		Sxy = (Sxy & 0xFFFF0000) | u;
		return value;
	}

	inline function get_Sy():Int {
		return toSigned16((Sxy >> 16) & 0xFFFF);
	}

	inline function set_Sy(value:Int):Int {
		var u = toUint16(value);
		Sxy = (Sxy & 0x0000FFFF) | (u << 16);
		return value;
	}

	inline function new(diff:Int, Sx:Int, Sy:Int) {
		this.diff = diff;
		this.Sx = Sx;
		this.Sy = Sy;
	}
}

/**
 * This object is a POD of the sustain element. 72-byte class since there's a reference in it.
 * @since Development
**/
#if cpp
@:unreflective
#end
@:publicFields
@:struct
class VirtualSustain {
	// the alpha of sustain (8 bytes)
	var alpha:Float;

	// the scale of the sustain (8 bytes)
	var scale:Float;

	// the speed of the sustain (8 bytes)
	var speed:Float;

	// the duration of the sustain (4 bytes)
	var length:Int;

	// the reference to the sustain (56 bytes)
	var ref:VirtualNote;

	// the rotation of the sustain (8 bytes)
	var r:Float;

	// the note diff relative to strum time (4 bytes)
	var diff:Int;

	// the current strum position
	var Sxy:Int;
	var Sx(get, set):Int;
	var Sy(get, set):Int;

	// helpers (put these where convenient)
	inline static function toSigned16(u:Int):Int {
		var v = u & 0xFFFF;
		// if high bit set, subtract 0x10000 (65536) to sign-extend
		return (v & 0x8000) != 0 ? (v - 0x10000) : v;
	}

	inline static function toUint16(s:Int):Int {
		return s & 0xFFFF;
	}

	inline function get_Sx():Int {
		return toSigned16(Sxy & 0xFFFF);
	}

	inline function set_Sx(value:Int):Int {
		var u = toUint16(value);
		Sxy = (Sxy & 0xFFFF0000) | u;
		return value;
	}

	inline function get_Sy():Int {
		return toSigned16((Sxy >> 16) & 0xFFFF);
	}

	inline function set_Sy(value:Int):Int {
		var u = toUint16(value);
		Sxy = (Sxy & 0x0000FFFF) | (u << 16);
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
		Sx = cX;
		Sy = cY;
	}

	inline function new(Sx:Int, Sy:Int, w:Int, h:Int) {
		this.Sx = Sx;
		this.Sy = Sy;
		this.w = w;
		this.h = h;
	}
}
