package;

import peote.view.Tools;
import peote.view.Program;

/**
 * ...
 * @author Christopher Speciale
 */
class TestScript
{
	static var buffer:Dynamic;
	static var program:Program;

	static public function main():Void
	{
		Tools.initBuffer(buffer);
		Tools.initProgram(program, buffer);

		Tools.addBufferTo(buffer, display);
	}
}