package miniaudio;

/**
	* The native Miniaudio extern.
	* C++ and HL.
	* @since Development
**/
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

	@:native("setPlaybackRate") static function setPlaybackRate(playbackRate:Float):Void;
	@:native("seekToPCMFrame") static function seekToPCMFrame(pos:Int64):Void;
	@:native("deactivate_decoder") static function deactivate_decoder(index:Int):Void;
	@:native("amplify_decoder") static function amplify_decoder(index:Int, volume:Float):Void;

	@:native("detectLatency") static function detectLatency():Int;

	@:native("getGlobalVolume") static function getGlobalVolume():Float;
	@:native("setGlobalVolume") static function setGlobalVolume(value:Float):Float;

	// AND NOW THE BACKGROUND AND SOUND STUFF

	@:native("loadBackgroundTrack") static function _loadBackgroundTrack(path:ConstCharStar):Int;
	inline static function loadBackgroundTrack(path:String):Int {
		return _loadBackgroundTrack(ConstCharStar.fromString(path));
	}
	@:native("playBackgroundTrack") static function playBackgroundTrack(index:Int):Void;
	@:native("stopBackgroundTrack") static function stopBackgroundTrack(index:Int):Void;
	@:native("setBackgroundTrackVolume") static function setBackgroundTrackVolume(index:Int, volume:Float):Void;
	@:native("setBackgroundTrackLooping") static function setBackgroundTrackLooping(index:Int, looping:Bool):Void;
	@:native("isBackgroundTrackPlaying") static function isBackgroundTrackPlaying(index:Int):Bool;

	@:native("loadSoundEffect") static function _loadSoundEffect(path:ConstCharStar):Int;
	inline static function loadSoundEffect(path:String):Int {
		return _loadSoundEffect(ConstCharStar.fromString(path));
	}
	@:native("playSoundEffect") static function playSoundEffect(index:Int, volume:Float):Void;
	@:native("stopSoundEffect") static function stopSoundEffect(index:Int):Void;

	@:native("getMixerMasterVolume") static function getMixerMasterVolume():Float;
	@:native("setMixerMasterVolume") static function setMixerMasterVolume(volume:Float):Float;
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

	@:hlNative("ma_thing", "setPlaybackRate") public static function setPlaybackRate(playbackRate:Float):Void {}
	@:hlNative("ma_thing", "seek_to_pcm_frame") public static function seekToPCMFrame(pos:hl.I64):Void {}
	@:hlNative("ma_thing", "deactivate_decoder") public static function deactivate_decoder(index:Int):Void {}
	@:hlNative("ma_thing", "amplify_decoder") public static function amplify_decoder(index:Int, volume:Float):Void {}
	@:hlNative("ma_thing", "detectLatency") public static function detectLatency():Int {
		return 0;
	}

	@:hlNative("ma_thing", "getGlobalVolume") public static function getGlobalVolume():Float {
		return 0;
	}
	@:hlNative("ma_thing", "setGlobalVolume") public static function setGlobalVolume(value:Float):Float {
		return 0;
	}

	// AND NOW THE BACKGROUND AND SOUND STUFF

	@:hlNative("ma_thing", "loadBackgroundTrack") public static function loadBackgroundTrack(path:String):Int {
		return 0;
	}

	@:hlNative("ma_thing", "playBackgroundTrack") public static function playBackgroundTrack(index:Int):Void {}
	@:hlNative("ma_thing", "stopBackgroundTrack") public static function stopBackgroundTrack(index:Int):Void {}
	@:hlNative("ma_thing", "setBackgroundTrackVolume") public static function setBackgroundTrackVolume(index:Int, volume:Float):Void {}
	@:hlNative("ma_thing", "setBackgroundTrackLooping") public static function setBackgroundTrackLooping(index:Int, looping:Bool):Void {}
	@:hlNative("ma_thing", "isBackgroundTrackPlaying") public static function isBackgroundTrackPlaying(index:Int):Bool {
		return false;
	}

	@:hlNative("ma_thing", "loadSoundEffect") public static function loadSoundEffect(path:String):Int {
		return 0;
	}

	@:hlNative("ma_thing", "playSoundEffect") public static function playSoundEffect(index:Int, volume:Float):Void {}
	@:hlNative("ma_thing", "stopSoundEffect") public static function stopSoundEffect(index:Int):Void {}

	@:hlNative("ma_thing", "getMixerMasterVolume") public static function getMixerMasterVolume():Float {
		return 0.0;
	}
	@:hlNative("ma_thing", "setMixerMasterVolume") public static function setMixerMasterVolume(volume:Float):Float {
		return 0.0;
	}
}
#else
class MiniAudio {
	// THE MAIN STUFF

	public static function destroy():Void {}
	public static function start():Void {}
	public static function stop():Void {}

	public static function stopped():Bool {
		return false;
	}

	public static function loadFiles(arr:Array<String>):Void {}

	public static function getPlaybackPosition():Float {
		return 0;
	}
	public static function getDuration():Float {
		return 0;
	}
	public static function getMixerState():Int {
		return 0;
	}

	public static function setPlaybackRate(playbackRate:Float):Void {}
	public static function seekToPCMFrame(pos:hl.I64):Void {}
	public static function deactivate_decoder(index:Int):Void {}
	public static function amplify_decoder(index:Int, volume:Float):Void {}
	public static function detectLatency():Int {
		return 0;
	}

	public static function getGlobalVolume():Float {
		return 0;
	}
	public static function setGlobalVolume(value:Float):Float {
		return 0;
	}

	// AND NOW THE BACKGROUND AND SOUND STUFF

	public static function loadBackgroundTrack(path:String):Int {
		return 0;
	}

	public static function playBackgroundTrack(index:Int):Void {}
	public static function stopBackgroundTrack(index:Int):Void {}
	public static function setBackgroundTrackVolume(index:Int, volume:Float):Void {}
	public static function setBackgroundTrackLooping(index:Int, looping:Bool):Void {}
	public static function isBackgroundTrackPlaying(index:Int):Bool {
		return false;
	}

	public static function loadSoundEffect(path:String):Int {
		return 0;
	}

	public static function playSoundEffect(index:Int, volume:Float):Void {}
	public static function stopSoundEffect(index:Int):Void {}

	public static function getMixerMasterVolume():Float {
		return 0.0;
	}
	public static function setMixerMasterVolume(volume:Float):Float {
		return 0.0;
	}
}
#end
