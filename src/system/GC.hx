package system;

typedef GCBackend = #if cpp cpp.vm.Gc; #else Int #end

/**
	The GC class abstracting over its target-specific gc implementations.
	WARNING: USE THIS WISELY.
**/
@:publicFields
abstract GC(GCBackend) {
	/**
		Enables the GC.
		@param inEnable Whenever you want to turn it on or not.
	**/
	static function enable(inEnable:Bool) {
		#if cpp
		GCBackend.enable(inEnable);
		#end
	}

	/**
		Run the GC.
		@param times How many times the gc should be ran.
	**/
	static function run(times:Int = 1) {
		for (i in 0...times) {
			#if cpp
			GCBackend.run(false);
			GCBackend.run(true);
			#end
		}
	}
}