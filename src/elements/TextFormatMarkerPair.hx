package elements;

import elements.text.*;

/**
	The text format marker pair, to color the text with marker pairs.
	@since Development
**/
@:allow(elements.Text)
class TextFormatMarkerPair {
	public var marker(default, set):String;
	public var color(default, set):Color;
	public var outlineColor(default, set):Color;
	public var outlineSize(default, set):Float;

	private var _onChange:Void->Void = null;

	private inline function dirty() {
		if (_onChange != null) _onChange();
	}

	function set_marker(v:String):String     { marker       = v; dirty(); return v; }
	function set_color(v:Color):Color        { color        = v; dirty(); return v; }
	function set_outlineColor(v:Color):Color { outlineColor = v; dirty(); return v; }
	function set_outlineSize(v:Float):Float  { outlineSize  = v; dirty(); return v; }

	public function new(marker:String, color:Color, outlineColor:Color = 0x000000FF, outlineSize:Float = 0) {
		this.marker       = marker;
		this.color        = color;
		this.outlineColor = outlineColor;
		this.outlineSize  = outlineSize;
	}
}