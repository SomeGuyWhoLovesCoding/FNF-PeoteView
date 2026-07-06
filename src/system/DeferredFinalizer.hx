package system;

// DeferredFinalizer.hx
// Drop this into your Haxe project and call DeferredFinalizer.drain() once per frame.
// Requires the gc.deferred.cpp build with -DHXCPP_DEFER_HAXE_FINALIZERS.

#if (cpp && EXPERIMENTAL_DRAIN_FINALIZERS)
@:headerInclude("hxcpp.h")
@:native("__hxcpp_run_deferred_finalizers")
extern function __hxcpp_run_deferred_finalizers(maxCount:Int):Int;

@:native("__hxcpp_deferred_finalizer_count")
extern function __hxcpp_deferred_finalizer_count():Int;
#end

class DeferredFinalizer
{
   #if (cpp && EXPERIMENTAL_DRAIN_FINALIZERS)
   /**
    * Call this once per frame from your game loop (e.g., in an ENTER_FRAME handler
    * or your main update function).  It processes up to `maxCount` deferred finalizers
    * that were queued during the last GC pause.
    *
    * Recommended budget: 64–256 per frame at 60fps.  This keeps per-frame cost
    * under 2ms while draining a 4700-finalizer spike in ~18–73 frames (0.3–1.2 sec).
    *
    * Returns the number of finalizers actually called.
    */
   public static function drain(maxCount:Int = 128):Int
   {
      return untyped __hxcpp_run_deferred_finalizers(maxCount);
   }

   /** How many deferred finalizers are waiting.  For diagnostics / budgeting. */
   public static function pending():Int
   {
      return untyped __hxcpp_deferred_finalizer_count();
   }
   #else
   public static function drain(maxCount:Int = 128):Int { return 0; }
   public static function pending():Int { return 0; }
   #end
}
