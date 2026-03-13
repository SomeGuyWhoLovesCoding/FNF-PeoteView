package elements;

import elements.text.*;

/**
	The text buffer class.

	Owns two `TextInternal` layers:
	  • `outlineLayer`  – rendered first (behind), for drop-shadows / fat outlines
	  • `fillLayer`     – rendered second (in front), the primary visible text

	All properties delegate to both layers so they stay in sync.
	Configure `outlineLayer` directly for anything that should differ between them.
**/
@:publicFields
class Text {

	var _key:String;

	var display:Display;

	/** The behind layer — tweak its color/outlineSize to add a shadow or secondary outline. **/
	var outlineLayer:TextInternal;

	/** The front layer — the primary visible text. **/
	var fillLayer:TextInternal;

	// ── delegating properties ─────────────────────────────────────────

	var text(default, set):String = "";

	function set_text(str:String) {
		if (str == text) return text;
		outlineLayer.text = str;
		fillLayer.text    = str;
        outlineLayer.renderOutline(); // Render outline after setting text
		return text = str;
	}

	var x(default, set):Float = 0;

	function set_x(value:Float) {
		if (value == x) return x;
		outlineLayer.x = value;
		fillLayer.x    = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return x = value;
	}

	var y(default, set):Float = 0;

	function set_y(value:Float) {
		if (value == y) return y;
		outlineLayer.y = value/* - 10*/;
		fillLayer.y    = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return y = value;
	}

	var scale(default, set):Float = 1.0;

	function set_scale(value:Float) {
		if (value == scale) return scale;
		outlineLayer.scale = value;
		fillLayer.scale    = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return scale = value;
	}

	var _scale(get, never):Float;
	function get__scale() return fillLayer._scale;

	var width (get, never):Float;
	function get_width()  return fillLayer.width;

	var height(get, never):Float;
	function get_height() return fillLayer.height;

	var alpha(default, set):Float = 1.0;

	function set_alpha(value:Float):Float {
		outlineLayer.alpha = value;
		fillLayer.alpha    = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return alpha = value;
	}

	var color(default, set):Color = 0xFFFFFFFF;

	function set_color(value:Color):Color {
		fillLayer.color    = value;
		outlineLayer.color = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return color = value;
	}

	var outlineColor(default, set):Color = 0x000000FF;

	function set_outlineColor(value:Color):Color {
		outlineLayer.color = value;
		outlineLayer.outlineColor = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return outlineColor = value;
	}

	var outlineSize(default, set):Float = 0;

	function set_outlineSize(value:Float):Float {
		outlineLayer.outlineSize = value;
		outlineLayer.x = x;
		outlineLayer.y = y;
        outlineLayer.renderOutline(); // Render outline after setting text
		return outlineSize = value;
	}

	var font(default, set):String;

	function set_font(value:String) {
		if (font == value) return value;
		outlineLayer.font = value;
		fillLayer.font    = value;
        outlineLayer.renderOutline(); // Render outline after setting text
		return font = value;
	}

	function setMarkerPair(part:String, color:Color, outlineColor:Color = 0x000000FF, outlineSize:Float = 0) {
		outlineLayer.setMarkerPair(part, outlineColor, outlineColor, outlineSize);
        outlineLayer.renderOutline(); // Render outline after setting text
		fillLayer.setMarkerPair(part, color, color, 0);
	}

	// ─────────────────────────────────────────────────────────────────

	function new(key:String, x:Float, y:Float, display:Display, text:String = "Sample text", font:String = "vcr") {
		_key         = key;
		this.display = display;

		// outlineLayer is added to the display first so it draws behind fillLayer
		outlineLayer = new TextInternal(x, y, display, font, true);
		fillLayer    = new TextInternal(x, y, display, font);

		if (text == null || text.length == 0) text = "Sample text";

		this.text = text;
		this.x    = x;
		this.y    = y;
	}

	/**
		Screen center the sprite at a specific axis, in a display.
		@param axis The axis you want to center the sprite to.
	**/
	function screenCenter(axis:Axis = XY) {
		outlineLayer.screenCenter(axis);
		fillLayer.screenCenter(axis);
        outlineLayer.renderOutline(); // Render outline after setting text
	}

	function dispose() {
		outlineLayer.dispose();
		fillLayer.dispose();
		display = null;
	}

	function removeProgram() {
		display.removeProgram(outlineLayer.program);
		display.removeProgram(fillLayer.program);
	}

	function addProgram() {
		display.addProgram(outlineLayer.program);
		display.addProgram(fillLayer.program);
	}
}
