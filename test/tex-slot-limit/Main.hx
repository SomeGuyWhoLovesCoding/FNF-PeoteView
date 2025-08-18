package;

import peote.view.*;
import haxe.CallStack;
import lime.app.Application;
import lime.ui.Window;
import lime.ui.KeyCode;
import system.*;

class Elem implements Element
{
	// Position in pixel (relative to upper left corner of Display)
	@posX public var x:Int = 0; // signed 2 bytes integer
	@posY public var y:Int = 0; // signed 2 bytes integer
	
	// Size in pixel
	@sizeX public var w:Int = 100; // signed 2 bytes integer
	@sizeY public var h:Int = 100; // signed 2 bytes integer
	
	// Rotation around pivot point
	@rotation public var r:Float;
	
	// pivot x (rotation offset)
	@pivotX public var px:Int = 0; // signed 2 bytes integer

	// pivot y (rotation offset)
	@pivotY public var py:Int = 0; // signed 2 bytes integer
		
	// Color (RGBA)
	@color public var c:Color = 0xffffffff;

    @texSlot public var slot:Int = 0;
	
	
	public function new() {}
}

@:publicFields
class Main extends Application
{

	override function onPreloadComplete() {	
		var peoteView = new PeoteView(window);

        var assets = [
            "assets/fpsCounterConcept.png",
            "assets/peote_font.png",
            "assets/peote_tiles.png",
            "assets/peote_tiles_bunnys.png",
            "assets/suzanneBW.png",
            "assets/suzanneGrey.png",
            "assets/suzanneGreyAlpha.png",
            "assets/suzanneRGBA.png",
            "assets/tail_old.png",
            "assets/test0.png",
            "assets/test1.png",
            "assets/test2.png",
            "assets/test3.png",
            "assets/wabbit_alpha.png",
            "assets/warning_screen.png",
            //"assets/characters/bf/sheet.png",
            //"assets/characters/dad/sheet.png",
            "assets/countdown/ready.png",
            "assets/countdown/set.png",
            "assets/countdown/go.png",
            "assets/countdown/sheet.png",
        ];

		TextureSystem.createMultiTexture("multiTexTest", assets, false, 5, 4);
		
		var display = new Display(0, 0, window.width, window.height);
		peoteView.addDisplay(display);

        var buffer:Buffer<Elem> = new Buffer<Elem>(64, 64, false);
        var program:Program = new Program(buffer);
        display.addProgram(program);

        TextureSystem.setTexture(program, 'multiTexTest', 'multiTexTest');

        for (i in 0...assets.length) {
            var elem = new Elem();
            elem.slot = i;
            elem.c.aF = 1 / assets.length;
            elem.x = 100 * (i % 12);
            elem.y = 100 * (Math.floor(i / 12));
            elem.w = 100;
            elem.h = 100;
            buffer.addElement(elem);
        }
	}
}