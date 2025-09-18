package elements;

/**
	The sustain note of the note sprite.
**/
class Sustain implements Element
{
	// position in pixel (relative to upper left corner of Display)
	@posX @formula("x") public var x:Int;
	@posY @formula("y + py") public var y:Int;

	// size in pixel
	@varying @sizeX @formula("w * speed") public var w:Int;
	@varying @sizeY @formula("h * scale") public var h:Int;

	// at what x position it have to slice (width of the tail in texturedata pixels) (WARNING: COUNT X POSITION FROM PNG BACKWARDS)
	@varying @custom public var tailPoint:Int = 43;

	@rotation public var r:Float;

	@pivotY @const @formula("h * 0.5") public var py:Int;

	@color public var c:Color = 0xFFFFFFFF;

	@varying @custom public var speed:Float = 1.0;

	@varying @custom public var scale:Float = 1.0;

	static public var defaultAlpha:Float = 0.6;
	static public var defaultMissAlpha:Float = 0.3;

	public var length:Int;

	@texTile var tile:Int = 0;

	/**
		The parent of this note sprite.
	**/
	public var parent:Note;

	static public var offsets:Array<Array<Int>> = [];
	static public var tailPoints:Array<Int> = [];

	static public function init(program:Program, name:String, texture:Texture)
	{
		// creates a texture-layer named "name"
		program.setTexture(texture, name);
		program.blendEnabled = true;
		program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
		program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

		var tileW = Util.toFloatString(texture.width / texture.tilesX);
		var tileH = Util.toFloatString(texture.height / texture.tilesY);
		var invTileW = Util.toFloatString(1.0 / (texture.width / texture.tilesX));
		var invTileH = Util.toFloatString(1.0 / (texture.height / texture.tilesY));

		program.injectIntoFragmentShader('
			vec4 slice(int textureID, float tailPoint) {
				vec2 coord = vTexCoord;

				// Slice position
				float slicePosX = 1.0 - (tailPoint * $invTileH * vSize.y) / vSize.x;
				float tailInvTileW = 1.0 - tailPoint * $invTileW;

				// Left branch: fold all arithmetic directly into fract()
				float leftCoordX = mix(
					tailInvTileW,
					0.0,
					fract(
						(1.0 - coord.x / slicePosX) * (vSize.x * $tileH / vSize.y - tailPoint) / ($tileW - tailPoint)
					)
				);

				// Right branch: inline oneMinusSlice
				float rightCoordX = mix(
					tailInvTileW,
					1.0,
					(coord.x - slicePosX) / (1.0 - slicePosX)
				);

				// Branchless select
				coord.x = mix(leftCoordX, rightCoordX, step(slicePosX, coord.x));

				return getTextureColor(textureID, coord);
			}
		');

		// instead of using normal "name" identifier to fetch the texture-color,
		// the postfix "_ID" gives access to use getTextureColor(textureID, ...) or getTextureResolution(textureID)
		program.setColorFormula( 'c * slice(${name}_ID, tailPoint)' );
	}

	inline public function new(x:Int, y:Int, w:Int, h:Int, id:Int = 0) {
		this.x = x;
		this.y = y;
		this.w = w;
		this.h = h;
	}

	inline public function changeID(id:Int) {
		tile = id;
		tailPoint = tailPoints[id];
	}

	inline public function followNote(note:Note) {
		var offset = offsets[note.id];
		x = note.x + (Math.floor(offset[0] * scale) >> 1);
		y = note.y + (Math.floor(offset[1] * scale) >> 1);
	}
}