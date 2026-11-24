package gameplay;

import haxe.Int64;

/**
	One inclusive span of selected note indexes: every id in [lo..hi] is
	selected. The selection is stored as a sorted list of these — see
	EditorEditSystem.selected.
**/
@:publicFields
class SelRange {
	var lo:Int64 = 0;
	var hi:Int64 = 0;

	function new(lo:Int64 = 0, hi:Int64 = 0) {
		this.lo = lo;
		this.hi = hi;
	}
}

/**
	A chart note's raw fields — the complete undo record for one note.
	Position-keyed (not global-index-keyed): every structural edit shifts
	the global indexes after it, so undo entries must re-resolve by fields.
**/
@:publicFields
class EditNoteData {
	var position:Int64 = 0;
	var duration:Int = 0;
	var index:Int = 0;
	var type:Int = 0;
	var lane:Int = 0;

	function new(position:Int64 = 0, duration:Int = 0, index:Int = 0, type:Int = 0, lane:Int = 0) {
		this.position = position;
		this.duration = duration;
		this.index = index;
		this.type = type;
		this.lane = lane;
	}
}

/**
	One recorded chart edit. kind: 0 = add (only `afters`), 1 = remove
	(only `befores`), 2 = replace (one entry each — the duration/retype
	gesture, which is one remove+re-add pair the user experiences as ONE
	edit). Add/remove carry ARRAYS so a single gesture that touches many
	notes — paste, cut, delete-selection, batch removal — is ONE undo
	step: one command, one CTRL+Z.

	v3.5 — `addedRanges`: THE EXACT INDEX RANGE ARRAY of a command's
	added notes. Every batch add goes through File.addNotes (the bulk
	extern), which computes the final global indexes of the newly added
	notes as coalesced inclusive ranges — the group-insertion proof
	lives on File.addNotes. Those ranges are recorded here the moment
	the add lands, and undoing the command removes EXACTLY those indexes
	via File.removeNotesFromRangeArray (the bulk removal extern): no
	field re-resolution, no missed or extra indexes — 100% correct by
	construction. INVARIANT: addedRanges is meaningful exactly while the
	command's added notes EXIST in the chart (paste/editorAdd set it on
	the undoStack; undo clears it moving the cmd to the redoStack; an
	undo-of-remove re-add sets it on the redoStack so the following redo
	removes those exact indexes again). null = the added notes are not
	currently in the chart.
**/
@:publicFields
class EditCmd {
	var kind:Int = 0;
	var befores:Array<EditNoteData> = null;
	var afters:Array<EditNoteData> = null;
	/** Exact current global index ranges of this command's added notes (null while they are not in the chart). */
	var addedRanges:Array<SelRange> = null;

	function new(kind:Int, befores:Array<EditNoteData>, afters:Array<EditNoteData>, addedRanges:Array<SelRange> = null) {
		this.kind = kind;
		this.befores = befores;
		this.afters = afters;
		this.addedRanges = addedRanges;
	}
}

