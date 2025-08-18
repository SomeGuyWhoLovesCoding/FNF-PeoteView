package peote.view;

import peote.view.*;
import peote.view.intern.BufferInterface;

extern class Display {
	public var peoteView:PeoteView;

	public var x:Float;
	public var y:Float;
	public var width:Int;
	public var height:Int;

	public var color:Int;

	var red:Float;
	var green:Float;
	var blue:Float;
	var alpha:Float;

	public var backgroundAlpha:Bool;
	public var backgroundDepth:Bool;
	public var backgroundEnabled:Bool;
	
	public var xOffset:Float;
	public var yOffset(default, set):Float;

	public var xz:Float;
	public var yz:Float;
	
	public var zoom:Float;

	public var xZoom:Float;
	public var yZoom:Float;

	public var isVisible:Bool;

	public function new(x:Float, y:Float, w:Int, h:Int, c:Int = 0x00000000);

	public function addProgram(program:Program, ?atProgram:Program, addBefore:Bool = false):Void;
	public function removeProgram(program:Program):Void;

	public function setFramebuffer(texture:Texture, ?textureSlot:Null<Int>, ?peoteView:PeoteView):Void;
	public function removeFrameBuffer():Void;

	public var fbTexture:Texture;
	public var framebufferTextureSlot:Int;
	public var renderFramebufferEnabled:Bool;

	public var renderFramebufferSkipFrames:Int;
	var renderFramebufferFrame:Int;
}