package elements;

/**
	RotatableDisplay is a custom class that extends Display with added rotation support at the vertex level.
**/
@:publicFields
class RotatableDisplay extends Display
{
	private var rotation(default, set):Float = 0.0;

	var uAngle_map:Map<CustomProgram, UniformFloat> = [];
	var uCos_map:Map<CustomProgram, UniformFloat> = [];
	var uSin_map:Map<CustomProgram, UniformFloat> = [];
	var uCenter_map:Map<CustomProgram, UniformVector> = [];

	var uAngle:UniformFloat;
	var uCos:UniformFloat;
	var uSin:UniformFloat;
	var uCenter:UniformVector;

	public function new(x:Int, y:Int, width:Int, height:Int, color = 0x00000000) {
		super(x, y, width, height, color);
	}

	private function set_rotation(deg:Float):Float {
		var uAngle_value = deg * (Math.PI / 180.0);
		for (uAngle in uAngle_map) uAngle.value = uAngle_value;
		var uCos_value = Math.cos(uAngle.value);
		for (uCos in uCos_map) uCos.value = uCos_value;
		var uSin_value = Math.sin(uAngle.value);
		for (uSin in uSin_map) uSin.value = Math.sin(uAngle.value);
		return rotation = deg;
	}
}