/**
	The editor's edit state machine: NOTE SELECTION, the CLIPBOARD, and
	the UNDO/REDO history — one class, because the three must stay
	coherent with each other.

	=== Why selection lives with the history ===

	The selection is a set of global chart indexes, and every structural
	edit (place, remove, undo, paste...) shifts the indexes after the edit
	point. Since ALL structural writes funnel through this class's
	recorders, each write also REMAPS the selection (insert at id k shifts
	selected ids >= k up by one; remove at k shifts ids > k down and drops
	k) — so the selection survives arbitrary edits, undos and redos
	without ever pointing at the wrong note.

	=== The storage: RANGES, not a flat id list ===

	The set is kept as a sorted array of INCLUSIVE [lo..hi] spans
	(SelRange), non-overlapping and merged-touching. A contiguous block —
	select-all, a marquee band over a dense chart, a pasted pattern —
	compresses to a handful of Int64 PAIRS no matter how many notes it
	covers: selecting a MILLION notes costs a few ranges, membership is a
	binary search over the ranges (O(log ranges)), and the structural
	remaps walk only the range tail — O(ranges) per edit instead of
	O(selected). The per-note work (reading fields, removing) is still
	per-note by necessity, but the bookkeeping never blows up.

	=== Selection ===

	CTRL+drag on the strumlines bands the SELECTION BOX sprite
	(SelectionBoxSprite — StrumlineNoteInteraction renders it and reports
	the captured id sets here); every note the box TOUCHES is selected,
	live on every move. SHIFT+drag adds the band to the existing
	selection instead of replacing it; SHIFT+click toggles one note;
	CTRL+A selects everything (ONE range); a plain click of EITHER
	button (no SHIFT, no CTRL) — or ESC — clears the whole selection.
	The per-note selection GRAPHIC is a separate element class
	(SelectionNoteSprite, v3.5) in its own program, layered above the
	box's — the elements can overlap, so the two graphics never share a
	buffer.

	=== Clipboard ===

	CTRL+C captures the selection's fields with positions RELATIVE to
	the earliest selected note, so a paste lands the pattern wherever the
	playhead is — THE MINIMAL DATA: one EditNoteData (5 ints) per copied
	note, nothing else, and the clipboard preserves every copied note's
	fields verbatim (an occupied slot at paste time only SKIPS landing
	that one note; nothing is dropped from the clipboard itself).
	CTRL+X = copy + delete-selection (one undo step). CTRL+V re-adds the
	clipboard at the snapped playhead — slots that already hold a note
	(same lane index + stored strumline + position) are SKIPPED, never
	overwritten — and selects what it pasted, so the next
	SHIFT-marquee/copy/cut acts on the fresh copies immediately.

	=== Undo / redo (v3.5: bulk externs + the exact index ranges) ===

	Every batch gesture commits through the chart extern's BULK API —
	File.addNotes / File.removeNotesFromRangeArray — ONE commit per
	gesture: one lock, one FFI crossing, instead of one addNote/
	removeNote per note. addNotes() computes THE EXACT FINAL GLOBAL
	INDEXES of the newly added notes as inclusive coalesced ranges (the
	added-range block — the group-insertion proof lives on File.addNotes),
	and those ranges are recorded on the command. Undo of an add is then
	index-exact: removeNotesFromRangeArray removes exactly those indexes
	— every note the paste added and NOTHING else — and undoing a remove
	re-adds the fields via ONE bulk add, records the NEW ranges on the
	command, and the redo that follows removes exactly those. Because the
	stacks are applied strictly LIFO, the chart state seen when a command
	is un-applied is exactly the state right after it was applied — the
	recorded ranges are always current. CTRL+Z / CTRL+Y, cap 256, a new
	edit clears the redo history. All of it is refused while a mouse
	hold-edit is in flight (its state tracks a note id the history would
	invalidate underneath it).

	@since Development
**/
@:publicFields
class EditorEditSystem {
	/** Owning editor mode (never null after construction). */
	var parent(default, null):PlayFieldEditorMode;

	// -------------------------------------------------------------------
	// Selection
	// -------------------------------------------------------------------

	/**
		The selected notes' global chart indexes as inclusive [lo..hi]
		spans, sorted ascending, non-overlapping, adjacent spans merged.
		Maintained ONLY through this class (the recorders remap it on
		every structural write) — never let an id in here go stale. This is
		the size optimization: contiguous selections compress to a few
		Int64 pairs however many notes they cover.
	**/
	var selected:Array<SelRange> = [];

	// -------------------------------------------------------------------
	// Clipboard
	// -------------------------------------------------------------------

	/**
		The copied notes, positions RELATIVE to the earliest one (subtract
		at copy time; paste adds the playhead target back). null = nothing
		copied yet. THE MINIMAL DATA: raw fields only, one object per
		copied note — every copy/paste is preserved with nothing extra.
	**/
	var clipboard:Array<EditNoteData> = null;

	// -------------------------------------------------------------------
	// Undo / redo history
	// -------------------------------------------------------------------

	/** Recorded chart edits, oldest first. */
	var undoStack:Array<EditCmd> = [];
	/** Edits undone, newest first — CTRL+Y re-applies them. */
	var redoStack:Array<EditCmd> = [];
	/** History cap (drops the OLDEST entry beyond it). */
	static inline var UNDO_LIMIT:Int = 256;

	function new(parent:PlayFieldEditorMode) {
		this.parent = parent;
	}

	// ===================================================================
	// Selection — range storage primitives
	// ===================================================================

	/**
		Binary-search lower bound over the ranges: the index of the FIRST
		range whose lo is > v. The range that could CONTAIN v is the one
		before it (the last range with lo <= v).
	**/
	static function lowerBoundRange(arr:Array<SelRange>, v:Int64):Int {
		var lo = 0, hi = arr.length;
		while (lo < hi) {
			var mid = (lo + hi) >> 1;
			if (arr[mid].lo <= v)
				lo = mid + 1;
			else
				hi = mid;
		}
		return lo;
	}

	/** Number of selected notes — sum of the span widths, O(ranges). */
	function selectionSize():Int64 {
		var n:Int64 = 0;
		for (r in selected)
			n += r.hi - r.lo + 1;
		return n;
	}

	inline function isSelected(id:Int64):Bool {
		var i = lowerBoundRange(selected, id);
		return i > 0 && selected[i - 1].hi >= id;
	}

