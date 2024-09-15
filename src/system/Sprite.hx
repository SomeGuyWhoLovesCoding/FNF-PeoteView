package system;

import utils.Loader;
import haxe.io.Bytes;

/**
 * The sprite.
 */
@:publicFields
class Sprite implements Element
{
	/**
	 * The sprite's x position.
	 */
	@posX var x:Float;

	/**
	 * The sprite's y position.
	 */
	@posY var y:Float;

	/**
	 * The sprite's z position.
	 */
	@zIndex var z:Int;

	/**
	 * The sprite's width.
	 */
	@sizeX var w:Int;

	/**
	 * The sprite's height.
	 */
	@sizeY var h:Int;

	/**
	 * The rotation around pivot point of the sprite.
	 */
	@rotation var r:Float;

	/**
	 * The pivot x of the sprite.
	 */
	@pivotX var px:Int;

	/**
	 * The pivot y of the sprite.
	 */
	@pivotY var py:Int;

	/**
	 * The color (in RGBA format) of the sprite.
	 */
	@color var c:Color = 0xffffffff;

	/**
	 * The texture slot of this sprite.
	 */
	@texSlot var slot:Int;

	/**
	 * Constructs a sprite.
	 */
	function new(x:Float = 0, y:Float = 0, z:Int = 0) {
        this.x = x;
        this.y = y;
        this.z = z;
    }

	/**
	 * Loads a texture.
	 * @param texture 
	 */
	function loadTexture(texture:Texture) {
		// WIP
	}

	
}
