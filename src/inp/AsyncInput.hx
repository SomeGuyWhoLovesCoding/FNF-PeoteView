package inp;

import lime.app.Event;
#if (windows || linux || hl) // not supported on android
import inp.AsyncKB;
import haxe.Timer;
import sys.thread.Mutex;
import sys.thread.Thread;
import lime.ui.KeyCode;

class ThreadSafeHistory {
	private var events:Array<{scanCode:Int, state:Int, timestamp:Float}> = [];
	private var mutex:Mutex;

	public function new() {
		mutex = new Mutex();
	}
	
	public function push(event:{scanCode:Int, state:Int, timestamp:Float}):Void {
		mutex.acquire();
		events.push(event);
		mutex.release();
	}
	
	// Fills a pre-allocated array with history data
	// Returns the number of events copied
	public function fillArrayWithHistory(target:Array<{scanCode:Int, state:Int, timestamp:Float}>, maxCount:Int = -1):Int {
		mutex.acquire();
		var copyCount = maxCount < 0 ? events.length : Std.int(Math.min(maxCount, events.length));
		
		// Ensure target has enough capacity
		if (target.length < copyCount) {
			// Resize target array to fit
			target.resize(copyCount);
		}
		
		// Copy from the end (most recent events)
		for (i in 0...copyCount) {
			var srcIndex = events.length - copyCount + i;
			target[i] = events[srcIndex];
		}
		
		mutex.release();
		return copyCount;
	}
	
	// Alternative: fill array with ALL history starting from oldest
	public function fillArrayWithAllHistory(target:Array<{scanCode:Int, state:Int, timestamp:Float}>):Int {
		mutex.acquire();
		var totalEvents = events.length;
		
		// Resize target if needed
		if (target.length < totalEvents) {
			target.resize(totalEvents);
		}
		
		// Copy all events
		for (i in 0...totalEvents) {
			target[i] = events[i];
		}
		
		mutex.release();
		return totalEvents;
	}
	
	public function clear():Void {
		mutex.acquire();
		events = [];
		mutex.release();
	}
	
	public function size():Int {
		mutex.acquire();
		var len = events.length;
		mutex.release();
		return len;
	}
	
	public function exists(predicate:{scanCode:Int, state:Int, timestamp:Float} -> Bool):Bool {
		mutex.acquire();
		var found = false;
		for (event in events) {
			if (predicate(event)) {
				found = true;
				break;
			}
		}
		mutex.release();
		return found;
	}
}

@:publicFields
class AsyncInput {
	static var inputThread:Thread;
	static var history = new ThreadSafeHistory();
	static var running = true;

	static var inputPress:Event<KeyCode->Float->Void>;
	static var inputRelease:Event<KeyCode->Float->Void>;
	
	static function main() {
		Sys.println("=== AsyncKB Test ===");
		Sys.println("Press keys to record them. Press ESC (27) to quit.");

		inputPress = new Event<KeyCode->Float->Void>();
		inputRelease = new Event<KeyCode->Float->Void>();
		
		AsyncKB.start();
		
		var startTime = Timer.stamp();
		
		// Input thread - reads events from C++ and stores in history
		/*inputThread = Thread.create(() -> {
			while (running) {
				if (AsyncKB.hasEvent()) {
					var scanCode = AsyncKB.getScanCode();
					var keyCode:KeyCode = KeyCodeConverter.fromNativeScanCode(scanCode);
					var state = AsyncKB.getState();
					var timestamp = AsyncKB.getTimestamp();
					
					history.push({
						scanCode: scanCode,
						state: state,
						timestamp: timestamp
					});
					
					var action = state == 1 ? "PRESSED" : "RELEASED";
					Sys.println('[${timestamp}] $action: scanCode(native)=$scanCode,keyCode=$keyCode');
				}
				
				Sys.sleep(0.002);
			}
		});*/
		
		// Pre-allocate array for processing (reused to avoid allocations)
		var processBuffer:Array<{scanCode:Int, state:Int, timestamp:Float}> = [];
		
		// Main thread - displays periodic updates
		/*while (running) {
			// Fill buffer with last 100 events (or fewer)
			var eventCount = history.fillArrayWithHistory(processBuffer, 100);
			
			// Check for ESC key in the buffer
			var escPressed = false;
			for (i in 0...eventCount) {
				if (processBuffer[i].state == 1 && processBuffer[i].scanCode == 27) {
					escPressed = true;
					break;
				}
			}
			
			if (escPressed) {
				running = false;
				break;
			}
			
			// Print status every second
			var elapsed = Timer.stamp() - startTime;
			if (Std.int(elapsed) > Std.int(elapsed - 0.01)) {
				Sys.print('\rEvents recorded: ${history.size()} (Press ESC to quit)');
			}
			
			Sys.sleep(0.1);
		}
		
		AsyncKB.stop();*/
		
		/*Sys.println('\n\n=== History Summary ===');
		
		// Get all history without allocation (reuse buffer)
		var totalEvents = history.fillArrayWithAllHistory(processBuffer);
		Sys.println('Total events: ' + totalEvents);
		
		var start = Std.int(Math.max(0, totalEvents - 10));
		for (i in start...totalEvents) {
			var event = processBuffer[i];
			Sys.println('  ${i+1}. [${event.timestamp}] ${event.state == 1 ? "PRESS" : "RELEASE"} ${event.scanCode}');
		}*/
	}

	static function poll() {
		try {
			while (AsyncKB.hasEvent()) {
				var scanCode = AsyncKB.getScanCode();
				var keyCode:KeyCode = KeyCodeConverter.fromNativeScanCode(scanCode);
				var state = AsyncKB.getState();
				var timestamp = AsyncKB.getTimestamp();
				
				if (state == 1) inputPress.dispatch(scanCode, timestamp);
				else inputRelease.dispatch(scanCode, timestamp);
			}
		} catch (e) {}
	}
}
#else
@:publicFields
class AsyncInput {
	static var inputThread:Dynamic;
	static var history:Array<Dynamic> = [];
	static var running = true;
	static function main() {
		Sys.println("async input is not supported on mobile. you already have a touchscreen to control and it's pretty fast anyway");
	}
}
#end