	/** True when at least one note is selected. */
	inline function hasSelection():Bool {
		return selected.length > 0;
	}

	function clearSelection() {
		if (selected.length == 0)
			return;
		selected.resize(0);
	}

	/**
		Inserts one selected id at its sorted position and merges it with
		any neighbor it touches (up to two merges). The id is selected
		afterwards by construction.
	**/
	function insertId(id:Int64) {
		var i = lowerBoundRange(selected, id);
		// Touching the range before? (its hi is id-1 or more)
		var mergedBefore = i > 0 && selected[i - 1].hi + 1 >= id;
		// Touching the range after? (its lo is id+1 or less)
		var mergedAfter = i < selected.length && selected[i].lo <= id + 1;
		if (mergedBefore && mergedAfter) {
			// Fuse all three: before absorbs id AND the after-range.
			selected[i - 1].hi = selected[i].hi;
			selected.splice(i, 1);
		} else if (mergedBefore) {
			selected[i - 1].hi = id;
		} else if (mergedAfter) {
			selected[i].lo = id;
		} else {
			selected.insert(i, new SelRange(id, id));
		}
	}

	/**
		SHIFT+click: toggles one note in/out of the selection. Returns the
		note's NEW selected state (false also when id is invalid). Removing
		splits the span; adding merges with neighbors.
	**/
	function toggleSelected(id:Int64):Bool {
		if (id < 0 || id >= File.getLength())
			return false;
		var i = lowerBoundRange(selected, id);
		if (i > 0 && selected[i - 1].hi >= id) {
			// Inside the span [lo..hi]: subtract the single id.
			var r = selected[i - 1];
			if (r.lo == id && r.hi == id) {
				selected.splice(i - 1, 1); // it was a singleton — gone
			} else if (r.lo == id) {
				r.lo = id + 1;
			} else if (r.hi == id) {
				r.hi = id - 1;
			} else {
				// Split into [lo..id-1] and [id+1..hi].
				selected.insert(i, new SelRange(id + 1, r.hi));
				r.hi = id - 1;
			}
			return false;
		}
		insertId(id);
		return true;
	}

	/**
		Replaces the selection with exactly these ids (a selection box
		that started without SHIFT, a paste, an undo restore). Invalid ids
		are dropped; the result is normalized into spans.
	**/
	function selectIds(ids:Array<Int64>) {
		var len = File.getLength();
		var next:Array<Int64> = [];
		for (id in ids) {
			if (id < 0 || id >= len)
				continue;
			next.push(id);
		}
		selected = spansFromIds(next);
	}

	/**
		Replaces the selection with exactly these SPANS (already
		normalized — a bulk add's added-range array, the restored ranges of
		an undone paste). Clamped to the store, merged defensively.
	**/
	function selectRanges(ranges:Array<SelRange>) {
		var len = File.getLength();
		var out:Array<SelRange> = [];
		for (r in ranges) {
			var lo = r.lo, hi = r.hi;
			if (lo < 0)
				lo = 0;
			if (hi >= len)
				hi = len - 1;
			if (lo > hi)
				continue;
			if (out.length > 0 && out[out.length - 1].hi + 1 >= lo) {
				if (hi > out[out.length - 1].hi)
					out[out.length - 1].hi = hi;
			} else {
				out.push(new SelRange(lo, hi));
			}
		}
		selected = out;
	}

	/**
		Adds these ids to the existing selection (a box band that started
		WITH SHIFT — additive banding). Merge-based: O(ids + ranges).
	**/
	function addIdsToSelection(ids:Array<Int64>) {
		var len = File.getLength();
		var valid:Array<Int64> = [];
		for (id in ids) {
			if (id < 0 || id >= len)
				continue;
			valid.push(id);
		}
		var incoming = spansFromIds(valid);
		if (incoming.length == 0)
			return;
		// Two-pointer union of the two sorted, normalized span lists.
		var union:Array<SelRange> = [];
		var a = 0, b = 0;
		while (a < selected.length || b < incoming.length) {
			// Pick the next span (by lo) from whichever list holds it.
			var r:SelRange;
			if (b >= incoming.length || (a < selected.length && selected[a].lo <= incoming[b].lo)) {
				r = selected[a];
				a++;
			} else {
				r = incoming[b];
				b++;
			}
			// Merge into the running tail when touching/overlapping.
			if (union.length > 0 && union[union.length - 1].hi + 1 >= r.lo) {
				if (r.hi > union[union.length - 1].hi)
					union[union.length - 1].hi = r.hi;
			} else {
				union.push(r);
			}
		}
		selected = union;
	}

	/** CTRL+A: every note in the chart — ONE span, whatever the size. */
	function selectAll() {
		var len = File.getLength();
		if (len <= 0) {
			clearSelection();
			return;
		}
		selected = [new SelRange(0, len - 1)];
	}

