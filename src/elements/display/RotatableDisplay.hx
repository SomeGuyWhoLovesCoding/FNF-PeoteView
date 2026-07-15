package elements.display;

// since peote-view 1.0.8
// this was from import.hx until I cleaned the said class up
import peote.view.Uniform.UniformFloat;
import peote.view.Uniform.UniformVec2;

/**
	RotatableDisplay is a custom class that extends Display with added rotation support at the vertex level.
	@since Development
**/
@:publicFields
class RotatableDisplay extends Display
{
	private var rotation(default, set):Float = 0.0;

	var uAngle:UniformFloat;
	var uCos:UniformFloat;
	var uSin:UniformFloat;
	var uCenter:UniformVec2;

	public function new(x:Int, y:Int, width:Int, height:Int, color = 0x00000000) {
		super(x, y, width, height, color);
		uAngle   = new UniformFloat(0.0);
		uSin     = new UniformFloat(0.0);
		uCos     = new UniformFloat(1.0); // this has to be 1.0. cosine is just sine but inverted.
		uCenter = new UniformVec2({x: x + width * 0.5, y: y + height * 0.5});
	}

	private function set_rotation(deg:Float):Float {
		uAngle.value = deg * 0.01745329251994329576923690768489;
		uCos.value = Math.cos(uAngle.value);
		uSin.value = Math.sin(uAngle.value);
		return rotation = deg;
	}
}