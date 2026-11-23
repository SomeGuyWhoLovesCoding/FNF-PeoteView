package underlying.data.chart;

/**
 * @since Development
**/
#if cpp
import cpp.ConstCharStar;

@:buildXml('<include name="../../../chartFileBuild.xml" />')
@:unreflective @:keep
@:include("./include/chart_file.h")
extern class File {
	@:native("remap") static function remap(newLength:Int64):Bool;

	@:runtime inline static function loadChart(inFile:String):Void {
		var str = ConstCharStar.fromString(inFile);
		_loadChart(str);
	}
	@:native("loadChart") static function _loadChart(inFile:ConstCharStar):Void;
	@:native("getNote_first8") static function getNote_first8(atIndex:Int64):Int64;
	@:native("getNote_last4") static function getNote_last4(atIndex:Int64):Int64;
	@:runtime inline static function getNote(atIndex:Int64):MetaNote {
		return new MetaNote.MetaNoteImpl(getNote_first8(atIndex), Int64.toInt(getNote_last4(atIndex)));
	}
	@:native("insertNote") static function insertNote(atGlobalPosition:Int64, duration:Int, index:Int, type:Int):Void;
	/**
	 * Adds a note from its raw fields — the editor-facing API.
	 *   position: 100ns ticks (the unit MetaNote.position uses)
	 *   duration: 1ms ticks (0 = tap note; 24-bit field, max 16,777,215 ms)
	 *   index:    column index within the strumline (0..1023, 10-bit field)
	 *   type:     notetype — a pure skin/behavior id (NoteSystem.typeToHandle);
	 *             it does NOT decide where the note draws
	 *   lane:     strumline id STORED ON the note (0..63, 6-bit field) —
	 *             the note draws/judges on this strumline; placement
	 *             passes the hovered strumline, the transpiler the source
	 *             chart's side
	 * The C++ side locates the note's 1/4-second shard and its sorted slot
	 * from the position. Returns the new note's global chart index — pass
	 * it to removeNote() later.
	 */
	@:native("addNote") static function addNote(position:Int64, duration:Int, index:Int, type:Int, lane:Int):Int64;
	/** Removes the note with the given global chart index. */
	@:native("removeNote") static function removeNote(atIndex:Int64):Void;
	/** Writes the live sharded store back out as a .fvc snapshot. */
	@:native("saveChart") static function saveChart():Bool;
	@:native("getLength") static function getLength():Int64;
	@:native("destroyChart") static function destroyChart():Void;
	@:native("getJudgement") static function getJudgement(globalIndex:Int64):Bool;
	@:native("setJudgement") static function setJudgement(globalIndex:Int64, value:Bool):Void;
	@:native("getHitFlag") static function getHitFlag(globalIndex:Int64):Bool;
	@:native("setHitFlag") static function setHitFlag(globalIndex:Int64, value:Bool):Void;
	@:native("setEditorMode") static function setEditorMode(value:Bool):Void;

	/**
	 * The note's precomputed overlap-group size — the 4 extra bytes per
	 * chart note (runtime-only; the on-disk format is unchanged). 1 = the
	 * note stands alone; otherwise the number of notes its merged sprite
	 * represents (same strumline, receptor column, notetype, duration and
	 * quantized speed-2 timing row — see MetaNote.OVERLAP_ROW_TICKS).
	 * Every member of a group carries the same value, so any note of an
	 * overlapping sprite traces to the same predictable combo number.
	 */
	@:native("getNoteOverlapCount") static function getNoteOverlapCount(globalIndex:Int64):Int;

	/**
	 * Bulk accessor for the note spawner: a pointer into the persistent
	 * per-note overlap-count block, covering notes [startIndex, endIndex)
	 * — entries are uint32, 4 bytes per note. The block is one allocation
	 * that lives for the whole chart lifetime and is freed on chart
	 * destroy; the pointer stays valid until the next chart mutation
	 * (addNote/removeNote rebuild the counts), so callers refetch it per
	 * pass. Null when the range is empty or the block is unavailable.
	 */
	@:native("getNotesFromRange") static function getNotesFromRange(startIndex:Int64, endIndex:Int64):cpp.Pointer<cpp.UInt32>;
}
#elseif hl
class File {
	@:hlNative("chart_file", "remap")
	public static function remap(newLength:Int64):Bool {
		return false;
	}

	@:hlNative("chart_file", "loadChart")
	public static function loadChart(inFile:String):Void {}

	@:hlNative("chart_file", "getNote_first8")
	public static function getNote_first8(atIndex:hl.I64):hl.I64 {
		return 0;
	}

	@:hlNative("chart_file", "getNote_last4")
	public static function getNote_last4(atIndex:hl.I64):hl.I64 {
		return 0;
	}

	//BOTTLENECK: low per-call heap allocation of MetaNoteImpl in the note-read path; GC churn if called per-frame in note loops | FIX: return the packed Int64 and decode in the caller, or fill a reusable scratch MetaNote via out-param
	@:runtime inline public static function getNote(atIndex:Int64):MetaNote {
		return new MetaNote.MetaNoteImpl(getNote_first8(atIndex), Int64.toInt(getNote_last4(atIndex)));
	}

	@:hlNative("chart_file", "insertNote")
	public static function insertNote(atGlobalPosition:hl.I64, duration:Int, index:Int, type:Int):Void {}

	/**
	 * Adds a note from its raw fields — the editor-facing API.
	 * See the cpp target's addNote docs for the field units.
	 * Returns the new note's global chart index.
	 */
	@:hlNative("chart_file", "addNote")
	public static function addNote(position:hl.I64, duration:Int, index:Int, type:Int, lane:Int):hl.I64 {
		return 0;
	}

	/** Removes the note with the given global chart index. */
	@:hlNative("chart_file", "removeNote")
	public static function removeNote(atIndex:hl.I64):Void {}

	/** Writes the live sharded store back out as a .fvc snapshot. */
	@:hlNative("chart_file", "saveChart")
	public static function saveChart():Bool {
		return false;
	}

	@:hlNative("chart_file", "getLength")
	public static function getLength():hl.I64 {
		return 0;
	}

	@:hlNative("chart_file", "destroyChart")
	public static function destroyChart():Void {}

	@:hlNative("chart_file", "getJudgement")
	public static function getJudgement(globalIndex:hl.I64):Bool {
		return false;
	}

	@:hlNative("chart_file", "setJudgement")
	public static function setJudgement(globalIndex:hl.I64, value:Bool):Void {}

	@:hlNative("chart_file", "getHitFlag")
	public static function getHitFlag(globalIndex:hl.I64):Bool {
		return false;
	}

	@:hlNative("chart_file", "setHitFlag")
	public static function setHitFlag(globalIndex:hl.I64, value:Bool):Void {}

	@:hlNative("chart_file", "setEditorMode")
	public static function setEditorMode(value:Bool):Void {};

	// Per-note overlap count (see the cpp target's docs). The bulk block
	// accessor getNotesFromRange is cpp-only — it returns a raw pointer
	// into the chart-lifetime block; the hl side reads counts per note.
	@:hlNative("chart_file", "getNoteOverlapCount")
	public static function getNoteOverlapCount(globalIndex:hl.I64):Int {
		return 1;
	}
}
#end
