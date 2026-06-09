package inp;

import lime.app.Event;
#if !android // not supported on android
import haxe.Timer;
import sys.thread.Mutex;
import sys.thread.Thread;
import lime.ui.KeyCode;

/**
	Second input system that runs asynchronously and was made specifically for gameplay.
	@since 0.94
**/
@:publicFields
class AsyncInput {
	static var initialized(default, null):Bool = false;
	static var initMutex(default, null):Mutex = new Mutex();
	static var inputPress:Event<KeyCode->Float->Void> = new Event<KeyCode->Float->Void>();
	static var inputRelease:Event<KeyCode->Float->Void> = new Event<KeyCode->Float->Void>();
	
	static function init() {
		initMutex.acquire();
		if (!initialized) {
			initialized = true;
		}
		initMutex.release();
	}
	
	static function shutdown() {
		initMutex.acquire();
		if (initialized) {
			initialized = false;
		}
		initMutex.release();
	}
}
#else
@:publicFields
class AsyncInput {
	static var initialized(default, null):Bool = false;
	static var initMutex(default, null):Dynamic = null;
	static var inputPress:Event<Int->Float->Void> = new Event<Int->Float->Void>();
	static var inputRelease:Event<Int->Float->Void> = new Event<Int->Float->Void>();
	static function init() {
		Sys.println("async input is not supported on posix platforms. For mobile, you already have a touchscreen to control and it's pretty fast anyway");
	}
	static function shutdown() {}
	static function poll() {}
}
#end