	/**
		Builds the normalized span list from an arbitrary id collection:
		sort ascending, drop duplicates, coalesce touching ids into spans.
		This is where the compression happens — a million consecutive ids
		become one [lo..hi] pair.
	**/
	static function spansFromIds(ids:Array<Int64>):Array<SelRange> {
		if (ids.length == 0)
			return [];
		ids.sort(function(a:Int64, b:Int64):Int {
			if (a == b)
				return 0;
			return a < b ? -1 : 1;
		});
		var spans:Array<SelRange> = [];
		var runLo = ids[0];
		var runHi = ids[0];
		for (i in 1...ids.length) {
			var id = ids[i];
			if (id == runHi)
				continue; // duplicate
			if (id == runHi + 1) {
				runHi = id; // extends the current span
			} else {
				spans.push(new SelRange(runLo, runHi));
				runLo = id;
				runHi = id;
			}
		}
		spans.push(new SelRange(runLo, runHi));
		return spans;
	}

	/**
		Re-establishes the invariant after a remap: walk the spans and
		fuse any that now touch (hi + 1 == next.lo) or overlap. O(ranges);
		drops empty spans (lo > hi) outright.
	**/
	function coalesceRanges() {
		var out:Array<SelRange> = [];
		for (r in selected) {
			if (r.lo > r.hi)
				continue; // emptied by a removal remap
			if (out.length > 0 && out[out.length - 1].hi + 1 >= r.lo) {
				if (r.hi > out[out.length - 1].hi)
					out[out.length - 1].hi = r.hi;
			} else {
				out.push(r);
			}
		}
		selected = out;
	}

	// ===================================================================
	// The recorders — EVERY structural editor write goes through these,
	// so the selection remap and the history stay coherent everywhere.
	// The batch paths commit through the BULK externs (v3.5); the
	// single-note replace gesture still uses the per-note externs.
	// ===================================================================

	/**
		Editor ADD: the bulk extern wrapped with undo recording and
		selection remapping. ONE note or a thousand — one File.addNotes
		commit, and the added-range block yields the exact final index of
		the new note for the undo record. Returns the new note's global
		chart index (or -1), exactly like File.addNote.
	**/
	function editorAdd(position:Int64, duration:Int, index:Int, type:Int, lane:Int):Int64 {
		var ranges = bulkAdd([new EditNoteData(position, duration, index, type, lane)]);
		if (ranges.length == 0)
			return -1;
		remapForInsertSpan(ranges);
		pushCmd(new EditCmd(0, null, [readNoteData(ranges[0].lo)], ranges));
		return ranges[0].lo;
	}

	/**
		Editor REMOVE: the bulk extern wrapped with undo recording (the
		note's fields are captured BEFORE the removal) and selection
		remapping. Returns true when something was removed.
	**/
	function editorRemove(id:Int64):Bool {
		if (id < 0 || id >= File.getLength())
			return false;
		var data = readNoteData(id);
		bulkRemoveRanges([new SelRange(id, id)]);
		pushCmd(new EditCmd(1, [data], null));
		return true;
	}

	/**
		Editor REMOVE of a whole id SET — the batch-removal gesture (the
		v3.4 right-click sweep): one recorded command, one CTRL+Z puts
		every note back. The ids need not be selected; invalid ids are
		dropped. The notes leave the selection via the span remaps. ONE
		File.removeNotesFromRangeArray commit, however many notes. Returns
		the count removed.
	**/
	function removeNotesByIds(ids:Array<Int64>):Int {
		var len = File.getLength();
		var valid:Array<Int64> = [];
		for (id in ids) {
			if (id < 0 || id >= len)
				continue;
			valid.push(id);
		}
		if (valid.length == 0)
			return 0;
		return removeIdsInternal(valid);
	}

	/**
		Editor REPLACE — the duration/retype gesture: one remove + one
		re-add the user experiences as a single edit, recorded as a single
		undo entry. A replaced note that was selected stays selected (on
		its new id). Returns the new note's global chart index (or -1).
	**/
	function replaceNote(oldId:Int64, position:Int64, duration:Int, index:Int, type:Int, lane:Int):Int64 {
		if (oldId < 0 || oldId >= File.getLength())
			return -1;
		var before = readNoteData(oldId);
		var wasSelected = isSelected(oldId);
		File.removeNote(oldId);
		remapForRemove(oldId);
		var ranges = bulkAdd([new EditNoteData(position, duration, index, type, lane)]);
		if (ranges.length == 0)
			return -1;
		remapForInsertSpan(ranges);
		var newId = ranges[0].lo;
		if (wasSelected && !isSelected(newId))
			insertId(newId);
		pushCmd(new EditCmd(2, [before], [readNoteData(newId)]));
		return newId;
	}

