package inp;

#if cpp
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
	static function _getScanCode():Float;
	
	@:native("getState")
	static function _getState():Float;
	
	@:native("getTimestamp")
	static function _getTimestamp():Float;
	
	public static inline function start():Void {
		_start();
	}
	
	public static inline function stop():Void {
		_stop();
	}
	
	public static inline function hasEvent():Bool {
		return _hasEvent();
	}
	
	public static inline function getScanCode():Int {
		return Std.int(_getScanCode());
	}
	
	public static inline function getState():Int {
		return Std.int(_getState());
	}
	
	public static inline function getTimestamp():Float {
		return _getTimestamp();
	}
}
#elseif hl
class AsyncKB {
	@:hlNative("async_kb", "start")
	public static function start():Void {}
	
	@:hlNative("async_kb", "stop")
	public static function stop():Void {}
	
	@:hlNative("async_kb", "hasEvent")
	public static function hasEvent():Bool { return false; }
	
	@:hlNative("async_kb", "getScanCode")
	public static function _getScanCode():Float { return 0.0; }
	
	@:hlNative("async_kb", "getState")
	public static function _getState():Float { return 0.0; }
	
	@:hlNative("async_kb", "getTimestamp")
	public static function getTimestamp():Float { return 0.0; }

	public static inline function getScanCode():Int {
		return Std.int(_getScanCode());
	}
	
	public static inline function getState():Int {
		return Std.int(_getState());
	}
}
#end