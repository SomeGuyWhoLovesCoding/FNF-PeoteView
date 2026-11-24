package gameplay;

/**
	A chart note's raw fields — the complete undo record for one note.
	Position-keyed (not global-index-keyed): every structural edit shifts
	the global indexes after it, so undo entries must re-resolve by fields.
**/
typedef EditNoteData = {
	position:Int64,
	duration:Int,
	index:Int,
	type:Int,
	lane:Int
}

/**
	One recorded chart edit. kind: 0 = add (only `afters`), 1 = remove
	(only `befores`), 2 = replace (one entry each — the duration/retype
	gesture, which is one remove+re-add pair the user experiences as ONE
	edit). Add/remove carry ARRAYS so a single gesture that touches many
	notes — paste, cut, delete-selection — is ONE undo step: one command,
	one CTRL+Z.
**/
typedef EditCmd = {
	kind:Int,
	befores:Array<EditNoteData>,
	afters:Array<EditNoteData>
}

/**
	The editor's edit state machine: NOTE SELECTION, the CLIPBOARD, and
	the UNDO/REDO history — one class, because the three must stay
	coherent with each other.

	=== Why selection lives with the history ===

	The selection is a set of global chart indexes, and every structural
	edit (place, remove, undo, paste...) shifts the indexes after the edit
	point. Since ALL structural writes funnel through this class's
	recorders, each write also REMAPS the selection set (insert at id k
	shifts selected ids >= k up by one; remove at k shifts ids > k down
	and drops k) — so the selection survives arbitrary edits, undos and
	redos without ever pointing at the wrong note.

	=== Selection ===

	CTRL+drag on the strumlines is a marquee (rubber-band) rectangle;
	SHIFT+click toggles one note; CTRL+A selects everything; ESC or a
	plain click on empty background clears. (The mouse gesture side —
	hit-testing, the live rectangle, the highlight overlay — lives in
	StrumlineNoteInteraction, which reports the captured id sets here.)

	=== Clipboard ===

	CTRL+C captures the selection's fields with positions RELATIVE to the
	earliest selected note, so a paste lands the pattern wherever the
	playhead is. CTRL+X = copy + delete-selection (one undo step).
	CTRL+V re-adds the clipboard at the snapped playhead — slots that
	already hold a note (same lane index + stored strumline + position)
	are SKIPPED, never overwritten — and selects what it pasted, so the
	next SHIFT-marquee/copy/cut acts on the fresh copies immediately.

	=== Undo / redo ===

	CTRL+Z / CTRL+Y, field-keyed records, cap 256, a new edit clears the
	redo history — the same machine the editor always had, now batch-
	aware: undoing a delete/cut re-adds the notes AND re-selects them;
	redoing a paste re-adds and re-selects the pasted set. All of it is
	refused while a mouse hold-edit is in flight (its state tracks a note
	id the history would invalidate underneath it).

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
		The selected notes' global chart indexes. Maintained ONLY through
		this class (the recorders remap it on every structural write) —
		never let an id in here go stale.
	**/
	var selected:Int64Map<Bool> = new Int64Map<Bool>();
	/** Selected note count (kept in sync with `selected`). */
	var selectedCount:Int = 0;

	// -------------------------------------------------------------------
	// Clipboard
	// -------------------------------------------------------------------

	/**
		The copied notes, positions RELATIVE to the earliest one (subtract
		at copy time; paste adds the playhead target back). null = nothing
		copied yet.
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
	// Selection
	// ===================================================================

	inline function isSelected(id:Int64):Bool {
		return selected.exists(id);
	}

	/** True when at least one note is selected. */
	inline function hasSelection():Bool {
		return selectedCount > 0;
	}

	function clearSelection() {
		if (selectedCount == 0)
			return;
		selected = new Int64Map<Bool>();
		selectedCount = 0;
	}

	/**
		SHIFT+click: toggles one note in/out of the selection. Returns the
		note's NEW selected state (false also when id is invalid).
	**/
	function toggleSelected(id:Int64):Bool {
		if (id < 0 || id >= File.getLength())
			return false;
		if (selected.exists(id)) {
			selected.remove(id);
			selectedCount--;
			return false;
		}
		selected.set(id, true);
		selectedCount++;
		return true;
	}

	/**
		Replaces the selection with exactly these ids (a marquee that
		started without SHIFT). Invalid ids are dropped.
	**/
	function selectIds(ids:Array<Int64>) {
		var next = new Int64Map<Bool>();
		var count = 0;
		for (id in ids) {
			if (id < 0 || id >= File.getLength())
				continue;
			next.set(id, true);
			count++;
		}
		selected = next;
		selectedCount = count;
	}

	/**
		Adds these ids to the existing selection (a marquee that started
		WITH SHIFT — additive banding).
	**/
	function addIdsToSelection(ids:Array<Int64>) {
		for (id in ids) {
			if (id < 0 || id >= File.getLength())
				continue;
			if (!selected.exists(id)) {
				selected.set(id, true);
				selectedCount++;
			}
		}
	}

	/** CTRL+A: every note in the chart. */
	function selectAll() {
		var len = File.getLength();
		if (len <= 0) {
			clearSelection();
			return;
		}
		var next = new Int64Map<Bool>();
		var count = 0;
		var i:Int64 = 0;
		while (i < len) {
			next.set(i, true);
			count++;
			i++;
		}
		selected = next;
		selectedCount = count;
	}

	// ===================================================================
	// The recorders — EVERY structural editor write goes through these,
	// so the selection remap and the history stay coherent everywhere.
	// (Same contracts as when these lived on PlayFieldEditorMode.)
	// ===================================================================

	/**
		Editor ADD: File.addNote wrapped with undo recording and selection
		remapping. Returns the new note's global chart index (or -1),
		exactly like File.addNote.
	**/
	function editorAdd(position:Int64, duration:Int, index:Int, type:Int, lane:Int):Int64 {
		var id = File.addNote(position, duration, index, type, lane);
		if (id >= 0) {
			remapForInsert(id);
			pushCmd({kind: 0, befores: null, afters: [readNoteData(id)]});
		}
		return id;
	}

	/**
		Editor REMOVE: File.removeNote wrapped with undo recording (the
		note's fields are captured BEFORE the removal) and selection
		remapping. Returns true when something was removed.
	**/
	function editorRemove(id:Int64):Bool {
		if (id < 0 || id >= File.getLength())
			return false;
		var data = readNoteData(id);
		File.removeNote(id);
		remapForRemove(id);
		pushCmd({kind: 1, befores: [data], afters: null});
		return true;
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
		var wasSelected = selected.exists(oldId);
		File.removeNote(oldId);
		remapForRemove(oldId);
		var newId = File.addNote(position, duration, index, type, lane);
		if (newId < 0)
			return -1;
		remapForInsert(newId);
		if (wasSelected && !selected.exists(newId)) {
			selected.set(newId, true);
			selectedCount++;
		}
		pushCmd({kind: 2, befores: [before], afters: [readNoteData(newId)]});
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
		if (selectedCount == 0)
			return false;
		var len = File.getLength();
		var datas:Array<EditNoteData> = [];
		for (id in selected.keys()) {
			if (id < 0 || id >= len)
				continue;
			datas.push(readNoteData(id));
		}
		if (datas.length == 0)
			return false;
		sortByPosition(datas, false);
		var base = datas[0].position;
		for (d in datas)
			d.position = d.position - base;
		clipboard = datas;
		return true;
	}

	/**
		CTRL+X: copy + delete the selection in one gesture — one undo
		step puts everything back (selected again).
	**/
	function cut():Bool {
		if (editingActive() || selectedCount == 0)
			return false;
		if (!copy())
			return false;
		// copy() captured the fields first; the deletion is the recorded
		// half of the gesture.
		return deleteSelection();
	}

	/**
		CTRL+V: re-adds the clipboard at the snapped playhead position.
		Slots that already hold a note (same lane index + stored
		strumline + position) are skipped, never overwritten — pasting
		twice in place is a no-op, not a stack of duplicates. The pasted
		notes become the new selection. One undo step removes them all.
	**/
	function paste():Bool {
		if (editingActive() || clipboard == null || clipboard.length == 0)
			return false;
		var si = parent.strumlineInput;
		var targetMs = si != null ? si.snapTime(parent.field.songPosition) : parent.field.songPosition;
		var target = MetaNote.floatToMetaNotePosition(targetMs);

		var toAdd:Array<EditNoteData> = [];
		for (d in clipboard) {
			var abs = target + d.position;
			if (findNoteAtSlot(d.index, d.lane, abs) >= 0)
				continue; // occupied slot — skip, never overwrite
			toAdd.push({position: abs, duration: d.duration, index: d.index, type: d.type, lane: d.lane});
		}
		if (toAdd.length == 0)
			return false;

		sortByPosition(toAdd, false);
		var added:Array<Int64> = [];
		for (d in toAdd) {
			var id = silentAdd(d);
			if (id >= 0)
				added.push(id);
		}
		if (added.length == 0)
			return false;

		var afters = [for (id in added) readNoteData(id)];
		pushCmd({kind: 0, befores: null, afters: afters});
		selectIds(added); // the pasted set is selected — move/copy it again at once
		Main.current.playScrollSound();
		parent.onChartEdited();
		return true;
	}

	/**
		DELETE / BACKSPACE: removes every selected note as ONE recorded
		command (one undo restores them all, selected again). The
		selection is empty afterwards by construction.
	**/
	function deleteSelection():Bool {
		if (editingActive() || selectedCount == 0)
			return false;
		var ids = [for (id in selected.keys()) id];
		if (ids.length == 0)
			return false;
		// Remove DESCENDING: deleting id k only shifts ids above k, so
		// the lower ids in this list stay valid as the loop runs.
		ids.sort(function(a:Int64, b:Int64):Int {
			return a > b ? -1 : (a < b ? 1 : 0);
		});
		var befores = [for (id in ids) readNoteData(id)];
		for (id in ids)
			silentRemove(id);
		sortByPosition(befores, false); // ascending — stable undo re-add order
		pushCmd({kind: 1, befores: befores, afters: null});
		Main.current.playScrollSound();
		parent.onChartEdited();
		return true;
	}

	// ===================================================================
	// Undo / redo (CTRL+Z / CTRL+Y)
	// ===================================================================

	/** CTRL+Z — inverse-applies the newest recorded edit (batch-aware). */
	function undo() {
		if (undoStack.length == 0 || editingActive())
			return;
		var cmd = undoStack.pop();
		switch (cmd.kind) {
			case 0: // undo adds → remove them again (order irrelevant: re-resolved by fields)
				var afters = cmd.afters.copy();
				sortByPosition(afters, true);
				for (d in afters)
					removeNoteByData(d);
			case 1: // undo removes → put them back, selected again
				var ids = [];
				for (d in cmd.befores)
					ids.push(silentAdd(d));
				selectIds(ids);
			default: // undo a replace → remove the replacement, restore the original
				var curId = findNoteByData(cmd.afters[0]);
				var wasSelected = curId >= 0 && selected.exists(curId);
				if (removeNoteByData(cmd.afters[0])) {
					var id = silentAdd(cmd.befores[0]);
					if (wasSelected && id >= 0 && !selected.exists(id)) {
						selected.set(id, true);
						selectedCount++;
					}
				}
		}
		redoStack.push(cmd);
		Main.current.playScrollSound();
		parent.onChartEdited();
	}

	/** CTRL+Y — re-applies the newest undone edit (batch-aware). */
	function redo() {
		if (redoStack.length == 0 || editingActive())
			return;
		var cmd = redoStack.pop();
		switch (cmd.kind) {
			case 0: // redo adds (e.g. a paste) → re-add them, selected again
				var ids = [];
				for (d in cmd.afters)
					ids.push(silentAdd(d));
				selectIds(ids);
			case 1: // redo removes → remove them again
				var befores = cmd.befores.copy();
				sortByPosition(befores, true);
				for (d in befores)
					removeNoteByData(d);
			default: // redo a replace → remove the original, put the replacement back
				var oldId = findNoteByData(cmd.befores[0]);
				var wasSelected = oldId >= 0 && selected.exists(oldId);
				if (removeNoteByData(cmd.befores[0])) {
					var id = silentAdd(cmd.afters[0]);
					if (wasSelected && id >= 0 && !selected.exists(id)) {
						selected.set(id, true);
						selectedCount++;
					}
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
		return {position: n.position, duration: n.duration, index: n.index, type: n.type, lane: n.lane};
	}

	private function pushCmd(cmd:EditCmd) {
		undoStack.push(cmd);
		if (undoStack.length > UNDO_LIMIT)
			undoStack.shift();
		// A new edit invalidates the redo history (standard editor rule).
		redoStack.resize(0);
	}

	/**
		Add WITHOUT recording — the undo/redo playback path (the command
		is already on a stack, moving between them). Still remaps the
		selection so ids stay coherent.
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
		at/after it shifts up by one.
	**/
	function remapForInsert(at:Int64) {
		if (selectedCount == 0)
			return;
		var next = new Int64Map<Bool>();
		var count = 0;
		for (id in selected.keys()) {
			next.set(id >= at ? id + 1 : id, true);
			count++;
		}
		selected = next;
		selectedCount = count;
	}

	/**
		Selection remap after a removal at index `at`: ids above it shift
		down by one; the removed note itself leaves the selection.
	**/
	function remapForRemove(at:Int64) {
		if (selectedCount == 0)
			return;
		var next = new Int64Map<Bool>();
		var count = 0;
		for (id in selected.keys()) {
			if (id == at)
				continue;
			next.set(id > at ? id - 1 : id, true);
			count++;
		}
		selected = next;
		selectedCount = count;
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
		fields among the ties). Undo resolves its targets this way instead
		of caching global indexes — every structural edit shifts the
		indexes after it, but fields are stable. Duplicate notes with
		identical fields are interchangeable for this purpose.
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
