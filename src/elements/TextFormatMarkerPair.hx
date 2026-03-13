package elements;

class TextFormatMarkerPair {
	public var marker:String;
	public var color:Color;
	public var outlineColor:Color;
	public var outlineSize:Float;
	
	public function new(marker:String, color:Color, ?outlineColor:Color = 0x000000FF, ?outlineSize:Float = 0) {
		this.marker = marker;
		this.color = color;
		this.outlineColor = outlineColor;
		this.outlineSize = outlineSize;
	}
}