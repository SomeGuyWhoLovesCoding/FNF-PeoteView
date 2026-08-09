package elements.display;

import peote.view.Uniform.UniformFloat;
import peote.view.Uniform.UniformVec2;

@:publicFields
class RotatableDisplay extends Display {
	private var rotation(default, set):Float = 0.0;

	var uAngle:UniformFloat;
	var uSin:UniformVec2;
	var uCenter:UniformVec2;

	static var sinVec:Vec2 = {x: 1.0, y: 0.0};

	public function new(x:Int, y:Int, width:Int, height:Int, color = 0x00000000) {
		super(x, y, width, height, color);
		uAngle = new UniformFloat(0.0);

		sinVec.x = 1.0;
		sinVec.y = 0.0;
		uSin = new UniformVec2(sinVec);
		uCenter = new UniformVec2({x: x + width * 0.5, y: y + height * 0.5});
	}

	private function set_rotation(deg:Float):Float {
		uAngle.value = deg * 0.01745329251994329576923690768489;

		sinVec.x = Math.cos(uAngle.value);
		sinVec.y = Math.sin(uAngle.value);
		uSin.value = sinVec;

		return rotation = deg;
	}
}
