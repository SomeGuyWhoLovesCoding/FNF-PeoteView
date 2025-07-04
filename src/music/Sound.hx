package music;

import Miniaudio.MaEngine;
import Miniaudio.MaSound;
import Miniaudio.MaSoundGroup;
import Miniaudio.MaDataSource;
import Miniaudio.MaResult;

/**
	This class is used to handle sound playback, volume control, and playback tracking, all within *miniaudio*, the one c file externed to haxe.
	It provides methods to initialize the sound engine, load sounds from files, play, stop, and seek within sounds.
	It also includes a playback tracking system that can use different methods to track the playback position of sounds
	and provides a global volume control for all sounds.
	It is used in the PlayField class to handle sound playback and tracking.
	@since Development
**/
@:publicFields
class Sound {
	private var sound:MaSound;
	static var engine:MaEngine;

	// START OF PLAYBACK TRACKING SYSTEM //

	var playbackTrackingMethod:PlaybackTrackingMethod = HYBRID;

	private var _programPos:cpp.Float64;
	private var _driverPos:cpp.Float32;
	private var _length:cpp.Float32;
	private var _time:cpp.Float64;
	private var _sampleRate:cpp.UInt32;
	private var _dataSource:cpp.Star<MaDataSource>;
	private var _playhead(default, null):Playhead = new Playhead();

	static var globalVolume(get, set):Float;

	inline static function get_globalVolume() {
		return Miniaudio.ma_engine_get_volume(engine);
	}

	inline static function set_globalVolume(value:Float) {
		value = Math.max(Math.min(value, 1.0), 0.0);
		var result = Miniaudio.ma_engine_set_volume(engine, value);
		if (result != MaResult.MA_SUCCESS) {
			Sys.println("[Sound system] Failed to set engine volume");
		}
		return value;
	}

	var time(get, set):Float;

	inline function get_time() {
		return _time;
	}

	inline function set_time(value:Float) {
		return setTime(value * 0.001);
	}

	/// END OF PLAYBACK TRACKING SYSTEM ///

	var sampleRate(get, never):Int;

	inline function get_sampleRate() {
		return _sampleRate;
	}

	var length(get, never):Float;

	inline function get_length() {
		return _length;
	}

	var volume(get, set):Float;

	inline function get_volume() {
		return Miniaudio.ma_sound_get_volume(sound);
	}

	inline function set_volume(value:Float) {
		Miniaudio.ma_sound_set_volume(sound, value);
		return value;
	}

	var playing(get, never):Bool;

	inline function get_playing() {
		return Miniaudio.ma_sound_is_playing(sound) != 0;
	}

	var finished(get, never):Bool;

	inline function get_finished() {
		return Miniaudio.ma_sound_at_end(sound) != 0;
	}

	static function init() {
		var result = Miniaudio.ma_engine_init(null, engine);

		if (result != MaResult.MA_SUCCESS) {
			Sys.println("[Sound system] Failed to initialize engine");
			return;
		}
	}

	function new() {
		sound = MaSound.create();

		// BUGFIX
		// Explanation:
		// GC frees that shit like it thinks it's a zombie so do this.
		// This is because certain externs can be buggy and somewhat
		// unstable even without gc.
		cpp.vm.Gc.doNotKill(this);
	}

	function fromFile(path:String) {
		var result = Miniaudio.ma_sound_init_from_file(engine, path,
		0x00000001, null, null, sound);

		if (result != MaResult.MA_SUCCESS) {
			if (path != "") {
				Sys.println('[Sound system] Failed to initialize sound named "$path"');
				Sys.println(result);
			}
			return;
		}

		Miniaudio.ma_sound_get_length_in_seconds(sound, cpp.Pointer.addressOf(_length).ptr);
		_length *= 1000;

		_dataSource = Miniaudio.ma_sound_get_data_source(sound);
		Miniaudio.ma_data_source_get_data_format(_dataSource, null, null, cpp.Pointer.addressOf(_sampleRate).ptr, null, 0);
	}

	function play() {
		var result = Miniaudio.ma_sound_start(sound);

		_programPos = -Timestamp.get() + _playhead.driver;

		if (result != MaResult.MA_SUCCESS) {
			Sys.println("[Sound system] Failed to play sound");
			return;
		}
	}

	function stop() {
		var result = Miniaudio.ma_sound_stop(sound);

		if (result != MaResult.MA_SUCCESS) {
			Sys.println("[Sound system] Failed to stop sound");
			return;
		}
	}

	private function setTime(timeInSec:cpp.Float64) {
		Miniaudio.ma_sound_seek_to_pcm_frame(sound, untyped (sampleRate * timeInSec));

		_programPos = -Timestamp.get() + timeInSec;

		return timeInSec;
	}

	function update() {
		var result:Float = 0;

		if (playing) {
			_playhead.program = _programPos + Timestamp.get();

			Miniaudio.ma_sound_get_cursor_in_seconds(sound, cpp.Pointer.addressOf(_driverPos).ptr);
			_playhead.driver = Math.floor(_driverPos * 1000) * 0.001;

			var prog = _playhead.program;
			var driv = _playhead.driver;

			switch (playbackTrackingMethod) {
				case DRIVER:
					result = driv;
				case PROGRAM:
					result = prog;
				default:
					// Sync
					if (prog > driv) {
						var multiply = 0.125;
						if (prog - driv > 5) multiply = 0.25;
						else if (prog - driv > 12.5) multiply = 0.5;
						else if (prog - driv > 25) multiply = 1.0;
						var subtract = (prog - driv) * multiply;
						_playhead.program -= subtract;
						_programPos -= subtract;
					}
					result = _playhead.program;
			}

			if (result < 0) {
				result = 0;
			}

			if (result > length) {
				result = length;
			}
		} else if (finished) {
			result = length * 0.001;
		}

		_time = result * 1000.0;
	}

	function dispose() {
		stop();
		Miniaudio.ma_sound_uninit(sound);
	}

	static function uninit() {
		Miniaudio.ma_engine_uninit(engine);
	}
}

/**
	Playback tracking method.
**/
private enum abstract PlaybackTrackingMethod(cpp.UInt8) {
	/**
		Playback position is retrieved from the current audio driver.
	**/
	var DRIVER = 0x40;

	/**
		Playback position is retrieved from the program.
		We don't recommend using this one.
	**/
	var PROGRAM = 0x01;

	/**
		Playback position is estimated.
	**/
	var HYBRID = 0x80;
}

/**
	Playback tracker.
**/
@:publicFields
private abstract Playhead(Array<Float>) from Array<Float> {
	var driver(get, set):Float;

	inline function get_driver():Float {
		return this[0];
	}

	inline function set_driver(value:Float):Float {
		return this[0] = value;
	}

	var program(get, set):Float;

	inline function get_program():Float {
		return this[1];
	}

	inline function set_program(value:Float):Float {
		return this[1] = value;
	}

	inline function new() {
		this = [0, 0];
	}
}