	// ===================================================================
	// Clipboard
	// ===================================================================

	/**
		CTRL+C: captures the selection into the clipboard, positions
		relative to the earliest note. Returns true when something was
		copied.
	**/
	function copy():Bool {
		if (selected.length == 0)
			return false;
		var len = File.getLength();
		var datas:Array<EditNoteData> = [];
		// Range order IS id order (ascending), and the store is
		// position-sorted — so ids ascending == positions ascending.
		for (r in selected) {
			var i = r.lo;
			while (i <= r.hi) {
				if (i >= 0 && i < len)
					datas.push(readNoteData(i));
				i++;
			}
		}
		if (datas.length == 0)
			return false;
		sortByPosition(datas, false);
		var base = datas[0].position;
		for (d in datas)
			d.position = d.position - base; // fresh objects — safe to mutate
		clipboard = datas;
		return true;
	}

	/**
		CTRL+X: copy + delete the selection in one gesture — one undo
		step puts everything back (selected again).
	**/
	function cut():Bool {
		if (editingActive() || selected.length == 0)
			return false;
		if (!copy())
			return false;
		// copy() captured the fields first; the deletion is the recorded
		// half of the gesture.
		return deleteSelection();
	}

	/**
		CTRL+V: re-adds the clipboard at the snapped playhead position —
		via ONE File.addNotes commit. THE MINIMAL DATA: the clipboard
		holds exactly the copied notes' raw fields, and only the notes
		that will actually land are staged (an occupied slot — same lane
		index + stored strumline + position — is skipped: never staged,
		never overwritten, never dropped from the clipboard itself).
		The bulk add's added-range block then gives THE EXACT FINAL
		INDEXES of the newly added notes, recorded on the command, so
		undoing the paste removes exactly those indexes (and NOTHING
		else) via File.removeNotesFromRangeArray. The pasted notes become
		the new selection. One undo step removes them all.
	**/
	function paste():Bool {
		if (editingActive() || clipboard == null || clipboard.length == 0)
			return false;
		var si = parent.strumlineInput;
		var targetMs = si != null ? si.snapTime(parent.field.songPosition) : parent.field.songPosition;
		var target = MetaNote.floatToMetaNotePosition(targetMs);

		// Stage exactly what will land: an occupied slot is skipped —
		// pasting twice in place is a no-op, not a stack of duplicates.
		var toAdd:Array<EditNoteData> = [];
		for (d in clipboard) {
			var abs = target + d.position;
			if (findNoteAtSlot(d.index, d.lane, abs) >= 0)
				continue; // occupied slot — skip, never overwrite
			toAdd.push(new EditNoteData(abs, d.duration, d.index, d.type, d.lane));
		}
		if (toAdd.length == 0)
			return false;

		// ONE bulk commit; `ranges` = the exact final indexes of the
		// pasted notes (coalesced inclusive spans, ascending).
		var ranges = bulkAdd(toAdd);
		if (ranges.length == 0)
			return false;

		remapForInsertSpan(ranges);
		var afters:Array<EditNoteData> = [];
		for (r in ranges) {
			var i = r.lo;
			while (i <= r.hi) {
				afters.push(readNoteData(i));
				i++;
			}
		}
		pushCmd(new EditCmd(0, null, afters, ranges));
		selectRanges(ranges); // the pasted set is selected — move/copy it again at once
		Main.current.playScrollSound();
		parent.onChartEdited();
		return true;
	}

	/**
		DELETE / BACKSPACE: removes every selected note as ONE recorded
		command (one bulk commit, one CTRL+Z restores them all, selected
		again). The selection is empty afterwards by construction.
	**/
	function deleteSelection():Bool {
		if (editingActive() || selected.length == 0)
			return false;
		// Materialize the selection's ids (ascending) — the spans mutate
		// as the removal remaps them.
		var ids:Array<Int64> = [];
		for (r in selected.copy()) {
			var i = r.lo;
			while (i <= r.hi) {
				ids.push(i);
				i++;
			}
		}
		if (ids.length == 0)
			return false;
		removeIdsInternal(ids);
		Main.current.playScrollSound();
		parent.onChartEdited();
		return true;
	}

	// ===================================================================
	// Undo / redo (CTRL+Z / CTRL+Y) — index-exact for the batch paths
	// ===================================================================

