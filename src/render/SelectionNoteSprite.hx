package render;

/**
	One selected note's highlight ELEMENT (v3.5): the per-note selection
	graphic — a translucent fill plus a bright 1px edge outline drawn
	around the note's rectangle, the same visual language as the box it
	was selected with (SelectionBoxSprite).

	Why a SEPARATE graphic, and not just more quads in the box's buffer:
	the selection elements can OVERLAP — each other and the box itself —
	and elements that share one buffer share one draw call, so the blend
	order between the box's translucent fill and the highlights is
	whatever the element order happens to be, and overlapping highlights
	stack their fills into mud. The elements therefore live in a buffer +
	program of their OWN (StrumlineNoteInteraction keeps two: one for the
	box, one for the element pool), layered ABOVE the box's: overlaps
	become deterministic — box below, elements above in note order — and
	a bright 1px edge survives another element's fill sitting on top of
	it, so every selected note stays individually readable even when
	elements overlap.

	The class owns FIVE plain RepeatSprites (the fill + the four edge
	lines) like the box does, centered by `setHighlight(cx, cy, size)`; it
	never touches the chart itself. Kept as one sprite OBJECT so the owner
	only ever handles "this note's selection element", not five loose
	rects.

	@since Development
**/
@:publicFields
class SelectionNoteSprite {
	/** The translucent fill rect (over the note's drawn rectangle). */
	var fill:RepeatSprite;
	/** The four edge outline rects (top/bottom/left/right, 1px thick). */
	var edgeTop:RepeatSprite;
	var edgeBottom:RepeatSprite;
	var edgeLeft:RepeatSprite;
	var edgeRight:RepeatSprite;

	/**
		Places the element over one note: centered on (cx, cy), sized to
		`size` (the note's drawn width) scaled by 1.15 — the same generous
		overlap the v3.3 flat quad used, so holds and notes near the lane
		edges stay fully covered. The 1px edges are drawn INWARD so the
		outline never grows past the element's outer footprint.
	**/
	function setHighlight(cx:Float, cy:Float, size:Float) {
		var w = Std.int(size * 1.15);
		var bx = Std.int(cx - w * 0.5);
		var by = Std.int(cy - w * 0.5);
		fill.x = bx;
		fill.y = by;
		fill.w = w;
		fill.h = w;
		// 1px edges drawn INWARD (same discipline as the box's) so two
		// adjacent elements never bleed into each other's footprint.
		edgeTop.x = bx;
		edgeTop.y = by;
		edgeTop.w = w;
		edgeTop.h = 1;
		edgeBottom.x = bx;
		edgeBottom.y = by + w - 1;
		edgeBottom.w = w;
		edgeBottom.h = 1;
		edgeLeft.x = bx;
		edgeLeft.y = by;
		edgeLeft.w = 1;
		edgeLeft.h = w;
		edgeRight.x = bx + w - 1;
		edgeRight.y = by;
		edgeRight.w = 1;
		edgeRight.h = w;
	}

	/** Hides the element (zero size on all five rects). */
	function hide() {
		fill.w = 0;
		fill.h = 0;
		edgeTop.w = 0;
		edgeTop.h = 0;
		edgeBottom.w = 0;
		edgeBottom.h = 0;
		edgeLeft.w = 0;
		edgeLeft.h = 0;
		edgeRight.w = 0;
		edgeRight.h = 0;
	}

	/** Adds all five elements to a buffer (attach-time). */
	function addToBuffer(buf:Buffer<RepeatSprite>) {
		buf.addElement(fill);
		buf.addElement(edgeTop);
		buf.addElement(edgeBottom);
		buf.addElement(edgeLeft);
		buf.addElement(edgeRight);
	}

	/** Pushes the current geometry to a buffer (per-frame or on change). */
	function updateIn(buf:Buffer<RepeatSprite>) {
		buf.updateElement(fill);
		buf.updateElement(edgeTop);
		buf.updateElement(edgeBottom);
		buf.updateElement(edgeLeft);
		buf.updateElement(edgeRight);
	}

	/** Removes all five elements from a buffer (detach-time). */
	function removeFromBuffer(buf:Buffer<RepeatSprite>) {
		buf.removeElement(fill);
		buf.removeElement(edgeTop);
		buf.removeElement(edgeBottom);
		buf.removeElement(edgeLeft);
		buf.removeElement(edgeRight);
	}

	function new() {
		fill = new RepeatSprite(0, 0, 0, 0);
		fill.c = 0x00FFFFFF; // cyan translucent fill
		fill.c.aF = 0.18;
		fill.c.luminanceF = 0.05;
		fill.r = 0;
		edgeTop = new RepeatSprite(0, 0, 0, 0);
		edgeBottom = new RepeatSprite(0, 0, 0, 0);
		edgeLeft = new RepeatSprite(0, 0, 0, 0);
		edgeRight = new RepeatSprite(0, 0, 0, 0);
		for (e in [edgeTop, edgeBottom, edgeLeft, edgeRight]) {
			e.c = 0x00FFFFFF; // solid bright cyan outline
			e.c.aF = 0.75;
			e.c.luminanceF = 0.15;
			e.r = 0;
		}
	}
}
