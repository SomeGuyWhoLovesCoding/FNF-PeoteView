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
	@varying @sizeX @formula("w * speed") public var w(default, set):Int;
	inline function set_w(value:Int) {
		var tailH:Float = tailPoint * invTileH;
		slicePosX = 1.0 - tailH * h / value;
		return value;
	}
	@varying @sizeY @formula("h * scale") public var h(default, set):Int;
	inline function set_h(value:Int) {
		var tailH:Float = tailPoint * invTileH;
		slicePosX = 1.0 - tailH * value / w;
		return value;
	}

	// at what x position it have to slice (width of the tail in texturedata pixels) (WARNING: COUNT X POSITION FROM PNG BACKWARDS)
	@varying @custom public var tailPoint(default, set):Int = 43;

	inline function set_tailPoint(value:Int) {
		var tailH:Float = tailPoint * invTileH;
		slicePosX = 1.0 - tailH * h / w;
		uAspectTail = aspectInvH - tailPoint;
		return value;
	}

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

	static public var uniforms(default, null):Array<UniformFloat>; // Not varying. Uniforms can hold values that store directly in the shader instead of repeatedly computing. - sgwl

	// Varying
	@varying @custom public var slicePosX(default, set):Float;       // left/right threshold
	inline function set_slicePosX(value:Float) {
    	invOneMinusSlice = 1.0 / (1.0 - value);
		return value;
	}
	@varying @custom public var invOneMinusSlice:Float;
	@varying @custom public var uAspectTail:Float;

	static public function init(program:Program, name:String, texture:Texture)
	{
	    program.setTexture(texture, name);
	    program.blendEnabled = true;
	    program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
	    program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
	
	    var tileW:Float = texture.width / texture.tilesX;
	    var tileH:Float = texture.height / texture.tilesY;
	
	    // slice-related uniforms
	    // Note: tailPoint varies per note, we still need it as a varying
	    uniforms = [
	        new UniformFloat("uInvTileW", 1.0 / tileW),
	        new UniformFloat("uInvTileH", 1.0 / tileH),
	        new UniformFloat("uAspectInvH", tileW / tileH),
	        new UniformFloat("uCoordScale", invTileH / invTileW)
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