	/**
		CTRL+Z — inverse-applies the newest recorded edit (batch-aware,
		index-exact). The stacks are applied strictly LIFO, so the chart
		state seen here is exactly the state right after this command was
		applied — its recorded added-ranges are still current. Kind-0
		undoes (paste, add) stage those ranges and ONE
		File.removeNotesFromRangeArray removes every note the command
		added and nothing else; kind-1 undoes re-add the captured fields
		via ONE File.addNotes and record the new ranges on the command
		(the following redo removes exactly those).
	**/
	function undo() {
		if (undoStack.length == 0 || editingActive())
			return;
		var cmd = undoStack.pop();
		switch (cmd.kind) {
			case 0: // undo adds → remove EXACTLY the recorded added ranges
				var ranges = cmd.addedRanges;
				cmd.addedRanges = null; // the added notes are about to be gone
				if (ranges != null && ranges.length > 0)
					bulkRemoveRanges(ranges);
			case 1: // undo removes → put them back (ONE bulk add), selected again
				var ids:Array<Int64> = [];
				var ranges = bulkAdd(cmd.befores);
				cmd.addedRanges = ranges; // exact while they exist — the redo input
				remapForInsertSpan(ranges);
				for (r in ranges) {
					var i = r.lo;
					while (i <= r.hi) {
						ids.push(i);
						i++;
					}
				}
				selectIds(ids);
			default: // undo a replace → remove the replacement, restore the original
				var curId = findNoteByData(cmd.afters[0]);
				var wasSelected = curId >= 0 && isSelected(curId);
				if (removeNoteByData(cmd.afters[0])) {
					var id = silentAdd(cmd.befores[0]);
					if (wasSelected && id >= 0 && !isSelected(id))
						insertId(id);
				}
		}
		redoStack.push(cmd);
		Main.current.playScrollSound();
		parent.onChartEdited();
	}

	/** CTRL+Y — re-applies the newest undone edit (batch-aware, index-exact). */
	function redo() {
		if (redoStack.length == 0 || editingActive())
			return;
		var cmd = redoStack.pop();
		switch (cmd.kind) {
			case 0: // redo adds (e.g. a paste) → re-add them (ONE bulk add), selected again
				var ranges = bulkAdd(cmd.afters);
				cmd.addedRanges = ranges; // exact again — the next undo's input
				remapForInsertSpan(ranges);
				selectRanges(ranges);
			case 1: // redo removes → remove EXACTLY the re-added ranges
				var ranges = cmd.addedRanges;
				cmd.addedRanges = null;
				if (ranges != null && ranges.length > 0)
					bulkRemoveRanges(ranges);
			default: // redo a replace → remove the original, put the replacement back
				var oldId = findNoteByData(cmd.befores[0]);
				var wasSelected = oldId >= 0 && isSelected(oldId);
				if (removeNoteByData(cmd.befores[0])) {
					var id = silentAdd(cmd.afters[0]);
					if (wasSelected && id >= 0 && !isSelected(id))
						insertId(id);
				}
		}
		undoStack.push(cmd);
		Main.current.playScrollSound();
		parent.onChartEdited();
	}

	// ===================================================================
	// Internals
	// ===================================================================

	/** True while a mouse hold-edit is in flight — history must not move its note. */
	function editingActive():Bool {
		var si = parent.strumlineInput;
		return si != null && (si.isDown || si.holdEditing);
	}

	/** Reads one note's full fields by global chart index. */
	function readNoteData(id:Int64):EditNoteData {
		var n = File.getNote(id);
		return new EditNoteData(n.position, n.duration, n.index, n.type, n.lane);
	}

	private function pushCmd(cmd:EditCmd) {
		undoStack.push(cmd);
		if (undoStack.length > UNDO_LIMIT)
			undoStack.shift();
		// A new edit invalidates the redo history (standard editor rule).
		redoStack.resize(0);
	}

	/**
		THE BULK ADD: stages every note's raw fields on the C++ side and
		commits them with ONE File.addNotes() call — one lock, one FFI
		crossing, however many notes. Returns THE EXACT FINAL INDEX RANGES
		of the newly added notes (ascending, coalesced inclusive spans,
		read back from the extern's added-range block) — the 100%-correct
		undo input: undoing the add removes exactly these indexes. Does
		NOT touch the selection — callers remap with remapForInsertSpan.
	**/
	function bulkAdd(datas:Array<EditNoteData>):Array<SelRange> {
		if (datas.length == 0)
			return [];
		File.clearStaged();
		for (d in datas)
			File.stageNote(d.position, d.duration, d.index, d.type, d.lane);
		if (File.addNotes() <= 0)
			return [];
		var count = File.getAddedRangeCount();
		var ranges:Array<SelRange> = [];
		for (k in 0...count) {
			var lo = File.getAddedRangeLo(k);
			var hi = File.getAddedRangeHi(k);
			if (lo >= 0 && hi >= lo)
				ranges.push(new SelRange(lo, hi));
		}
		return ranges;
	}

