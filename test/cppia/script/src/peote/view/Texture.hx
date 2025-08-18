package peote.view;

import peote.view.*;
import peote.view.intern.BufferInterface;

extern class Texture {
	public var width:Int;
	public var height:Int;
	public var slotsX:Int;
	public var slotsY:Int;
	public var slotsWidth:Int;
	public var slotsHeight:Int;
	public var tilesX:Int;
	public var tilesY:Int;

	public function new(slotWidth:Int, slotHeight:Int, ?slots:Null<Int>, ?textureConfig:Dynamic);
}