package miniaudio;

#if cpp
import cpp.ConstCharStar;
@:buildXml('<include name="../../../miniaudioBuild.xml" />')
@:unreflective @:keep
@:include("./include/ma_thing.h")
extern class MiniAudio {
	// THE MAIN STUFF

	@:native("destroy") static function destroy():Void;
	@:native("start") static function start():Void;
	@:native("stop") static function stop():Void;
	@:native("stopped") static function stopped():Bool;

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

	@:native("detectLatency") static function detectLatency():Int;

	@:native("getGlobalVolume") static function getGlobalVolume():cpp.Float64;
	@:native("setGlobalVolume") static function setGlobalVolume(value:cpp.Float64):cpp.Float64;

	@:native("wearingHeadphones") static function wearingHeadphones():Bool;
	@:native("wearingPlugNPlay") static function wearingPlugNPlay():Bool;

	// AND NOW THE BACKGROUND AND SOUND STUFF

	@:native("loadBackgroundTrack") static function _loadBackgroundTrack(path:ConstCharStar):Int;
	inline static function loadBackgroundTrack(path:String):Int {
		return _loadBackgroundTrack(ConstCharStar.fromString(path));
	}
	@:native("playBackgroundTrack") static function playBackgroundTrack(index:Int):Void;
	@:native("stopBackgroundTrack") static function stopBackgroundTrack(index:Int):Void;
	@:native("setBackgroundTrackVolume") static function setBackgroundTrackVolume(index:Int, volume:cpp.Float32):Void;
	@:native("setBackgroundTrackLooping") static function setBackgroundTrackLooping(index:Int, looping:Bool):Void;
	@:native("isBackgroundTrackPlaying") static function isBackgroundTrackPlaying(index:Int):Void;

	@:native("loadSoundEffect") static function _loadSoundEffect(path:ConstCharStar):Int;
	inline static function loadSoundEffect(path:String):Int {
		return _loadSoundEffect(ConstCharStar.fromString(path));
	}
	@:native("playSoundEffect") static function playSoundEffect(index:Int, volume:cpp.Float32):Void;
}
#elseif hl
class MiniAudio {
	// THE MAIN STUFF

	@:hlNative("ma_thing", "destroy") public static function destroy():Void {}
	@:hlNative("ma_thing", "start") public static function start():Void {}
	@:hlNative("ma_thing", "stop") public static function stop():Void {}

	@:hlNative("ma_thing", "stopped") public static function stopped():Bool {
		return false;
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
	@:hlNative("ma_thing", "detectLatency") public static function detectLatency():Int {
		return 0;
	}

	@:hlNative("ma_thing", "getGlobalVolume") public static function getGlobalVolume():Float {
		return 0;
	}
	@:hlNative("ma_thing", "setGlobalVolume") public static function setGlobalVolume(value:Float):Float {
		return 0;
	}

	@:hlNative("ma_thing", "wearingHeadphones") public static function wearingHeadphones():Bool {
		return false;
	}
	@:hlNative("ma_thing", "wearingPlugNPlay") public static function wearingPlugNPlay():Bool {
		return false;
	}

	// AND NOW THE BACKGROUND AND SOUND STUFF

	@:hlNative("ma_thing", "loadBackgroundTrack") static function _loadBackgroundTrack(path:hl.Bytes):Int;
	inline static function loadBackgroundTrack(path:String):Int {
		return _loadBackgroundTrack(ConstCharStar.fromString(path.toUtf8()));
	}
	@:hlNative("ma_thing", "playBackgroundTrack") static function playBackgroundTrack(index:Int):Void;
	@:hlNative("ma_thing", "stopBackgroundTrack") static function stopBackgroundTrack(index:Int):Void;
	@:hlNative("ma_thing", "setBackgroundTrackVolume") static function setBackgroundTrackVolume(index:Int, volume:hl.F32):Void;
	@:hlNative("ma_thing", "setBackgroundTrackLooping") static function setBackgroundTrackLooping(index:Int, looping:Bool):Void;
	@:hlNative("ma_thing", "isBackgroundTrackPlaying") static function isBackgroundTrackPlaying(index:Int):Void;

	@:hlNative("ma_thing", "loadSoundEffect") static function _loadSoundEffect(path:hl.Bytes):Int;
	inline static function loadSoundEffect(path:String):Int {
		return _loadSoundEffect(ConstCharStar.fromString(path.toUtf8()));
	}
	@:hlNative("ma_thing", "playSoundEffect") static function playSoundEffect(index:Int, volume:hl.F32):Void;
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
