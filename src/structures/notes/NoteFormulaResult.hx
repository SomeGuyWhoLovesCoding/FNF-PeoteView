package structures.notes;

@:publicFields
#if cpp
@:unreflective
#end
abstract NoteFormulaResult(Vector<Float>) {
	var x(get, set):Float;
	var y(get, set):Float;
	var scale(get, set):Float;
	var sustainRot(get, set):Float;
	var scrollMultiplier(get, set):Float;

	inline function get_x()
		return this[0];

	inline function get_y()
		return this[1];

	inline function get_scale()
		return this[2];

	inline function get_sustainRot()
		return this[3];

	inline function get_scrollMultiplier()
		return this[4];

	inline function set_x(value:Float)
		return this[0] = value;

	inline function set_y(value:Float)
		return this[1] = value;

	inline function set_scale(value:Float)
		return this[2] = value;

	inline function set_sustainRot(value:Float)
		return this[3] = value;

	inline function set_scrollMultiplier(value:Float)
		return this[4] = value;

	function new() {
		this = new Vector<Float>(5, 0);
		scale = 1;
		scrollMultiplier = 1;
	}
}
