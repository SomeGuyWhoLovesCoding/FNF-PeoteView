package tooling.fvlua;

/**
	The element with centered rotation and support for global rotation via camera rotation. Same API as `Sprite`, just without `clip*X/Y` for simplicity and maintainability.
	@since Development
**/
@:publicFields
class LuaSprite implements Element {
	/**
		The sprite's x position.
	**/
	@posX @formula("uDisplayRotateX(aPos + vec2(px, py))") var x:Float;

	/**
		The sprite's y position.
	**/
	@posY @formula("uDisplayRotateY(aPos + vec2(px, py))") var y:Float;

	/**
		The sprite's width.
	**/
	@sizeX var w:Float;

	/**
		The sprite's height.
	**/
	@sizeY var h:Float;

	/**
		The rotation around pivot point of the sprite.
	**/
	@rotation @formula("uDisplayRotation(r)") var r:Float;

	/**
		The pivot x of the sprite.
	**/
	@pivotX @formula("w * 0.5") var px:Int;

	/**
		The pivot y of the sprite.
	**/
	@pivotY @formula("h * 0.5") var py:Int;

	/**
		The color (in RGBA format) of the sprite.
	**/
	@color var c:Color = 0xffffffff;

	/**
		The texture slot of this sprite.
		This is used for multitexture.
	**/
	@texSlot var slot:Int;

	/**
		The texture tile of this sprite.
		This is used for texture tiling, which in case WILL performs better.
	**/
	@texTile var tile:Int;

	/**
		The sprite's options.
		@param texRepeatX Whenever the texture should repeat horizontally.
		@param texRepeatY Whenever the texture should repeat vertically.
		@param blend Whenever your sprite's texture should appear with crispy edges or not.
	**/
	var OPTIONS = {texRepeatX: false, texRepeatY: false, blend: true};

	/**
		Constructs a sprite.
		@param x The sprite's x.
		@param y The sprite's y.
	**/
	function new(x:Int = 0, y:Int = 0, w:Int = 0, h:Int = 0) {
		this.x = x;
		this.y = y;
		if (w != 0)
			this.w = w;
		if (h != 0)
			this.h = h;
	}

	/**
		Screen center the sprite at a specific axis, in a display.
		@param axis The axis you want to center the sprite to.
	**/
	function screenCenter(display:Display, axis:Axis = XY) {
		var _w:Float = display.width;
		var _h:Float = display.height;
		switch (axis) {
			case X:
				x = (_w - w) * 0.5;
			case Y:
				y = (_h - h) * 0.5;
			default:
				x = (_w - w) * 0.5;
				y = (_h - h) * 0.5;
		}
	}

	/**
	 * Helper function to set the graphic's dimensions by using `scale`, allowing you to keep the current aspect ratio
	 * should one of the numbers be `<= 0`. It might make sense to call `updateHitbox()` afterwards!
	 *
	 * @param   width    How wide the graphic should be. If `<= 0`, and `height` is set, the aspect ratio will be kept.
	 * @param   height   How high the graphic should be. If `<= 0`, and `width` is set, the aspect ratio will be kept.
	 * 
	 * ported from flixel.
	 */
	public function setGraphicSize(width = 0, height = 0):Void {
		if (width <= 0 && height <= 0)
			return;

		var newScaleX:Float = width / w;
		var newScaleY:Float = height / h;
		// scale.set(newScaleX, newScaleY);

		if (width <= 0)
			w = Std.int(newScaleY);
		else if (height <= 0)
			h = Std.int(newScaleX);
	}

	/**
		Sets the sprite's size to the texture's size at a specific axis.
		This is useful for multitexture.
		@param texture The texture you want to set the sprite's size to.
		@param axis The axis you want to rescale the sprite in.
	**/
	function setSizeToTexture(texture:Texture, axis:Axis = XY) {
		if (texture == null) {
			return;
		}

		var tW = texture.slotsX != 1 ? texture.slotWidth : Math.floor(texture.width / texture.tilesX);
		var tH = texture.slotsY != 1 ? texture.slotHeight : Math.floor(texture.height / texture.tilesY);

		switch (axis) {
			case X:
				w = tW;
			case Y:
				h = tH;
			default:
				w = tW;
				h = tH;
		}
	}

	/**
		Disposes this sprite.
	**/
	function dispose() {}
}
