package inp;

#if (cpp && !android)
import cpp.ConstCharStar;

@:buildXml('<include name="../../../asyncKbBuild.xml" />')
@:unreflective @:keep
@:include("./include/AsyncKB.h")
extern class AsyncKB {
	@:native("start")
	static function _start():Void;
	
	@:native("stop")
	static function _stop():Void;
	
	@:native("hasEvent")
	static function _hasEvent():Bool;
	
	@:native("getScanCode")
	static function getScanCode():Int;
	
	@:native("getState")
	static function getState():Int;
	
	@:native("getTimestamp")
	static function _getTimestamp():Float;
	
	@:native("getGlobalTimestampComparison")
	static function getGlobalTimestampComparison():Float;
	
	public static inline function start():Void {
		_start();
	}
	
	public static inline function stop():Void {
		_stop();
	}
	
	public static inline function hasEvent():Bool {
		return _hasEvent();
	}
	
	public static inline function getTimestamp():Float {
		return _getTimestamp();
	}
}
#elseif (hl && !android)
class AsyncKB {
	@:hlNative("async_kb", "start")
	public static function start():Void {}
	
	@:hlNative("async_kb", "stop")
	public static function stop():Void {}
	
	@:hlNative("async_kb", "hasEvent")
	public static function hasEvent():Bool { return false; }
	
	@:hlNative("async_kb", "getScanCode")
	public static function getScanCode():Int { return 0; }
	
	@:hlNative("async_kb", "getState")
	public static function getState():Int { return 0; }
	
	@:hlNative("async_kb", "getTimestamp")
	public static function getTimestamp():Float { return 0.0; }
	
	@:hlNative("async_kb", "getGlobalTimestampComparison")
	public static function getGlobalTimestampComparison():Float { return 0.0; }
}
#else // unsupported on android
class AsyncKB {
	public static function start():Void {}
	
	public static function stop():Void {}
	
	public static function hasEvent():Bool { return false; }
	
	public static function getScanCode():Int { return 0; }
	
	public static function getState():Int { return 0; }
	
	public static function getTimestamp():Float { return 0.0; }
	
	public static function getGlobalTimestampComparison():Float { return 0.0; }
}
#end