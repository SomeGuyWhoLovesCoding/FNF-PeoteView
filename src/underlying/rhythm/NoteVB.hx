package underlying.rhythm;

/**
 * v3.9.0 — the draw pass's two scratch structs (formerly the virtual
 * note buffer's pooled objects; the 3D per-(lane,index) lists, slot
 * arrays and buffers are GONE — that state now lives in the chart
 * extern's GTFR arenas, and drawNote BINDS there when it finishes).
 *
 * Exactly ONE pair exists on NoteSystem (`drawScratchNote` /
 * `drawScratchSustain`), reused for every note of every frame: the
 * behavior pass fills them, then GTFR_BIND_NOTE / GTFR_BIND_SUSTAIN
 * packs the values into the extern's packed, grow-only arena. Zero
 * steady-state allocation; zero boxing (the structs are @:struct
 * stack values).
 *
 * Field semantics are the old VirtualNote/VirtualSustain ones minus
 * the pooling state (notesInOne moved to the arena's packed flags).
 * @since Development
**/
#if cpp
@:unreflective
#end
@:publicFields
@:struct
class VirtualNote {
	var initialAlpha:Float;
	var addedAlpha:Float;
	var scale:Float;
	var Sx:Int;
	var Sy:Int;
	var diff:Int;
	var globalIndex:Int64;

	inline function new(diff:Int, Sx:Int, Sy:Int) {
		this.diff = diff;
		this.Sx = Sx;
		this.Sy = Sy;
	}
}

/**
 * The sustain half of the scratch pair (see VirtualNote above).
 * @since Development
**/
#if cpp
@:unreflective
#end
@:publicFields
@:struct
class VirtualSustain {
	var alpha:Float;
	var scale:Float;
	var speed:Float;
	var length:Int;
	var r:Float;
	var diff:Int;
	var Sx:Int;
	var Sy:Int;
	var w:Int;
	var h:Int;
	/** The owning note (the scratch note this sustain belongs to). */
	var ref:VirtualNote;

	inline function new(Sx:Int, Sy:Int, w:Int, h:Int) {
		this.Sx = Sx;
		this.Sy = Sy;
		this.w = w;
		this.h = h;
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
}
