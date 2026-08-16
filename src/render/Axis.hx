package render;

/**
 * The axis.
 * @since Development
**/
@:publicFields
enum abstract Axis(Int) {
	/**
		X.
	**/
	var X:Axis = 0;

	/**
		Y.
	**/
	var Y:Axis = 1;

	/**
		XY.
	**/
	var XY:Axis = -1;
}
