package underlying.overlay;

/** Textured quad for the generated pixel-art TAB hint. */
@:publicFields
class ControlsTabHintSprite implements Element {
	@posX var x:Float = 0.0;
	@posY var y:Float = 0.0;
	@sizeX var w:Float = 15.0;
	@sizeY var h:Float = 7.0;
	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth:Int = 15;
	@texH var clipHeight:Int = 7;
	@texPosX var clipPosX:Int = 0;
	@texPosY var clipPosY:Int = 0;
	@custom @varying @texSizeX var clipSizeX:Int = 15;
	@custom @varying @texSizeY var clipSizeY:Int = 7;
	@color var c:Color = 0xFFFFFFFF;
	var OPTIONS = {blend: true};

	function new() {}
}
