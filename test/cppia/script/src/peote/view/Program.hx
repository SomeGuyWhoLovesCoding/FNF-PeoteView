package peote.view;

import peote.view.*;
import peote.view.intern.BufferInterface;

extern class Program {
	public var displays(default, null):Array<Display>;
	public var buffer(default, null):BufferInterface;

	public var isVisible:Bool;

	public var colorEnabled:Bool;

	public var blendEnabled:Bool;
	public var blendSeparate:Bool;
	public var blendFuncSeparate:Bool;

	var blendValues:Int = 0;

	public var autoUpdateTextures:Bool;

	var glShaderConfig:Dynamic;

	public function new(buffer:BufferInterface);
}