package elements;

/**
	The note sprite of the note system. This is also used for the receptor.
**/
class Note implements Element
{
	static public var defaultAlpha:Float = 1;
	static public var defaultMissAlpha:Float = 0.5;

	// position in pixel (relative to upper left corner of Display)
	@varying @custom @formula("ox * scale") public var ox:Int;
	@varying @custom @formula("oy * scale") public var oy:Int;
	@posX @formula("uDisplayRotateX(((aPos + vec2(px, py) + vec2(ox, oy))) - vec2(diff * cos(scrollDirection * 0.01745329), (diff * sin(scrollDirection * 0.01745329))))") @set("properties") public var x:Int;
	@posY @formula("uDisplayRotateY(((aPos + vec2(px, py) + vec2(ox, oy))) - vec2(diff * cos(scrollDirection * 0.01745329), (diff * sin(scrollDirection * 0.01745329))))") @set("properties") public var y:Int;

	// size in pixel
	@varying @sizeX @formula("w * scale") @set("properties") public var w:Int = 100;
	@varying @sizeY @formula("h * scale") @set("properties") public var h:Int = 100;
	@varying @custom @set("properties") public var scale:Float = 1.0;

	@rotation @formula("uDisplayRotation(r)") public var r:Float;

	@pivotX @const @formula("w * 0.5") public var px:Int;
	@pivotY @const @formula("h * 0.5") public var py:Int;

	@color public var c:Color = 0xFFFFFFFF;

	@varying @custom @set("properties") public var initialAlpha(default, set):Float = 1.0;
	inline public function set_initialAlpha(value:Float) {
		initialAlpha = value;

		if (initialAlpha < 0) initialAlpha = 0;
		if (initialAlpha > 1) initialAlpha = 1;
		return value;
	}

	@varying @custom @set("properties") public var addedAlpha:Float = 0.0;

	// stuff that makes the note actually move
	@varying @custom public var diff:Int = 0;
	@varying @custom public var scrollDirection:Int = 90;

	// extra tex attributes for clipping
	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int = 100;
	@texH var clipHeight:Int = 100;

	// extra tex attributes to adjust texture within the clip
	@texPosX  var clipPosX:Int = 0;
	@texPosY  var clipPosY:Int = 0;
	@texSizeX var clipSizeX:Int = 100;
	@texSizeY var clipSizeY:Int = 100;

	public var rW:Int;
	public var rH:Int;

	static public var KEYS:Int;

	// this was done to mimic sparrow atlas functionality
	static public var offsetAndSizeFrames:Array<Int> = [];

	public var id:Int = 0;

	inline public function new(x:Int, y:Int, w:Int, h:Int, scale:Float = 1.0, initialAlpha:Float = 1.0, addedAlpha:Float = 0.0) {
		reset();
		setProperties(x, y, w, h, scale, initialAlpha, addedAlpha);
	}

	static public function init(program:CustomProgram, name:String, texture:Texture)
	{
		// creates a texture-layer named "name"
		program.setTexture(texture, name);

		program.injectIntoFragmentShader(
		'
			vec4 why(int textureID, float initialAlpha, float addedAlpha)
			{
				vec4 tex = getTextureColor(textureID, vTexCoord);
				if (tex.a == 0.0) return tex;

				float newA = clamp(tex.a * initialAlpha + addedAlpha, 0.0, 1.0);

				return vec4(tex.rgb * (newA / tex.a), newA);
			}
		');

		// instead of using normal "name" identifier to fetch the texture-color,
		// the postfix "_ID" gives access to use getTextureColor(textureID, ...) or getTextureResolution(textureID)
		program.setColorFormula( 'c * why(${name}_ID, initialAlpha, addedAlpha)' );
	}

	inline public function changeID(id:Int) {
		this.id = id;
	}

	// Command functions

	inline public function reset() {
		setOffsetAndSize(0 + ((arrayLengthOfNoteSkin_main()) * id));
		rW = w;
		rH = h;
	}

	inline public function toNote() {
		setOffsetAndSize(6 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	inline public function press() {
		setOffsetAndSize(12 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	inline public function confirm() {
		setOffsetAndSize(18 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	// Checking functions

	inline public function idle() {
		return isOffsetAndSize(0 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	inline public function isNote() {
		return isOffsetAndSize(6 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	inline public function pressed() {
		return isOffsetAndSize(12 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	inline public function confirmed() {
		return isOffsetAndSize(18 + ((arrayLengthOfNoteSkin_main()) * id));
	}

	private function setOffsetAndSize(offset:Int) {
		clipX = offsetAndSizeFrames[offset];
		clipY = offsetAndSizeFrames[offset + 1];
		w = clipWidth = clipSizeX = offsetAndSizeFrames[offset + 2];
		h = clipHeight = clipSizeY = offsetAndSizeFrames[offset + 3];
		ox = offsetAndSizeFrames[offset + 4];
		oy = offsetAndSizeFrames[offset + 5];
	}

	private function isOffsetAndSize(offset:Int) {
		var X = offsetAndSizeFrames[offset];
		var Y = offsetAndSizeFrames[offset + 1];
		var width = offsetAndSizeFrames[offset + 2];
		var height = offsetAndSizeFrames[offset + 3];
		return clipX == X && clipY == Y &&
			(clipWidth == width && clipSizeX == width) && (clipHeight == height && clipSizeY == height) &&
			ox == offsetAndSizeFrames[offset + 4] && oy == offsetAndSizeFrames[offset + 5];
	}

	inline static function arrayLengthOfNoteSkin_main() {
		return Std.int(Math.ffloor(offsetAndSizeFrames.length) / KEYS);
	}
}
