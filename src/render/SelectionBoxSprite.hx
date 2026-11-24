package render;

/**
	The editor's SELECTION BOX element sprite (v3.4): an axis-aligned
	rectangle band drawn from two drag corner points — a translucent fill
	plus a bright 1px edge outline — that visually drives selecting every
	chart note the box touches.

	The class owns FIVE plain RepeatSprites (the fill + the four edge
	lines) and normalizes any corner pair into the axis-aligned rect; it
	never touches the chart itself (the interaction layer feeds it
	corners and reads `boxActive()`). Kept as one sprite OBJECT so the
	owner only ever handles "the selection box", not five loose rects —
	the elements ride in the owner's Buffer<RepeatSprite> with the
	selection highlight quads (above the grid program, below the ghost).

	@since Development
**/
@:publicFields
class SelectionBoxSprite {
	/** The translucent fill rect. */
	var fill:RepeatSprite;
	/** The four edge outline rects (top/bottom/left/right, 1px thick). */
	var edgeTop:RepeatSprite;
	var edgeBottom:RepeatSprite;
	var edgeLeft:RepeatSprite;
	var edgeRight:RepeatSprite;

	/**
		Updates the box from its two drag corners (any corner order —
		normalized here). A zero-area band hides all five elements.
	**/
	function setBox(x0:Float, y0:Float, x1:Float, y1:Float) {
		var bx = Std.int(Math.min(x0, x1));
		var by = Std.int(Math.min(y0, y1));
		var bw = Std.int(Math.abs(x1 - x0));
		var bh = Std.int(Math.abs(y1 - y0));
		fill.x = bx;
		fill.y = by;
		fill.w = bw;
		fill.h = bh;
		// 1px edges drawn INWARD so the outline never grows the band's
		// outer footprint (the capture rect and the visual stay equal).
		edgeTop.x = bx;
		edgeTop.y = by;
		edgeTop.w = bw;
		edgeTop.h = 1;
		edgeBottom.x = bx;
		edgeBottom.y = by + bh - 1;
		edgeBottom.w = bw;
		edgeBottom.h = 1;
		edgeLeft.x = bx;
		edgeLeft.y = by;
		edgeLeft.w = 1;
		edgeLeft.h = bh;
		edgeRight.x = bx + bw - 1;
		edgeRight.y = by;
		edgeRight.w = 1;
		edgeRight.h = bh;
	}

	/** Hides the box (zero size on all five elements). */
	function hideBox() {
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

	/** TRUE when the box currently has area (a band is being dragged). */
	function boxActive():Bool {
		return fill.w > 0 && fill.h > 0;
	}

	/** The box's normalized bounds (the capture rectangle). */
	function boundsX():Int
		return fill.x;
	function boundsY():Int
		return fill.y;
	function boundsW():Int
		return fill.w;
	function boundsH():Int
		return fill.h;

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
		fill.c = 0xFFFFFF00; // warm white translucent fill
		fill.c.aF = 0.10;
		fill.c.luminanceF = 0.05;
		fill.r = 0;
		edgeTop = new RepeatSprite(0, 0, 0, 0);
		edgeBottom = new RepeatSprite(0, 0, 0, 0);
		edgeLeft = new RepeatSprite(0, 0, 0, 0);
		edgeRight = new RepeatSprite(0, 0, 0, 0);
		for (e in [edgeTop, edgeBottom, edgeLeft, edgeRight]) {
			e.c = 0xFFFFFF00; // solid bright outline
			e.c.aF = 0.8;
			e.c.luminanceF = 0.15;
			e.r = 0;
		}
	}
}
