package underlying.rhythm;

/**
 * The two-dimensional note judgement system.
 *
 * This replaces the old flat per-note judgement flag (File.getJudgement /
 * File.setJudgement on a bare global index) with a two-dimensional 1-bit
 * array:
 *
 *     judged[lane][index]
 *
 *   - N lane rows  — one per strumline; a note's row is its stored lane,
 *                    clamped (NoteSystem.clampLane).
 *   - M index bits — one per global chart note index (the chart length).
 *   - 1 bit per cell — "this note has been judged (resolved by a hit or
 *                    a miss)". The hit/miss distinction itself stays in
 *                    the per-note hit flag (File.getHitFlag).
 *
 * The lane dimension is what makes RANGE registration safe. An
 * ambient-occluded visual note (a sprite with several chart notes merged
 * into it by NoteSpawner's overlap pass) covers a span of GLOBAL indexes
 * [head .. tail], and between two members of that group the global order
 * can interleave notes that belong to OTHER lanes — an opponent jack
 * between two player notes, say. Those notes keep their bits in their own
 * lane's row, so registering an index span on one lane's row can never
 * mark another lane's notes as judged. Within one lane, the merge chain
 * guarantees no other note of the same (lane, index) column can sit inside
 * a group's span without being part of the group: a same-column note that
 * fails the overlap check is drawn itself and becomes the new chain head,
 * splitting the span — so (lane, index) filtering over [head .. tail]
 * yields EXACTLY the member list of the visual note.
 *
 * registerRange() bulk-sets a run of bits in one lane's row with
 * word-aligned fills (no per-note reads); getNotesFromRange() walks a
 * global-index span collecting the notes that actually belong to a
 * (lane, index) pair. judgeRangeHit / judgeRangeMiss register a whole
 * ambient-occlusion group at once — every note merged into the visual
 * note resolves with its head — in contiguous member runs handed to
 * registerRange, so a dense spam burst of a hundred merged notes is a
 * handful of word writes instead of a hundred per-note flag calls.
 *
 * @since Development
**/
@:publicFields
class JudgementSystem {
	/**
	 * The two-dimensional 1-bit array, packed 32 indexes per word:
	 * `words[lane][index >> 5]`, bit `(1 << (index & 31))`.
	 * Row = lane (strumline id), column = global note index.
	**/
	var words(default, null):Array<Array<Int>>;

	/** Number of lane rows (N). Never shrinks within one playthrough.**/
	var laneCount(default, null):Int;

	/** Number of addressable note-index bits per row (M). Never shrinks.**/
	var indexCapacity(default, null):Int;

	static var BITS_PER_WORD = 32;

	function new(lanes:Int = 0, indexes:Int = 0) {
		words = [];
		laneCount = 0;
		indexCapacity = 0;
		ensureCapacity(lanes, indexes);
	}

	inline static function wordsFor(indexes:Int):Int {
		// ceil(indexes / 32); 0 indexes -> 0 words.
		return (indexes + 31) >> 5;
	}

	/**
	 * Grows the array when the strumline count or the chart length grew
	 * (the editor can addNote while the note system lives). Growth only
	 * appends zero words — existing bits keep their (lane, index)
	 * meaning. Never shrinks; a smaller request is ignored.
	**/
	function ensureCapacity(lanes:Int, indexes:Int) {
		if (lanes < laneCount)
			lanes = laneCount;
		var wordsNeeded = wordsFor(indexes);
		if (wordsNeeded < wordsFor(indexCapacity))
			wordsNeeded = wordsFor(indexCapacity);

		// Append the missing lane rows.
		for (lane in laneCount...lanes)
			words.push(wordsNeeded > 0 ? [for (_ in 0...wordsNeeded) 0] : []);

		// Widen every row (old and new) to the needed word count.
		for (lane in 0...lanes) {
			var row = words[lane];
			for (w in row.length...wordsNeeded)
				row.push(0);
		}

		laneCount = lanes;
		var capacity = wordsNeeded * BITS_PER_WORD;
		if (capacity > indexCapacity)
			indexCapacity = capacity;
	}

	// ------------------------------------------------------------------
	// Single-bit API
	// ------------------------------------------------------------------

	/**
	 * Reads the judgement bit of (lane, index).
	 * Out-of-range reads return false ("not judged"), matching the old
	 * File.getJudgement contract.
	 * @param lane  The note's strumline row (clamped stored lane).
	 * @param index The note's global chart index.
	**/
	inline function isJudged(lane:Int, index:Int64):Bool {
		if (index < 0)
			return false;
		var i = Int64.toInt(index);
		if (lane < 0 || lane >= laneCount || i >= indexCapacity)
			return false;
		return (words[lane][i >> 5] & (1 << (i & 31))) != 0;
	}

