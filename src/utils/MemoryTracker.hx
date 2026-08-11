package utils;

#if hl
import hl.Gc;
#elseif cpp
import cpp.vm.Gc;
#end

class MemoryTracker {
	static var activeLabel:String = null;
	static var startMemory:Float = 0;
	static var totalAllocations:FakeStringMap<Float> = new FakeStringMap<Float>();

	public static function start(label:String):Void {
		if (activeLabel != null) {
			throw "FINISH FIRST ONE FIRST!";
		}
		activeLabel = label;

		#if hl
		startMemory = Gc.stats().currentMemory;
		#elseif cpp
		startMemory = Gc.memInfo(Gc.MEM_INFO_CURRENT);
		#else
		startMemory = 0;
		#end
	}

	public static function end():Void {
		if (activeLabel == null) {
			throw "NO MEASUREMENT RUNNING!";
		}

		var label = activeLabel;
		activeLabel = null;

		#if hl
		var endMemory = Gc.stats().currentMemory;
		#elseif cpp
		var endMemory = Gc.memInfo(Gc.MEM_INFO_CURRENT);
		#else
		var endMemory = 0;
		#end

		var delta = endMemory - startMemory;

		var prevTotal = totalAllocations.exists(label) ? totalAllocations.get(label) : 0;
		totalAllocations.set(label, prevTotal + delta);

		// Sys.println('[MemoryTracker] "' + label + '" allocated: ' + delta + ' bytes (Total: ' + (prevTotal + delta) + ' bytes)');
	}
}