	/**
		THE BULK REMOVE: stages every inclusive [lo..hi] removal range on
		the C++ side and commits them ALL with ONE
		File.removeNotesFromRangeArray() call — the ranges are normalized
		there (sorted, touching/overlapping merged, clamped) so an id
		staged twice is removed once, and the pass walks highest-id-first
		so lower ids stay valid. The selection is then remapped per span,
		descending — sequential descending span remaps are exactly the
		store's end state (a surviving id's final index is its original
		index minus the removed ids below it, whichever span held them).
		Returns the number of notes removed. THE undo-of-paste path:
		passing a paste command's recorded added-ranges removes every
		note the paste added and nothing else.
	**/
	function bulkRemoveRanges(ranges:Array<SelRange>):Int {
		if (ranges.length == 0)
			return 0;
		var len = File.getLength();
		// Clamp every span against the CURRENT length (the commit removes
		// them all at once, so every clamp sees the pre-commit length).
		var spans:Array<SelRange> = [];
		for (r in ranges) {
			var lo = r.lo, hi = r.hi;
			if (lo < 0)
				lo = 0;
			if (hi >= len)
				hi = len - 1;
			if (lo <= hi)
				spans.push(new SelRange(lo, hi));
		}
		if (spans.length == 0)
			return 0;
		// ONE commit for the whole set.
		File.clearStaged();
		for (r in spans)
			File.stageRemovalRange(r.lo, r.hi);
		var removed = File.removeNotesFromRangeArray();
		// Then the selection remaps, descending — same end state the
		// store reached (spans disjoint here: spansFromIds / coalesced
		// added-ranges / pre-merged inputs).
		spans.sort(function(a:SelRange, b:SelRange):Int {
			if (a.lo == b.lo)
				return 0;
			return a.lo > b.lo ? -1 : 1;
		});
		for (r in spans)
			remapForRemoveSpan(r.lo, r.hi);
		return removed;
	}

	/**
		Add WITHOUT recording — the undo/redo playback path (the command
		is already on a stack, moving between them). Still remaps the
		selection so ids stay coherent. Single-note; the batch paths use
		bulkAdd.
	**/
	function silentAdd(d:EditNoteData):Int64 {
		var id = File.addNote(d.position, d.duration, d.index, d.type, d.lane);
		if (id >= 0)
			remapForInsert(id);
		return id;
	}

	/** Remove WITHOUT recording — the undo/redo playback path. */
	function silentRemove(id:Int64) {
		if (id < 0 || id >= File.getLength())
			return;
		File.removeNote(id);
		remapForRemove(id);
	}

	/**
		Selection remap after an insert at index `at`: every selected id
		at/after it shifts up by one. Per span: spans fully at/after it
		shift up; a span straddling it grows at the top. A final coalesce
		fuses anything the shift made touch. O(ranges) — NOT O(selected):
		a million-note selection remaps in a few steps.
	**/
	function remapForInsert(at:Int64) {
		if (selected.length == 0)
			return;
		for (r in selected) {
			if (r.lo >= at) {
				r.lo += 1;
				r.hi += 1;
			} else if (r.hi >= at) {
				r.hi += 1; // lo < at <= hi: the top end shifts up
			}
		}
		coalesceRanges();
	}

	/**
		Selection remap after a BULK insert whose notes now occupy
		[lo..hi] (count = hi-lo+1 ids, all at/after lo): every selected
		id at/after lo shifts up by count. Same shape as the single
		insert, with count instead of 1. The ranges replay in ascending
		lo order — the same order the bulk add inserted the groups — so
		each span's shift sees the cumulative ids exactly as the store
		did. O(ranges per insert-range).
	**/
	function remapForInsertSpan(ranges:Array<SelRange>) {
		if (selected.length == 0 || ranges.length == 0)
			return;
		var sorted = ranges.copy();
		sorted.sort(function(a:SelRange, b:SelRange):Int {
			if (a.lo == b.lo)
				return 0;
			return a.lo < b.lo ? -1 : 1;
		});
		for (r in sorted) {
			var at = r.lo;
			var count:Int64 = r.hi - r.lo + 1;
			for (s in selected) {
				if (s.lo >= at) {
					s.lo += count;
					s.hi += count;
				} else if (s.hi >= at) {
					s.hi += count; // lo < at <= hi: the top end shifts up
				}
			}
		}
		coalesceRanges();
	}

	/**
		Selection remap after a removal at index `at`: the removed note
		itself leaves the selection; ids above it shift down by one. Per
		span: a span containing `at` keeps its lo and loses its top end
		(the removed id drops out, everything above slides down into
		place); spans fully above shift down. Empty spans drop, touching
		spans re-fuse — again O(ranges).
	**/
	function remapForRemove(at:Int64) {
		if (selected.length == 0)
			return;
		for (r in selected) {
			if (r.hi < at)
				continue; // entirely below — untouched
			if (r.lo > at) {
				r.lo -= 1;
				r.hi -= 1; // entirely above — slides down
			} else {
				r.hi -= 1; // lo <= at <= hi: the id `at` drops, top slides down
			}
		}
		coalesceRanges(); // drops emptied spans, fuses re-touching ones
	}

