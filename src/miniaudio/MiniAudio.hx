package miniaudio;

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

	@:native("setPlaybackRate") static function setPlaybackRate(playbackRate:Float):Void;
	@:native("seekToPCMFrame") static function seekToPCMFrame(pos:cpp.Int64):Void;
	@:native("deactivate_decoder") static function deactivate_decoder(index:Int):Void;
	@:native("amplify_decoder") static function amplify_decoder(index:Int, volume:Float):Void;
}