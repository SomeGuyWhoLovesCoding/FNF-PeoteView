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
	@posX @formula("x + px + ox") public var x:Int;
	@posY @formula("y + py + oy") public var y:Int;

	// size in pixel
	@varying @sizeX @formula("w * scale") public var w:Int = 100;
	@varying @sizeY @formula("h * scale") public var h:Int = 100;
	@varying @custom public var scale:Float = 1.0;

	@rotation public var r:Float;

	@pivotX @const @formula("w * 0.5") public var px:Int;
	@pivotY @const @formula("h * 0.5") public var py:Int;

	@color public var c:Color = 0xFFFFFFFF;

	@varying @custom public var initialAlpha(default, set):Float = 1.0;
	inline public function set_initialAlpha(value:Float) {
		initialAlpha = value;

		if (initialAlpha < 0) initialAlpha = 0;
		if (initialAlpha > 1) initialAlpha = 1;
		return value;
	}

	@varying @custom public var addedAlpha:Float = 0.0;

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

	static public var offsetAndSizeFramesGM:Array<Int> = [];
	static public var enableGM:Bool;

	public var id:Int = 0;

	inline public function new(x:Int, y:Int, w:Int, h:Int) {
		this.x = x;
		this.y = y;
		this.w = w;
		this.h = h;
		reset();
	}

	static public function init(program:Program, name:String, texture:Texture)
	{
		// creates a texture-layer named "name"
		program.setTexture(texture, name);
		program.blendEnabled = true;
		program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
		program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

		program.injectIntoFragmentShader(
		'
			vec4 why(int textureID, float initialAlpha, float addedAlpha)
			{
				vec2 coord = vTexCoord;
				vec4 tex = getTextureColor(textureID, coord);

				if (tex.a != 0.0) {
					float oldA = tex.a;
					float newA = clamp(oldA * initialAlpha + addedAlpha, 0.0, 1.0);

					// Adjust premultiplied color to match the new alpha
					if (oldA > 0.0) {
						tex.rgb *= newA / oldA;
					}

					tex.a = newA;
				}

				return tex;
			}
		');

		// instead of using normal "name" identifier to fetch the texture-color,
		// the postfix "_ID" gives access to use getTextureColor(textureID, ...) or getTextureResolution(textureID)
		program.setColorFormula( 'c * why(${name}_ID, initialAlpha, addedAlpha)' );
	}

	inline public function toggleGMVariant(/*mult:Int, */g:Int, isCover:Bool) {
		var granularityValue = g - 1;
		//var int = (id + (granularityValue * 2)) * (24 - (isCover ? 12 : 0));
		var int = ((id * (arrayLengthOfNoteSkin_gm())) + (granularityValue * 2) + (isCover ? 1 : 0)) * 6;
		//Sys.println(toggleGMVariant);
		//Sys.println(int);
		//trace(/*mult,*/g,isCover,id,int,ox,oy,px,py);
		setOffsetAndSizeGM(int);
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

	private function setOffsetAndSizeGM(offset:Int) {
		clipX = offsetAndSizeFramesGM[offset];
		clipY = offsetAndSizeFramesGM[offset + 1];
		w = clipWidth = clipSizeX = offsetAndSizeFramesGM[offset + 2];
		h = clipHeight = clipSizeY = offsetAndSizeFramesGM[offset + 3];
		ox = offsetAndSizeFramesGM[offset + 4];
		oy = offsetAndSizeFramesGM[offset + 5];
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

	private function isOffsetAndSizeGM(offset:Int) {
		var X = offsetAndSizeFramesGM[offset];
		var Y = offsetAndSizeFramesGM[offset + 1];
		var width = offsetAndSizeFramesGM[offset + 2];
		var height = offsetAndSizeFramesGM[offset + 3];
		return clipX == X && clipY == Y &&
			(clipWidth == width && clipSizeX == width) && (clipHeight == height && clipSizeY == height) &&
			ox == offsetAndSizeFramesGM[offset + 4] && oy == offsetAndSizeFramesGM[offset + 5];
	}

	inline static function arrayLengthOfNoteSkin_main() {
		return Std.int(Math.ffloor(offsetAndSizeFrames.length) / KEYS);
	}

	inline static function arrayLengthOfNoteSkin_gm() {
		return Std.int(Math.ffloor(offsetAndSizeFramesGM.length) / (KEYS * 6));
	}
}
