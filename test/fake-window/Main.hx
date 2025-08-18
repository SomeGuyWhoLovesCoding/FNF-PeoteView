
import peote.view.*;
import haxe.CallStack;
import lime.app.Application;
import lime.ui.Window;
import lime.ui.KeyCode;
import structures.FakeWindow;

@:publicFields
class Main extends Application
{
	static var current:Main;

	var peoteView:PeoteView;
	override function onPreloadComplete() {	
		current = this;

		peoteView = new PeoteView(window);
		
		var fakeWindow = new FakeWindow(peoteView);
		fakeWindow.reload(window.width, window.height);
	}
}