package system;

// plese dont use this lol
#if cpp
import cpp.NativeGc;
@:noDebug
@:final
@:publicFields
class CustomFinalizer {
    public function new() {
        // Register this instance for finalization, do not pin it in memory
        NativeGc.addFinalizable(this, false);
    }

    public function finalize(): Void {
        // Clean up native resources here
        trace("Finalizing ResourceHandler and freeing native memory.");
    }
}
#else
@:publicFields
class CustomFinalizer {
    function new() {}
}
#end