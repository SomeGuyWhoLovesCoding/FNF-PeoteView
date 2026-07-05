package elements;

/**
	The sustain note of the note sprite.
	@since Development
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
	
	// Object pool for reducing GC pressure
	static var pool:Array<Sustain> = [];
	static var poolSize:Int = 0;

	public var length:Int;

	@texTile @set("properties") var tile:Int = 0;

	// at what x position it have to slice (width of the tail in texturedata pixels) (WARNING: COUNT X POSITION FROM PNG BACKWARDS)
	@varying @custom @set("properties") public var tailPoint:Int = 43;

	// stuff that makes the note actually move
	public var diff:Int = 0;
	public var scrollDirection:Int = 90;

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

	inline public function new(x:Int = 0, y:Int = 0, w:Int = 100, h:Int = 100, r:Float = 0, s:Float = 1.0, sc:Float = 1.0, tile:Int = 0, tailPoint:Int = 43) {
		setProperties(x, y, w, h, r, s, sc, tile, tailPoint);
	}
	
	/**
	 * Acquires a Sustain from the object pool or creates a new one if pool is empty.
	 * @param x X position
	 * @param y Y position
	 * @param w Width
	 * @param h Height
	 * @param r Rotation
	 * @param s Speed
	 * @param sc Scale factor
	 * @param tile Tile ID
	 * @param tailPoint Tail point for slicing
	 * @return A Sustain instance from the pool or newly created
	 */
	static public inline function acquire(x:Int = 0, y:Int = 0, w:Int = 100, h:Int = 100, r:Float = 0, s:Float = 1.0, sc:Float = 1.0, tile:Int = 0, tailPoint:Int = 43):Sustain {
		var sustain:Sustain = null;
		if (poolSize > 0) {
			sustain = pool[--poolSize];
			pool[poolSize] = null;
		} else {
			sustain = new Sustain();
		}
		sustain.setProperties(x, y, w, h, r, s, sc, tile, tailPoint);
		return sustain;
	}
	
	/**
	 * Returns a Sustain to the object pool for reuse.
	 * The sustain should not be used after calling this method.
	 * @param sustain The sustain to return to the pool
	 */
	static public inline function release(sustain:Sustain):Void {
		if (sustain != null) {
			if (poolSize < pool.length) {
				pool[poolSize++] = sustain;
			} else {
				pool.push(sustain);
				poolSize++;
			}
		}
	}
	
	/**
	 * Clears all sustains from the pool. Call this when disposing or resetting the game state.
	 */
	static public inline function clearPool():Void {
		pool = [];
		poolSize = 0;
	}

	inline public function changeID(id:Int) {
		tile = id;
		tailPoint = tailPoints[id];
	}
}