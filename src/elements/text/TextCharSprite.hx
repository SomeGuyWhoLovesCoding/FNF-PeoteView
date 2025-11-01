package elements.text;

/**
	The underlying text character element.
**/
@:publicFields
class TextCharSprite implements Element {
	@posX @formula("x - os") var x:Float;
	@posY @formula("y - os")  var y:Float;
	@sizeX @formula("w + (os * 2.0)") var w:Float;
	@sizeY @formula("h + (os * 2.0)") var h:Float;

	// extra tex attributes for clipping
	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int  = 1;
	@texH var clipHeight:Int = 1;

	// extra tex attributes to adjust texture within the clip
	@texPosX  var clipPosX:Int = 0;
	@texPosY  var clipPosY:Int = 0;
	@texSizeX var clipSizeX:Int = 1;
	@texSizeY var clipSizeY:Int = 1;

	@color var c:Color = 0xFFFFFFFF;

	@color private var alphaColor:Color = 0xFFFFFFFF;

	var alpha(get, set):Float;

	inline function get_alpha() {
		return alphaColor.aF;
	}

	inline function set_alpha(value:Float) {
		value = Math.max(value, 0);
		alphaColor.luminanceF = value;
		return alphaColor.aF = value;
	}

	// outline implementation

	@color var oc:Color = 0x000000FF;
	@varying @custom var os:Float = 0.0;

	function new() {}
}