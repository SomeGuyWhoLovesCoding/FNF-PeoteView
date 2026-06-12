// EVERYTHING RELATED TO THE OPTIONS SCREEN SHEET IN THE CLASS IS 100% HARDCODED.

package elements.sprites;

/**
	* This is a cheap copy of UISprite with less things in mind because it's meant for the options screen.
	* @since Development
**/
@:publicFields
class OptionsSprite implements Element {
	// position in pixel (relative to upper left corner of Display)
	@posX @formula("uDisplayRotateX(aPos)")  var x:Float = 0.0;
	@posY @formula("uDisplayRotateY(aPos)") var y:Float = 0.0;

	// size in pixel
	@sizeX var w:Float = 0.0;
	@sizeY var h:Float = 0.0;

	// extra tex attributes for clipping
	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int = 200;
	@texH var clipHeight:Int = 200;

	// extra tex attributes to adjust texture within the clip
	@texPosX  var clipPosX:Int = 0;
	@texPosY  var clipPosY:Int = 0;
	@custom @varying @texSizeX var clipSizeX:Int = 200;
	@custom @varying @texSizeY var clipSizeY:Int = 200;

	@rotation @formula("uDisplayRotation(r)") var r:Float;

	@color var c:Color = 0xFFFFFFFF;

	var type:OptionsSpriteType = NONE;

	var isNone(get, never):Bool;

	inline function get_isNone() {
		return type == NONE;
	}

	var isCategoryText(get, never):Bool;

	inline function get_isCategoryText() {
		return type == CATEGORY_TEXT;
	}

	var isControlsSubcat(get, never):Bool;

	inline function get_isControlsSubcat() {
		return type == CONTROLS_SUBCAT;
	}

	var isControlsOption(get, never):Bool;

	inline function get_isControlsOption() {
		return type == CONTROLS_OPTION;
	}

	var isPreferenceOption(get, never):Bool;

	inline function get_isPreferenceOption() {
		return type == PREFERENCE_OPTION;
	}

	var curID(default, null):Int;

	var OPTIONS = { texRepeatX: false, texRepeatY: false, blend: true };

	static function init(program:CustomProgram, name:String, texture:Texture) {
		// creates a texture-layer named "name"
		program.setTexture(texture, name, true);

		// Sparrow uses identity matrix varyings — the UV distortion shader
		// is a no-op here; nothing extra is injected except upscale if it's enabled.
		if (Main.current.upscale) {
			program.injectIntoFragmentShader(Shaders.UPSCALE_FRAGMENT_SHADER);
			program.setColorFormula('
				iconPixel(${name}_ID, vTexCoord, vec2(clipSizeX, 0.0), vec2(clipSizeY, 0.0)) * c
			');
		}
	}

	function new() {}

	inline function changeID(id:Int) {
		var wValue = 1;
		var hValue = 1;
		var xValue = 0;
		var yValue = 0;

		if (isCategoryText) {
			wValue = 216;
			hValue = 36;
			yValue = hValue * id;
		}

		if (isControlsSubcat) {
			wValue = 745;
			hValue = 65;
			xValue = 284;
			yValue = hValue * id;
		}

		if (isControlsOption) {
			wValue = 574;
			hValue = 55;
			yValue = 135 + (hValue * id);
		}

		if (isPreferenceOption) {
			wValue = 574;
			hValue = 55;
			yValue = 135 + (hValue * id);
		}

		if ((w != wValue && clipWidth != wValue && clipSizeX != wValue) && (h != hValue && clipHeight != hValue && clipHeight != hValue)) {
			w = clipWidth = clipSizeX = wValue;
			h = clipHeight = clipSizeY = hValue;
		}

		clipX = xValue;
		clipY = yValue;

		curID = id;
	}
}

private enum abstract OptionsSpriteType(Int) {
	var NONE;
	var CATEGORY_TEXT;
	var CONTROLS_SUBCAT;
	var CONTROLS_OPTION;
	var PREFERENCE_OPTION;
	var GRAPHICS_OPTION;
}