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

	@varying @custom public var initialAlpha:Float = 1.0;
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

	/**
		The data of this note sprite.
	**/
	public var data:MetaNote;

	/**
		The child of this note sprite.
	**/
	public var child:Sustain;

	public var playable:Bool;
	public var missed:Bool;

	public var rW:Int;
	public var rH:Int;

	static public var offsetAndSizeFrames:Array<Int> = [];

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
		program.setTexture(texture, name, true );
		program.blendEnabled = true;

		var tW:String = Util.toFloatString(texture.width / texture.tilesX);
		var tH:String = Util.toFloatString(texture.height / texture.tilesY);

		program.injectIntoFragmentShader(
		'
			vec4 why(int textureID, float initialAlpha, float addedAlpha)
			{
				vec2 coord = vTexCoord;
				vec4 tex = getTextureColor( textureID, coord );

				tex.a *= initialAlpha;
				tex.a += addedAlpha;

				return tex;
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
		setOffsetAndSize(0 + (24 * id));
		rW = w;
		rH = h;
	}

	inline public function toNote() {
		setOffsetAndSize(6 + (24 * id));
	}

	inline public function press() {
		setOffsetAndSize(12 + (24 * id));
	}

	inline public function confirm() {
		setOffsetAndSize(18 + (24 * id));
	}

	// Checking functions

	inline public function idle() {
		return isOffsetAndSize(0 + (24 * id));
	}

	inline public function isNote() {
		return isOffsetAndSize(6 + (24 * id));
	}

	inline public function pressed() {
		return isOffsetAndSize(12 + (24 * id));
	}

	inline public function confirmed() {
		return isOffsetAndSize(18 + (24 * id));
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
}
