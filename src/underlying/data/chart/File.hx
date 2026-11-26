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

	// === Judgement state (per-shard, in-RAM, flat) ===
	// Every chart shard owns its own flat judgement bit array inside the
	// chart file's C++ side: allocated freshly zeroed when the shard
	// opens, kept index-aligned across note inserts/removes, and destroyed
	// when the shard closes — a shard that leaves the LRU window and comes
	// back is automatically un-judged, so no manual index zero-out is ever
	// needed for that. getJudgement/setJudgement above read/write those
	// per-note bits; clearJudgements zeroes ONLY the active shards.
	/** Zeroes the judgement bits of the ACTIVE shards (closed shards reopen freshly zeroed). */
	@:native("clearJudgements") static function clearJudgements():Void;

	/**
	 * `getNotesFromRange` — collects the global indexes in
	 * [fromIndex .. toIndex] whose note belongs to (lane, index): the exact
	 * member list of an ambient-occluded visual note (its head plus every
	 * chart note that folds into its sprite). The results land in a
	 * PERSISTENT memory block on the C++ side — reused across calls, grown
	 * geometrically, never reallocated per call — that tracks its own
	 * custom length variable; the return value is that length, and
	 * getRangeNoteAt() reads entries back with zero allocation.
	 *   strumlineCount: strumline count used to clamp each note's stored
	 *                   lane (same rule as NoteSystem.clampLane)
	 *   lane:           the strumline the visual note is on
	 *   index:          the column (receptor index) of the visual note
	 */
	@:native("getNotesFromRange") static function getNotesFromRange(strumlineCount:Int, lane:Int, index:Int, fromIndex:Int64, toIndex:Int64):Int;
	/** Reads entry `at` of the persistent block filled by the last getNotesFromRange call (-1 when out of range). */
	@:native("getRangeNoteAt") static function getRangeNoteAt(at:Int):Int64;

	// === Bulk edit API (v3.5) — stage, then commit ONE call ===
	// The batch gestures (paste, delete-selection, undo/redo of either)
	// stage every note/range first, then commit once: ONE lock, ONE FFI
	// crossing instead of one per note. The per-note fields and units are
	// exactly addNote()'s; the removal ranges are inclusive global id
	// ranges, normalized (sorted, touching/overlapping merged, clamped) on
	// the C++ side so no id can ever be removed twice.
	/**
	 * Stage one note to add (fields exactly as addNote's). The staging
	 * buffers live on the C++ side — no Haxe-side accumulation.
	 */
	@:native("stageNote") static function stageNote(position:Int64, duration:Int, index:Int, type:Int, lane:Int):Void;
	/**
	 * Commits every staged note as ONE bulk insert, ascending by position
	 * (ties keep staging order). Returns the number added and fills the
	 * ADDED-RANGE BLOCK on the C++ side: the exact final global indexes
	 * of the newly added notes as inclusive coalesced [lo..hi] ranges —
	 * read with getAddedRangeCount/Lo/Hi. THE key point for undo: a
	 * per-note add() id goes stale the moment a later add lands at or
	 * below it; addNotes' group ranges are FINAL by construction (a
	 * group of m ties around the first member's id r occupies exactly
	 * [r .. r+m-1], later groups land strictly above it), so they are the
	 * 100%-correct removal input for undoing the paste.
	 */
	@:native("addNotes") static function addNotes():Int;
	/**
	 * Stage one inclusive [lo..hi] global id range to remove. Overlapping/
	 * touching staged ranges are merged at commit — an id staged twice is
	 * removed once.
	 */
	@:native("stageRemovalRange") static function stageRemovalRange(lo:Int64, hi:Int64):Void;
	/**
	 * Commits every staged range as ONE bulk removal, highest id first so
	 * lower ids stay valid while the higher ones disappear. Returns the
	 * number of notes removed. THE undo-of-paste path: pass the paste's
	 * recorded added-ranges — removing exactly those indexes removes
	 * every note the paste added and nothing else.
	 */
	@:native("removeNotesFromRangeArray") static function removeNotesFromRangeArray():Int;
	/** Drops everything staged (an aborted gesture — selection changed mid-stage, etc.). */
	@:native("clearStaged") static function clearStaged():Void;
	// === Mirror API (v3.7) — in-place column flip, undo = same call again ===
	/**
		Stage one inclusive [lo..hi] global id range to mirror (the
		selection's id ranges). Ranges are NOT normalized at commit — the
		flip is an involution per note, so an id staged twice lands back
		on its original column.
	**/
	@:native("stageMirrorRange") static function stageMirrorRange(lo:Int64, hi:Int64):Void;
	/**
		Commits every staged mirror range as ONE locked pass: every
		note's column index becomes indexLo + indexHi - index (the
		mirror axis pair read off the SELECTION's column bounds). In
		place — no note is added or removed, ids never move (the store
		orders by position only) — so the selection survives untouched
		and UNDO/REDO replay exactly this call on the same ranges:
		"mirror the notes back", no remove-and-readd. Returns the number
		of notes flipped.
	**/
	@:native("mirrorNotesFromSelectionRanges") static function mirrorNotesFromSelectionRanges(indexLo:Int, indexHi:Int):Int;
	// === Shift API (v3.8) — in-place column/lane move (Alt+arrows) ===
	/**
		Stage one inclusive [lo..hi] global id range to shift (the
		selection's id ranges). Ranges are NOT normalized at commit —
		the shift is a pure field rewrite per note.
	**/
	@:native("stageShiftRange") static function stageShiftRange(lo:Int64, hi:Int64):Void;
	/**
		Commits every staged shift range as ONE locked pass: every
		note's column becomes wrapMod(column + dIndex, mania) and its
		lane wrapMod(lane + dLane, strumlineCount) — the exact landing
		discipline of the paste. In place — ids never move — so the
		selection survives untouched and UNDO/REDO replay the inverse
		delta on the same ranges. Returns the number of notes shifted.
	**/
	@:native("shiftNotesFromSelectionRanges") static function shiftNotesFromSelectionRanges(dIndex:Int, dLane:Int, mania:Int, strumlineCount:Int):Int;
	/** Number of ranges in the persistent added-range block filled by the last addNotes call. */
	@:native("getAddedRangeCount") static function getAddedRangeCount():Int;
	/** Range `at`'s inclusive lower id (or -1 when out of range). */
	@:native("getAddedRangeLo") static function getAddedRangeLo(at:Int):Int64;
	/** Range `at`'s inclusive upper id (or -1 when out of range). */
	@:native("getAddedRangeHi") static function getAddedRangeHi(at:Int):Int64;
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

	// === Judgement state (per-shard, in-RAM, flat) +
	// getNotesFromRange (persistent block, custom length).
	// See the cpp target's docs for the semantics. ===

	@:hlNative("chart_file", "clearJudgements")
	public static function clearJudgements():Void {}

	@:hlNative("chart_file", "getNotesFromRange")
	public static function getNotesFromRange(strumlineCount:Int, lane:Int, index:Int, fromIndex:hl.I64, toIndex:hl.I64):Int {
		return 0;
	}

	@:hlNative("chart_file", "getRangeNoteAt")
	public static function getRangeNoteAt(at:Int):hl.I64 {
		return -1;
	}

	// === Bulk edit API (v3.5) — stage, then commit ONE call ===
	// See the cpp target's docs for the full contract, including the
	// exact-index guarantee of addNotes (its added-range block is the
	// 100%-correct removal input for undoing a paste). ===

	@:hlNative("chart_file", "stageNote")
	public static function stageNote(position:hl.I64, duration:Int, index:Int, type:Int, lane:Int):Void {}

	@:hlNative("chart_file", "addNotes")
	public static function addNotes():Int {
		return 0;
	}

	@:hlNative("chart_file", "stageRemovalRange")
	public static function stageRemovalRange(lo:hl.I64, hi:hl.I64):Void {}

	@:hlNative("chart_file", "removeNotesFromRangeArray")
	public static function removeNotesFromRangeArray():Int {
		return 0;
	}

	@:hlNative("chart_file", "clearStaged")
	public static function clearStaged():Void {}

	// === Mirror API (v3.7) — see the cpp target's docs for the contract ===

	@:hlNative("chart_file", "stageMirrorRange")
	public static function stageMirrorRange(lo:hl.I64, hi:hl.I64):Void {}

	@:hlNative("chart_file", "mirrorNotesFromSelectionRanges")
	public static function mirrorNotesFromSelectionRanges(indexLo:Int, indexHi:Int):Int {
		return 0;
	}

	// === Shift API (v3.8) — see the cpp target's docs for the contract ===

	@:hlNative("chart_file", "stageShiftRange")
	public static function stageShiftRange(lo:hl.I64, hi:hl.I64):Void {}

	@:hlNative("chart_file", "shiftNotesFromSelectionRanges")
	public static function shiftNotesFromSelectionRanges(dIndex:Int, dLane:Int, mania:Int, strumlineCount:Int):Int {
		return 0;
	}

	@:hlNative("chart_file", "getAddedRangeCount")
	public static function getAddedRangeCount():Int {
		return 0;
	}

	@:hlNative("chart_file", "getAddedRangeLo")
	public static function getAddedRangeLo(at:Int):hl.I64 {
		return -1;
	}

	@:hlNative("chart_file", "getAddedRangeHi")
	public static function getAddedRangeHi(at:Int):hl.I64 {
		return -1;
	}
}
#end