	/**
	 * Sets a single judgement bit. Out-of-range writes are ignored.
	 * @param lane  The note's strumline row (clamped stored lane).
	 * @param index The note's global chart index.
	**/
	inline function setJudged(lane:Int, index:Int64):Void {
		if (index < 0)
			return;
		var i = Int64.toInt(index);
		if (lane < 0 || lane >= laneCount || i >= indexCapacity)
			return;
		words[lane][i >> 5] |= (1 << (i & 31));
	}

	/**
	 * Clears a single judgement bit. Out-of-range clears are ignored.
	 * @param lane  The note's strumline row (clamped stored lane).
	 * @param index The note's global chart index.
	**/
	inline function clearJudged(lane:Int, index:Int64):Void {
		if (index < 0)
			return;
		var i = Int64.toInt(index);
		if (lane < 0 || lane >= laneCount || i >= indexCapacity)
			return;
		words[lane][i >> 5] &= ~(1 << (i & 31));
	}

	// ------------------------------------------------------------------
	// Range API — the "register a range of index" primitive
	// ------------------------------------------------------------------

	/** All-32-bits-set guard: `(1 << 32) - 1` wraps on 32-bit Ints.**/
	inline static function wordMask(fromBit:Int, toBit:Int):Int {
		var count = toBit - fromBit + 1;
		if (count >= 32)
			return -1;
		return ((1 << count) - 1) << fromBit;
	}

	/**
	 * Registers a RANGE of global note indexes as judged on one lane's
	 * row: every bit in [fromIndex .. toIndex] of `lane` gets set, using
	 * word-aligned fills — no per-note reads.
	 *
	 * Bits of OTHER lanes' notes may share the global index span (their
	 * indexes interleave), but they live in other rows and are never
	 * touched; only this lane's cells in the span change.
	 *
	 * @param lane      The strumline row to register on.
	 * @param fromIndex First global chart index of the range (inclusive).
	 * @param toIndex   Last global chart index of the range (inclusive).
	**/
	function registerRange(lane:Int, fromIndex:Int64, toIndex:Int64) {
		if (lane < 0 || lane >= laneCount)
			return;
		if (fromIndex > toIndex)
			return;
		var from = fromIndex < 0 ? 0 : Int64.toInt(fromIndex);
		var to = Int64.toInt(toIndex);
		if (to >= indexCapacity)
			to = indexCapacity - 1;
		if (from > to || from >= indexCapacity)
			return;

		var row = words[lane];
		var firstWord = from >> 5;
		var lastWord = to >> 5;
		if (firstWord == lastWord) {
			row[firstWord] |= wordMask(from & 31, to & 31);
		} else {
			row[firstWord] |= wordMask(from & 31, 31);
			var w = firstWord + 1;
			while (w < lastWord) {
				row[w] = -1;
				++w;
			}
			row[lastWord] |= wordMask(0, to & 31);
		}
	}

	/**
	 * Clears a RANGE of global note indexes on one lane's row — the
	 * inverse of registerRange, same span semantics.
	 * @param lane      The strumline row to clear on.
	 * @param fromIndex First global chart index of the range (inclusive).
	 * @param toIndex   Last global chart index of the range (inclusive).
	**/
	function clearRange(lane:Int, fromIndex:Int64, toIndex:Int64) {
		if (lane < 0 || lane >= laneCount)
			return;
		if (fromIndex > toIndex)
			return;
		var from = fromIndex < 0 ? 0 : Int64.toInt(fromIndex);
		var to = Int64.toInt(toIndex);
		if (to >= indexCapacity)
			to = indexCapacity - 1;
		if (from > to || from >= indexCapacity)
			return;

		var row = words[lane];
		var firstWord = from >> 5;
		var lastWord = to >> 5;
		if (firstWord == lastWord) {
			row[firstWord] &= ~wordMask(from & 31, to & 31);
		} else {
			row[firstWord] &= ~wordMask(from & 31, 31);
			var w = firstWord + 1;
			while (w < lastWord) {
				row[w] = 0;
				++w;
			}
			row[lastWord] &= ~wordMask(0, to & 31);
		}
	}

	/** Clears every bit in every row (fresh judgement state).**/
	function reset() {
		for (lane in 0...laneCount) {
			var row = words[lane];
			for (w in 0...row.length)
				row[w] = 0;
		}
	}

	// ------------------------------------------------------------------
	// getNotesFromRange — the ambient-occlusion member list
	// ------------------------------------------------------------------

