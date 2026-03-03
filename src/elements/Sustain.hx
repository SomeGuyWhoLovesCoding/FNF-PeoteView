package elements;

/**
	The sustain note of the note sprite.
**/
class Sustain implements Element
{
	// position in pixel (relative to upper left corner of Display)
	@posX @formula("uDisplayRotateX(aPos + vec2(0.0, py))") @set("properties") public var x:Int;
	@posY @formula("uDisplayRotateY(aPos + vec2(0.0, py))") @set("properties") public var y:Int;

	// size in pixel
	@varying @sizeX @formula("w * speed") @set("properties") public var w:Int;
	@varying @sizeY @formula("h * scale") @set("properties") public var h:Int;

	@rotation @formula("uDisplayRotation(r)") @set("properties") public var r:Float;

	@pivotY @const @formula("h * 0.5") public var py:Int;

	@color public var c:Color = 0xFFFFFFFF;

	@varying @custom @set("properties") public var speed:Float = 1.0;

	@varying @custom @set("properties") public var scale:Float = 1.0;

	static public var defaultAlpha:Float = 0.6;
	static public var defaultMissAlpha:Float = 0.3;

	public var length:Int;

	@texTile @set("properties") var tile:Int = 0;

	// at what x position it have to slice (width of the tail in texturedata pixels) (WARNING: COUNT X POSITION FROM PNG BACKWARDS)
	@varying @custom @set("properties") public var tailPoint:Int = 43;

	/**
		The parent of this note sprite.
	**/
	public var parent:Note;

	static public var offsets:Array<Array<Int>> = [];
	static public var tailPoints:Array<Int> = [];

	static public function init(program:CustomProgram, name:String, texture:Texture)
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

				vec2 raw = vec2(
					(tailPoint * $invTileH * vSize.y) / vSize.x,
					tailPoint * $invTileW
				);
				vec2 tail = vec2(1.0) - raw;

				vec2 t = vec2(
					fract((1.0 - coord.x / tail.x) * (vSize.x * $tileH / vSize.y - tailPoint) / ($tileW - tailPoint)),
					(coord.x - tail.x) / raw.x  // reuse raw.x instead of recomputing 1.0 - tail.x
				);

				vec2 coordX = mix(vec2(tail.y), vec2(0.0, 1.0), t);

				coord.x = mix(coordX.x, coordX.y, step(tail.x, coord.x));

				return getTextureColor(textureID, coord);
			}
		');

		// instead of using normal "name" identifier to fetch the texture-color,
		// the postfix "_ID" gives access to use getTextureColor(textureID, ...) or getTextureResolution(textureID)
		program.setColorFormula( 'c * slice(${name}_ID, tailPoint)' );
	}

	inline public function new(x:Int, y:Int, w:Int, h:Int, r:Float, s:Float, sc:Float, tile:Int, tailPoint:Int) {
		setProperties(x, y, w, h, r, s, sc, tile, tailPoint);
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