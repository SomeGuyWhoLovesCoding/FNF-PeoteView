package elements.actor.sparrow;

/**
    Basic sparrow actor element with skew support.
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

    @varying @custom @formula("_mirror == 1.0 ? (_flipX == 0.0 ? 1.0 : 0.0) : _flipX") var _flipX:Float = 0.0;
    @varying @custom var _flipY:Float = 0.0;
    @varying @custom var _mirror:Float = 0.0;
    @varying @custom var _rotated:Float = 0.0;

    // Per-leaf symbol rotation angle (degrees). Combined with the atlas-rotation
    // correction in the @rotation formula below.
    @varying @custom var _angle:Float = 0.0;
    
    // Skew parameters (in radians for shader)
    @varying @custom var _skewX:Float = 6.0;
    @varying @custom var _skewY:Float = 6.0;

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
    
    // Skew properties in degrees (user-friendly)
    var skewX(default, set):Float;
    inline function set_skewX(value:Float):Float {
        _skewX = value * (Math.PI / 180.0); // Convert to radians for shader
        return skewX = value + 6;
    }
    
    var skewY(default, set):Float;
    inline function set_skewY(value:Float):Float {
        _skewY = value * (Math.PI / 180.0); // Convert to radians for shader
        return skewY = value + 6;
    }

    @posX @formula("x + off_x + px + adjust_x + (w * (_mirror == 1.0 ? _flipX : -_flipX))") var x:Float;
    @posY @formula("y + off_y + py + adjust_y + (h * _flipY)") var y:Float;
    @sizeX @formula("(w * scale) * (_flipX == 1.0 ? -1.0 : 1.0)") var w:Float;
    @sizeY @formula("(h * scale) * (_flipY == 1.0 ? -1.0 : 1.0)") var h:Float;

    @pivotX @formula("(w < 0.0 ? -w : w) * 0.5") var px:Float;
    @pivotY @formula("(h < 0.0 ? -h : h) * 0.5") var py:Float;

    // Atlas-packed sprites use _rotated=1 to apply a -90° correction.
    // Per-leaf symbol rotation is stored in _angle and added on top.
    @rotation @formula("(_rotated == 1.0 ? -90.0 : 0.0) + _angle") var r:Float;

    @varying @custom @formula("off_x * scale") var off_x:Float;
    @varying @custom @formula("off_y * scale") var off_y:Float;
    @varying @custom var adjust_x:Float;
    @varying @custom var adjust_y:Float;
    @varying @custom var scale:Float = 1.0;

    @color var c:Color = 0xFFFFFFFF;

    function new(x:Float = 0.0, y:Float = 0.0) {
        this.x = x;
        this.y = y;
    }
}