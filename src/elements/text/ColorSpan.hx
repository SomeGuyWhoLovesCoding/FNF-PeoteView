package elements.text;

/**
	Text's color span.
	@since Development
**/
class ColorSpan {
	public var start:Int;
	public var end:Int;
	public var color:Color;
	public var outlineColor:Color;
	public var outlineSize:Float;

	public function new(start:Int, end:Int, color:Color, outlineColor:Color, outlineSize:Float) {
		this.start = start;
		this.end = end;
		this.color = color;
		this.outlineColor = outlineColor;
		this.outlineSize = outlineSize;
	}
}
