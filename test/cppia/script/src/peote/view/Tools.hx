package peote.view;

import peote.view.*;
import peote.view.intern.BufferInterface;

extern class Tools {
	static function initBuffer(buffer:BufferInterface):Void;

	static function initProgram(program:Program, buffer:BufferInterface):Void;

	static function addProgramTo(element:Element.ElementInterface, display:Display):Void;

	static function initElement(element:Element.ElementInterface, x:Float = 0.0, y:Float = 0.0, w:Float = 200.0, h:Float = 200.0):Void;

	static function addElementTo(element:Element.ElementInterface, buffer:BufferInterface):Void;

	static function setPositionOfDisplay(display:Display, x:Float = 0.0, y:Float = 0.0):Void;

	static function setSizeOfDisplay(display:Display, w:Int = 100, h:Int = 100):Void;
}