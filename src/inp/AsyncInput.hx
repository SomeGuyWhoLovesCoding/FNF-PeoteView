package inp;

import lime.app.Event;

/**
	Second input system that runs asynchronously and was made specifically for gameplay.
	@deprecated
	@since 0.94
**/
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