package inp;

import lime.app.Event;
#if (FV_LIME_FORK && !android) // not supported on android
import haxe.Timer;
import sys.thread.Mutex;
import sys.thread.Thread;
import lime.ui.KeyCode;

/**
	Second input system that runs asynchronously and was made specifically for gameplay.
	@since 0.94
**/
#if (lime_cffi)
import lime._internal.backend.native.NativeCFFI;
@:access(lime._internal.backend.native.NativeCFFI)
#end
@:publicFields
@:noDebug
class AsyncInput {
	static var initialized(default, null):Bool = false;
	static var initMutex(default, null):Mutex = new Mutex();
	static var inputPress:Event<KeyCode->Float->Void> = new Event<KeyCode->Float->Void>();
	static var inputRelease:Event<KeyCode->Float->Void> = new Event<KeyCode->Float->Void>();
	
	static function init() {
		initMutex.acquire();
		if (!initialized) {
			initialized = true;
			haxe.Timer.delay(enableAsyncInput, 1);
		}
		initMutex.release();
	}
	
	static function shutdown() {
		initMutex.acquire();
		if (initialized) {
			initialized = false;
			haxe.Timer.delay(disableAsyncInput, 1);
		}
		initMutex.release();
	}

	#if lime_cffi
	inline static function asyncKeyEvent_init() {
		var backend = @:privateAccess lime.app.Application.current.__backend;
		var evt = @:privateAccess backend.asyncKeyEventInfo;
		if (evt.state == 1) AsyncInput.inputPress.dispatch(evt.keyCode, evt.timestamp);
		else AsyncInput.inputRelease.dispatch(evt.keyCode, evt.timestamp);
	}

	inline static function enableAsyncInput() {
		var backend = @:privateAccess lime.app.Application.current.__backend;
		@:privateAccess NativeCFFI.lime_asynckey_event_manager_register(asyncKeyEvent_init, backend.asyncKeyEventInfo);
	}

	inline static function disableAsyncInput() {
		var backend = @:privateAccess lime.app.Application.current.__backend;
		@:privateAccess NativeCFFI.lime_asynckey_event_manager_register(backend.handleAsyncKeyEvent, backend.asyncKeyEventInfo);
	}
	#end
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