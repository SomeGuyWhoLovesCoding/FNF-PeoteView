package peote.view;

import peote.view.PeoteGL.GLUniformLocation;

/**
	Set up a custom "uniform vec2" that can be accessed within glsl shadercode.
**/
class UniformVec2
{
	/**The value that can be changed at runtime**/
	public var value:Array<Float>;

	/**The identifier to be used within shadercode**/
	public var name(default, null):String;
	
	/**
		Creates a new `UniformVec2` instance.
		@param name identifier to be used within shadercode
		@param value start value (must be two)
	**/
	public inline function new(name:String, value:Array<Float>) 
	{
		this.name = name;
		this.value = value;
	}
	
}
