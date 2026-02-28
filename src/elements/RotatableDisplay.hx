package elements;

/**
	RotatableDisplay is a custom class that extends Display with added rotation support at the vertex level.
**/
@:publicFields
class RotatableDisplay extends Display
{
	private var rotation(default, set):Float = 0.0;

	var uAngle:UniformFloat;
	var uCos:UniformFloat;
	var uSin:UniformFloat;
	var uCenterX:UniformFloat;
	var uCenterY:UniformFloat;

	public function new(x:Int, y:Int, width:Int, height:Int, color = 0x00000000) {
		super(x, y, width, height, color);
		uAngle   = new UniformFloat("uDisplayAngle", 0.0);
		uSin     = new UniformFloat("uSin", 0.0);
		uCos     = new UniformFloat("uCos", 1.0); // this has to be 1.0. cosine is just sine but inverted.
		uCenterX = new UniformFloat("uDisplayCX", x + width  * 0.5);
		uCenterY = new UniformFloat("uDisplayCY", y + height * 0.5);
	}

	private function set_rotation(deg:Float):Float {
		uAngle.value = deg * (Math.PI / 180.0);
		uCos.value = Math.cos(uAngle.value);
		uSin.value = Math.sin(uAngle.value);
		return rotation = deg;
	}
}