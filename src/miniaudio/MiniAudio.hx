package miniaudio;

#if cpp
@:buildXml('<include name="../../../miniaudioBuild.xml" />')
@:unreflective @:keep
@:include("./include/ma_thing.h")
extern class MiniAudio {
	@:native("destroy") static function destroy():Void;
	@:native("start") static function start():Void;
	@:native("stop") static function stop():Void;
	@:native("stopped") static function stopped():Int;

	@:runtime inline static function loadFiles(arr:Array<String>):Void {
		var vec = StdVectorString.fromStringArray(arr);
		//Sys.println("Loading files: " + vec.data());
		_loadFiles(vec);
	}
	@:native("loadFiles") static function _loadFiles(argv:StdVectorString):Void;

	@:native("getPlaybackPosition") static function getPlaybackPosition():Float;
	@:native("getDuration") static function getDuration():Float;
	@:native("getMixerState") static function getMixerState():Int;

	@:native("setPlaybackRate") static function setPlaybackRate(playbackRate:cpp.Float32):Void;
	@:native("seekToPCMFrame") static function seekToPCMFrame(pos:cpp.Int64):Void;
	@:native("deactivate_decoder") static function deactivate_decoder(index:Int):Void;
	@:native("amplify_decoder") static function amplify_decoder(index:Int, volume:Float):Void;
}
#elseif hl
class MiniAudio {
	@:hlNative("ma_thing", "destroy") public static function destroy():Void {}
	@:hlNative("ma_thing", "start") public static function start():Void {}
	@:hlNative("ma_thing", "stop") public static function stop():Void {}

	@:hlNative("ma_thing", "stopped") public static function stopped():Int {
		return 0;
	}

	@:runtime inline public static function loadFiles(arr:Array<String>):Void {
		var nativeArray = new hl.NativeArray(arr.length);
		for (i in 0...arr.length) {
			nativeArray[i] = @:privateAccess arr[i].toUtf8();
		}
		_loadFiles(nativeArray);
	}
	@:hlNative("ma_thing", "loadFiles") public static function _loadFiles(args:hl.NativeArray<hl.Bytes>):Void {}

	@:hlNative("ma_thing", "get_playback_position") public static function getPlaybackPosition():Float {
		return 0;
	}
	@:hlNative("ma_thing", "get_duration") public static function getDuration():Float {
		return 0;
	}
	@:hlNative("ma_thing", "get_mixer_state") public static function getMixerState():Int {
		return 0;
	}

	@:hlNative("ma_thing", "setPlaybackRate") public static function setPlaybackRate(playbackRate:hl.F32):Void {}
	@:hlNative("ma_thing", "seek_to_pcm_frame") public static function seekToPCMFrame(pos:hl.I64):Void {}
	@:hlNative("ma_thing", "deactivate_decoder_hl") public static function deactivate_decoder(index:Int):Void {}
	@:hlNative("ma_thing", "amplify_decoder_hl") public static function amplify_decoder(index:Int, volume:Float):Void {}
}
#else
class MiniAudio {
	static function destroy():Void {}
	static function start():Void {}
	static function stop():Void {}

	static function stopped():Int {
		return 0;
	}

	static function loadFiles(arr:Array<String>):Void {}

	static function getPlaybackPosition():Float {
		return 0;
	}
	static function getDuration():Float {
		return 0;
	}
	static function getMixerState():Int {
		return 0;
	}

	static function setPlaybackRate(playbackRate:Float):Void {}
	static function seekToPCMFrame(pos:haxe.Int64):Void {}
	static function deactivate_decoder(index:Int):Void {}
	function amplify_decoder(index:Int, volume:Float):Void {}
}
#end