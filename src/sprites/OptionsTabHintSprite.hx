// The options menu's "tab" hint sprite.
package sprites;

/**
 * A tiny textured sprite pinned 5 pixels in from the top-right corner of the
 * options screen, showing "tab" — the key that switches option categories.
 * It replaces the two old instruction texts (the bottom navigation hint and
 * the top-right description text).
 *
 * The texture is generated in code by OptionsMenu.createTabHint() (a 15x7
 * pixel-art key cap, like the noteskin grid textures), so there is no asset
 * file for it — the clip defaults below match that texture exactly.
 * @since Development
**/
@:publicFields
class OptionsTabHintSprite implements Element {
	// position in pixel (relative to upper left corner of Display)
	@posX @formula("uDisplayRotateX(aPos)") var x:Float = 0.0;
	@posY @formula("uDisplayRotateY(aPos)") var y:Float = 0.0;

	// size in pixel
	@sizeX var w:Float = 15.0;
	@sizeY var h:Float = 7.0;

	// extra tex attributes for clipping
	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int = 15;
	@texH var clipHeight:Int = 7;

	// extra tex attributes to adjust texture within the clip
	@texPosX var clipPosX:Int = 0;
	@texPosY var clipPosY:Int = 0;
	@custom @varying @texSizeX var clipSizeX:Int = 15;
	@custom @varying @texSizeY var clipSizeY:Int = 7;

	@rotation @formula("uDisplayRotation(r)") var r:Float;

	@color var c:Color = 0xFFFFFFFF;

	var OPTIONS = {texRepeatX: false, texRepeatY: false, blend: true};

	/**
		Wires a program up to the hint texture, in the same shape as the
		noteskin editor's GridBackgroundSprite.init / UISprite.init: the color
		formula multiplies the sampled texel by the element color, so the menu
		can fade/dim the hint through `c`.
	**/
	static function init(program:CustomProgram, name:String, texture:Texture) {
		// creates a texture-layer named "name"
		program.setTexture(texture, name, true);

		if (Main.current.upscale) {
			program.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER);
			program.setColorFormula('
				iconPixel(${name}_ID, vTexCoord, vec2(clipSizeX, 0.0), vec2(clipSizeY, 0.0)) * c
			');
		} else {
			program.injectIntoFragmentShader('
				vec4 getTexColor(int textureID, vec4 c)
				{
					return getTextureColor(textureID, vTexCoord) * c;
				}
			');
			program.setColorFormula('getTexColor(${name}_ID, c)');
		}
	}

	function new() {}
}
