// EVERYTHING RELATED TO THE STORY MENU SHEET IN THE CLASS IS 100% HARDCODED.
// This is a cheap copy of UISprite with less things in mind because it's meant for the story menu.
// This was originally meant for the pause menu, but it was later used for the story menu.

package elements.sprites;

@:publicFields
class StoryModeSprite implements Element {
	// position in pixel (relative to upper left corner of Display)
	@posX var x:Float = 0.0;
	@posY var y:Float = 0.0;

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
	@texSizeX var clipSizeX:Int = 200;
	@texSizeY var clipSizeY:Int = 200;

	@color var c:Color = 0xFFFFFFFF;

	var type:StoryModeSpriteType = NONE;

	var isNone(get, never):Bool;

	inline function get_isNone() {
		return type == NONE;
	}

	var isPauseOption(get, never):Bool;

	inline function get_isPauseOption() {
		return type == PAUSE_OPTION;
	}

	var isDifficultyCornerText(get, never):Bool;

	inline function get_isDifficultyCornerText() {
		return type == DIFF_TEXT;
	}

	var isStoryMenuPiece(get, never):Bool;

	inline function get_isStoryMenuPiece() {
		return type == STORY_MENU_PIECE;
	}

	var curID(default, null):Int;

	var OPTIONS = { texRepeatX: false, texRepeatY: false, blend: true };

	private static var hardcoded_difficulty_corner_text_values(default, null):Array<Array<Int>> = [
		[0, 456, 85, 32],
		[85, 456, 122, 32],
		[207, 456, 82, 32],
		[289, 456, 125, 32],
		[414, 456, 113, 32],
		[0, 488, 215, 32],
		[215, 488, 80, 32],
		[295, 488, 80, 32]
	];

	private static var hardcoded_story_menu_piece_values(default, null):Array<Array<Int>> = [
		[0, 555, 300, 45],
		[360, 555, 165, 45]
	];

	static function init(program:Program, name:String, texture:Texture) {
		// creates a texture-layer named "name"
		program.setTexture(texture, name, true);
		program.blendEnabled = true;
		program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
		program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
	}

	function new() {}

	inline function changeID(id:Int) {
		var wValue = 1;
		var hValue = 1;
		var xValue = 0;
		var yValue = 0;

		if (isPauseOption) {
			wValue = 525;
			hValue = 114;
			yValue = hValue * id;
		}

		if (isDifficultyCornerText) {
			var option:Array<Int> = hardcoded_difficulty_corner_text_values[id];
			xValue = option[0];
			yValue = option[1];
			wValue = option[2];
			hValue = option[3];
		}

		if (isStoryMenuPiece) {
			var option:Array<Int> = hardcoded_story_menu_piece_values[id];
			xValue = option[0];
			yValue = option[1];
			wValue = option[2];
			hValue = option[3];
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

private enum abstract StoryModeSpriteType(Int) {
	var NONE;
	var PAUSE_OPTION;
	var DIFF_TEXT;
	var STORY_MENU_PIECE;
}