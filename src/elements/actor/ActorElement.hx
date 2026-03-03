package elements.actor;

/**
	Basic sparrow actor element with animate atlas matrix support (scaling + matrix).
	@since Development
**/
@:publicFields
class ActorElement implements Element {
	@texX var clipX:Int = 0;
	@texY var clipY:Int = 0;
	@texW var clipWidth(default, set):Int = 1;
	@texH var clipHeight(default, set):Int = 1;

	inline function set_clipWidth(value:Int) {
		clipWidth = value;
		clipSizeX = value;
		return value;
	}

	inline function set_clipHeight(value:Int) {
		clipHeight = value;
		clipSizeY = value;
		return value;
	}

	@texSizeX private var clipSizeX:Int = 1;
	@texSizeY private var clipSizeY:Int = 1;

	@varying @custom @formula("mixHelperF(_flipX, (1.0 - _flipX), _mirror)") var _flipX:Float = 0.0;
	@varying @custom var _flipY:Float = 0.0;
	@varying @custom var _mirror:Float = 0.0;
	@varying @custom var _rotated:Float = 0.0;
	
	@varying @custom var _ma:Float = 1.0;
	@varying @custom var _mb:Float = 0.0;
	@varying @custom var _mc:Float = 0.0;
	@varying @custom var _md:Float = 1.0;

	@varying @custom var _originU:Float = 0.0;
	@varying @custom var _originV:Float = 0.0;

	var flipX(default, set):Bool;

	inline function set_flipX(value:Bool):Bool {
		_flipX = value ? 1.0 : 0.0;
		return flipX = value;
	}

	var flipY(default, set):Bool;

	inline function set_flipY(value:Bool):Bool {
		_flipY = value ? 1.0 : 0.0;
		return flipY = value;
	}

	var mirror(default, set):Bool;

	inline function set_mirror(value:Bool):Bool {
		_mirror = value ? 1.0 : 0.0;
		return mirror = value;
	}

	var rotated(default, set):Bool;

	inline function set_rotated(value:Bool):Bool {
		_rotated = value ? 1.0 : 0.0;
		return rotated = value;
	}

	@posX @formula("uDisplayRotateX(vec2(aPos.x + off_x + px + adjust_x + (w * (_flipX * sign(_mirror - 0.5))), aPos.y + off_y + py + adjust_y + (h * _flipY)))") var x:Float;
	@posY @formula("uDisplayRotateY(vec2(aPos.x + off_x + px + adjust_x + (w * (_flipX * sign(_mirror - 0.5))), aPos.y + off_y + py + adjust_y + (h * _flipY)))") var y:Float;

	// Replace existing sizeX/sizeY formulas:
	@sizeX @formula("(w * scale) * (1.0 + (_flipX * 2.0))") var w:Float;
	@sizeY @formula("(h * scale) * (1.0 + (_flipY * 2.0))") var h:Float;

	@pivotX @formula("mixHelperF(-w, w, clamp(w, 0.0, 1.0)) * 0.5") var px:Float;
	@pivotY @formula("mixHelperF(-h, h, clamp(h, 0.0, 1.0)) * 0.5") var py:Float;

	@rotation @formula("uDisplayRotation(r)") var r:Float;

	@varying @custom @formula("off_x * scale") var off_x:Float;
	@varying @custom @formula("off_y * scale") var off_y:Float;
	@varying @custom var adjust_x:Float;
	@varying @custom var adjust_y:Float;
	@varying @custom var scale:Float = 1.0;

	@color var color:Color = 0xFFFFFFFF;

	function new(x:Float = 0.0, y:Float = 0.0) {
		this.x = x;
		this.y = y;
	}
}