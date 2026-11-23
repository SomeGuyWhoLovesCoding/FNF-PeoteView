package underlying.rhythm;

import underlying.rhythm.NoteVB.VirtualNote;

/**
 * Represents a single receptor/lane, consolidating all per-index state
 * previously held in parallel arrays within Strumline.
 * @since 0.94
**/
@:publicFields
class Receptor {
	var note:Note;

	var noteToHit:MetaNote;
	var noteToHit_sprite:Note;
	var noteToHit_index:Int64;

	var sustainToHold:MetaNote;
	var sustainToHold_index:Int64;
	var sustainToHold_duration:Int;

	var botHitToCheck:Bool;
	var playerHitToCheck:Bool;

	var ambientOccludeYPrev:Int;
	var ambientOccludeYCur:Int;

	// The sprite of the CURRENT ambient-occlusion group head for this
	// column — the merge target every overlapping note of this (lane,
	// index) is folded into within one processNotes pass. Per-column
	// tracking (instead of one global "last drawn sprite") keeps merges
	// from bleeding onto a chord partner's sprite, and gives the pass a
	// stable head whose globalIndex..judgementRangeEnd span is exactly
	// the group the two-dimensional judgement system registers on hit.
	// Only meaningful WITHIN one pass; cleared by clearOverlapState().
	var ambientOccludeHead:VirtualNote;

	var confirmTimer:ReceptorTimer;
	var sustainActive:Bool;
	var sustainResolved:Bool;

	var sustainPivotX:Int = 0;
	var sustainPivotY:Int = 0;

	function new(note:Note) {
		this.note = note;
		resetState();
	}

	function resetState() {
		noteToHit = null;
		noteToHit_sprite = null;
		noteToHit_index = 0;

		sustainToHold = null;
		sustainToHold_index = 0;
		sustainToHold_duration = 0;

		botHitToCheck = false;
		playerHitToCheck = false;

		ambientOccludeHead = null;

		confirmTimer = new ReceptorTimer(Math.POSITIVE_INFINITY, Math.POSITIVE_INFINITY, Math.POSITIVE_INFINITY);
		sustainActive = false;
		sustainResolved = false;
	}

	inline function updateAnimation(songPosition:Float) {
		if (songPosition > confirmTimer.tailTime) {
			note.press();
			confirmTimer.tailTime = Math.POSITIVE_INFINITY;
		}

		if (songPosition > confirmTimer.endTime) {
			note.reset();
			confirmTimer.startTime = Math.POSITIVE_INFINITY;
			confirmTimer.endTime = Math.POSITIVE_INFINITY;
		}
	}
}