	/**
		Selection remap after a SPAN removal [lo..hi] (count = hi-lo+1):
		the removed ids leave the selection; ids above hi shift down by
		count. A span straddling the removal keeps its lo and its top
		slides down by count — the dropped ids are exactly replaced by the
		shifted-down ones above them, so a contiguous span stays
		CONTIGUOUS ([5..10] minus [7..8] → 5,6 stay, 9,10 shift to 7,8
		→ [5..8]). O(ranges).
	**/
	function remapForRemoveSpan(lo:Int64, hi:Int64) {
		if (selected.length == 0)
			return;
		var count:Int64 = hi - lo + 1;
		for (r in selected) {
			if (r.hi < lo)
				continue; // entirely below — untouched
			if (r.lo > hi) {
				r.lo -= count;
				r.hi -= count; // entirely above — slides down
			} else {
				r.hi -= count; // straddles: the hole is filled by the shift
			}
		}
		coalesceRanges(); // drops emptied spans, fuses re-touching ones
	}

	/**
		The shared batch-removal core: removes exactly these ids (already
		validated, taken in any order) as ONE kind-1 command — the fields
		captured BEFORE the removal (while every id is still valid,
		ascending for the stable undo re-add order), then ONE
		File.removeNotesFromRangeArray commit (descending spans), the
		selection following along via the per-span remaps. Returns the
		count removed.
	**/
	function removeIdsInternal(ids:Array<Int64>):Int {
		var spans = spansFromIds(ids);
		if (spans.length == 0)
			return 0;
		var befores:Array<EditNoteData> = [];
		for (r in spans) {
			var i = r.lo;
			while (i <= r.hi) {
				if (i >= 0 && i < File.getLength())
					befores.push(readNoteData(i));
				i++;
			}
		}
		var removed = bulkRemoveRanges(spans);
		if (removed > 0)
			pushCmd(new EditCmd(1, befores, null));
		return removed;
	}

	/** In-place sort by position; pass desc=true for descending. */
	static function sortByPosition(arr:Array<EditNoteData>, desc:Bool) {
		arr.sort(function(a:EditNoteData, b:EditNoteData):Int {
			if (a.position == b.position)
				return 0;
			var less = a.position < b.position;
			return (less != desc) ? -1 : 1;
		});
	}

	/**
		Finds the chart index of the note with EXACTLY these fields (the
		store is position-sorted, so binary-search the position then match
		fields among the ties). Only the kind-2 replace undo/redo resolves
		its targets this way — the batch paths are INDEX-exact via the
		bulk externs' added-range blocks and never need this. Duplicate
		notes with identical fields are interchangeable for this purpose.
	**/
	function findNoteByData(d:EditNoteData):Int64 {
		if (d == null)
			return -1;
		var len = File.getLength();
		if (len <= 0)
			return -1;
		var lo:Int64 = 0, hi:Int64 = len;
		while (lo < hi) {
			var mid:Int64 = (lo + hi) >> 1;
			if (File.getNote(mid).position < d.position)
				lo = mid + 1;
			else
				hi = mid;
		}
		var i = lo;
		while (i < len) {
			var n = File.getNote(i);
			if (n.position != d.position)
				break;
			if (n.duration == d.duration && n.index == d.index && n.type == d.type && n.lane == d.lane)
				return i;
			i++;
		}
		return -1;
	}

	/**
		Occupancy check for paste: is there already a note with exactly
		this lane index + stored strumline at this position? (Type does
		not matter — two notes on one slot collide whatever their types.)
	**/
	function findNoteAtSlot(index:Int, lane:Int, position:Int64):Int64 {
		var len = File.getLength();
		if (len <= 0)
			return -1;
		var lo:Int64 = 0, hi:Int64 = len;
		while (lo < hi) {
			var mid:Int64 = (lo + hi) >> 1;
			if (File.getNote(mid).position < position)
				lo = mid + 1;
			else
				hi = mid;
		}
		var i = lo;
		while (i < len) {
			var n = File.getNote(i);
			if (n.position != position)
				break;
			if (n.index == index && n.lane == lane)
				return i;
			i++;
		}
		return -1;
	}

	private function removeNoteByData(d:EditNoteData):Bool {
		var id = findNoteByData(d);
		if (id < 0)
			return false;
		silentRemove(id);
		return true;
	}
}
