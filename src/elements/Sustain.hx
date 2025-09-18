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

	// Precomputed variables
	static var invTileW:Float;
	static var invTileH:Float;
	static var aspectInvH:Float;
	static var coordScale:Float;

	static public function init(program:Program, name:String, texture:Texture)
	{
	    program.setTexture(texture, name);
	    program.blendEnabled = true;
	    program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
	    program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
	
	    var tileW:Float = texture.width / texture.tilesX;
	    var tileH:Float = texture.height / texture.tilesY;
	
	    // precompute uniforms
	    invTileW = 1.0 / tileW;
	    invTileH = 1.0 / tileH;
	    aspectInvH = tileW / tileH;
	    coordScale = invTileH / invTileW;
	
	    // slice-related uniforms
	    // Note: tailPoint varies per note, we still need it as a varying
	    var uniforms = [
	        new UniformFloat("uInvTileW", invTileW),
	        new UniformFloat("uInvTileH", invTileH),
	        new UniformFloat("uAspectInvH", aspectInvH),
	        new UniformFloat("uCoordScale", coordScale)
	    ];
	
	    program.injectIntoFragmentShader('
	        vec4 slice(int textureID, float tailPoint, float slicePosX, float invOneMinusSlice, float uAspectTail) {
	            vec2 coord = vTexCoord;
	
	            float tailW = tailPoint * uInvTileW;
	
	            // Left side coordinate
	            float leftFrac = fract(
	                (1.0 - coord.x / slicePosX) * uAspectTail * uCoordScale / (1.0 - tailPoint * uInvTileW)
	            );
	            float coordLeft = mix(1.0 - tailW, 0.0, leftFrac);
	
	            // Right side coordinate
	            float coordRight = mix(1.0 - tailW, 1.0,
	                                   (coord.x - slicePosX) * invOneMinusSlice);
	
	            // Branchless selection
	            coord.x = mix(coordRight, coordLeft, step(coord.x, slicePosX));
	
	            return getTextureColor(textureID, coord);
	        }
	    ', false, uniforms);
	
	    program.setColorFormula('c * slice(${name}_ID, tailPoint, slicePosX, invOneMinusSlice, uAspectTail)');
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
