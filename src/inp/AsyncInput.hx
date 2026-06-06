package inp;

import lime.app.Event;
#if (windows || linux || hl) // not supported on android
import inp.AsyncKB;
import haxe.Timer;
import sys.thread.Mutex;
import sys.thread.Thread;
import lime.ui.KeyCode;
import lime.app.Application;

@:publicFields
@:final
class AsyncInput {
	static var initialized = false;
	static var initMutex = new Mutex();
	static var inputPress:Event<KeyCode->Float->Void>;
	static var inputRelease:Event<KeyCode->Float->Void>;

	static function addEvents() {
		var window = Application.current.window;
		window.onFocusIn.add(init);
		window.onFocusOut.add(shutdown);
	}

	static function removeEvents() {
		var window = Application.current.window;
		window.onFocusIn.remove(init);
		window.onFocusOut.remove(shutdown);
	}
	
	static function init() {
		initMutex.acquire();
		if (!initialized) {
			initialized = true;
			inputPress = new Event<KeyCode->Float->Void>();
			inputRelease = new Event<KeyCode->Float->Void>();
			
			// Start on next frame to avoid blocking the current thread
			haxe.Timer.delay(function() {
				try {
					AsyncKB.start();
				} catch (e:Dynamic) {
					// Silent fail - already started or can't start
				}
			}, 0);
		}
		initMutex.release();
	}
	
	static function shutdown() {
		initMutex.acquire();
		if (initialized) {
			// Stop on next frame to avoid blocking
			haxe.Timer.delay(function() {
				try {
					AsyncKB.stop();
				} catch (e:Dynamic) {
					// Silent fail - already stopped
				}
			}, 0);
			initialized = false;
		}
		initMutex.release();
	}
	
	static function poll() {
		if (!initialized) return;
		
		try {
			while (AsyncKB.hasEvent()) {
				var nativeCode = AsyncKB.getScanCode();
				var state = AsyncKB.getState();
				var timestamp = AsyncKB.getTimestamp();
				
				var keyCode:KeyCode = cast nativeCode;
				
				if (state == 1) {
					if (inputPress != null) inputPress.dispatch(keyCode, timestamp);
				} else {
					if (inputRelease != null) inputRelease.dispatch(keyCode, timestamp);
				}
			}
		} catch (e:Dynamic) {
			// Silent fail - allow polling to continue
		}
	}
}
#else
@:publicFields
class AsyncInput {
	static var initialized = false;
	static var initMutex = null;
	static var inputPress:Event<KeyCode->Float->Void>;
	static var inputRelease:Event<KeyCode->Float->Void>;
	static function init() {
		Sys.println("async input is not supported on mobile. you already have a touchscreen to control and it's pretty fast anyway");
	}
	static function shutdown() {}
	static function poll() {}
}
#end