	/**
	 * `getNotesFromRange` — collects the notes inside the global-index
	 * span [fromIndex .. toIndex] that belong to the given lane
	 * (strumline) and index (column): the exact member list of an
	 * ambient-occluded visual note — its head plus every chart note the
	 * overlap pass merged into the sprite.
	 *
	 * Notes interleaved from other lanes, and other columns of the same
	 * lane (chord partners), are skipped: they own their own sprites and
	 * their own judgements. The merge chain guarantees this filter is
	 * exact — a same-column note inside the span that did NOT merge would
	 * have been drawn itself and split the group's span, so it cannot
	 * lie between a head and its registered tail.
	 *
	 * @param lane      The strumline the visual note is on.
	 * @param index     The column (receptor index) of the visual note.
	 * @param fromIndex The head's global chart index (inclusive).
	 * @param toIndex   The tail's global chart index (inclusive).
	 * @param out       Array the member indexes are appended to.
	 * @return The number of members appended.
	**/
	function getNotesFromRange(lane:Int, index:Int, fromIndex:Int64, toIndex:Int64, out:Array<Int64>):Int {
		if (out == null)
			return 0;
		var appended = 0;
		var len = File.getLength();
		if (len <= 0)
			return 0;

		var i = fromIndex;
		while (i <= toIndex) {
			if (i < 0) {
				i = i + 1;
				continue;
			}
			if (i >= len)
				break;
			var n = File.getNote(i);
			if (NoteSystem.clampLane(n.lane, laneCount) == lane && n.index == index) {
				out.push(i);
				++appended;
			}
			i = i + 1;
		}
		return appended;
	}

	// ------------------------------------------------------------------
	// Ambient-occlusion group registration
	// ------------------------------------------------------------------

	/**
	 * Registers every ambient-occluded note in the global-index span
	 * [head .. tail] of (lane, index) as HIT: judgement bits set (through
	 * registerRange, over contiguous runs of member indexes) and hit
	 * flags cleared (missed=false).
	 *
	 * Called when the visual note's head is hit — by the opponent/botplay
	 * auto-hit, by the player's press (via NoteSystem.registerPlayerHit),
	 * anywhere a head resolves — so every note the sprite represents
	 * resolves with it and none can linger on the strumline as an
	 * un-judged "not pressed yet" ghost.
	 *
	 * @param lane  The strumline row of the visual note.
	 * @param index The column (receptor index) of the visual note.
	 * @param head  The head note's global chart index.
	 * @param tail  The last merged note's global chart index.
	 * @return The number of notes registered (the visual group's size).
	**/
	function judgeRangeHit(lane:Int, index:Int, head:Int64, tail:Int64):Int {
		return judgeRange(lane, index, head, tail, false);
	}

	/**
	 * Registers every ambient-occluded note in the global-index span
	 * [head .. tail] of (lane, index) as MISSED: judgement bits set the
	 * same way, hit flags raised (missed=true). Called when a playable
	 * head scrolls past the hit window, so the whole visual group misses
	 * with its head and the miss scoring's notesInOne matches the number
	 * of notes actually resolved.
	 *
	 * @param lane  The strumline row of the visual note.
	 * @param index The column (receptor index) of the visual note.
	 * @param head  The head note's global chart index.
	 * @param tail  The last merged note's global chart index.
	 * @return The number of notes registered (the visual group's size).
	**/
	function judgeRangeMiss(lane:Int, index:Int, head:Int64, tail:Int64):Int {
		return judgeRange(lane, index, head, tail, true);
	}

	function judgeRange(lane:Int, index:Int, head:Int64, tail:Int64, missed:Bool):Int {
		if (tail < head)
			tail = head;

		var members:Array<Int64> = [];
		var count = getNotesFromRange(lane, index, head, tail, members);
		if (count == 0) {
			// Defensive: the span walked out of the chart or the head was
			// removed. The head itself must still resolve.
			File.setHitFlag(head, missed);
			setJudged(lane, head);
			return 1;
		}

		// Register contiguous runs of member indexes with bulk
		// registerRange calls — a gap in a run is a note of another lane
		// (or another column) interleaved into the global order, whose
		// bit lives elsewhere and must not be judged with this group.
		var haveRun = false;
		var runStart:Int64 = 0;
		var prev:Int64 = 0;
		for (m in members) {
			File.setHitFlag(m, missed);
			if (!haveRun) {
				runStart = m;
				haveRun = true;
			} else if (m != prev + 1) {
				registerRange(lane, runStart, prev);
				runStart = m;
			}
			prev = m;
		}
		if (haveRun)
			registerRange(lane, runStart, prev);

		return count;
	}
}
