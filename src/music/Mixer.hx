package music;

import lime.ui.KeyCode;
import miniaudio.MiniAudio;
import miniaudio.StdVectorString;
import utils.Tools;
import lime.ui.Window;
import data.SaveData;

@:publicFields
class Mixer {
	static var globalVolume(get, set):Float;
	inline static function get_globalVolume():Float {
		return MiniAudio.getMixerMasterVolume();
	}
	inline static function set_globalVolume(value:Float):Float {
		return MiniAudio.setMixerMasterVolume(value);
	}

	static var trackCount:Int;
	static inline var sampleRate:Int = 44100;

	static var length(default, null):Float;

	static var speed(default, set):Float = 1;

	static function set_speed(value:Float) {
		speed = Math.max(value, 0.1);
		MiniAudio.setPlaybackRate(speed);
		// Apply the performance preference: keep pitch-preserving time-stretch only when enabled.
		#if (cpp || hl)
		MiniAudio.setStretchEnabled(SaveData.state.preferences.timeStretch != false);
		#end
		return speed;
	}

	static function applyTimeStretchPreference() {
		#if (cpp || hl)
		MiniAudio.setStretchEnabled(SaveData.state.preferences.timeStretch != false);
		#end
	}

	static function setTime(value:Float, playfield:PlayField) {
		var pcmFrame = Tools.betterInt64FromFloat(value * (sampleRate / 1000.0));
		MiniAudio.seekToPCMFrame(pcmFrame);
		if (playfield != null) {
			if (playfield.songEnded) playfield.songPosition = MiniAudio.getPlaybackPosition();
		}
		
		// Reset the window system when seeking to prevent stale data
		accumulatedTime = value;
		audioTimeWindow = [];
		windowIndex = 0;
	}

	static var loadedFiles:Array<String>;

	static public function load(files:Array<String>):Void {
		for (i in 0...files.length)
			files[i] = Paths.asset(files[i]);

		loadedFiles = files;
		MiniAudio.loadFiles(files);
		trackCount = files.length;
		length = MiniAudio.getDuration();
		
		// Initialize window system state
		accumulatedTime = 0;
		audioTimeWindow = [];
		windowIndex = 0;
		
		Sys.println("  [ Audio Pipeline ]   Song initialized. (Length: " + Tools.formatTime(length, true) + ")");

		// Apply the time-stretch performance preference once the audio system is up.
		#if (cpp || hl)
		MiniAudio.setStretchEnabled(SaveData.state.preferences.timeStretch != false);
		#end
	}

	static public function startMusic():Void {
		MiniAudio.start();
		// FIX: Clear the window to prevent stale timestamps from affecting the resume
		audioTimeWindow = [];
		windowIndex = 0;
	}

	static public function stopMusic():Void {
		MiniAudio.stop();
		// FIX: Clear the window to prevent stale timestamps from affecting the next pause
		audioTimeWindow = [];
		windowIndex = 0;
	}

	static public function destroyMusic():Void {
		MiniAudio.destroy();
		while (loadedFiles.pop() != null) {}
		loadedFiles = null; // Clean up
		
		// Clean up window system state
		accumulatedTime = 0;
		audioTimeWindow = [];
		windowIndex = 0;
	}

	// =========================================================================
	//  Audio Time Window System (100ms / 4000 Timestamps)
	// =========================================================================
	
	static var audioTimeWindow:Array<Float> = [];
	static var windowIndex:Int = 0;
	static var accumulatedTime:Float = 0;
	static inline var WINDOW_SIZE:Int = 4000;
	
	static public function updateWithAudioTime(deltaTime:Float, playfield:PlayField, window:Window):Void {
		if (playfield == null) return;
		
		if (isPlaying()) {
			playfield.songPosition = MiniAudio.getPlaybackPosition();
		}
	}

	static function isPlaying():Bool {
		return MiniAudio.getMixerState() == MixerState.PLAYING;
	}

	static function isStopped():Bool {
		return MiniAudio.stopped();
	}

	static function changeTrackVolume(index:Int, volume:Float):Void {
		MiniAudio.amplify_decoder(index, volume);
	}

	static function init(header:Header):Void {
		var files:Array<String> = header.voicesDirs;
		files.unshift(header.instDir);
		load(files);
	}

	static function update(playField:PlayField, deltaTime:Float):Void {
		if (playField != null) {
			if (!playField.songEnded) {
				if (RenderingMode.enabled && playField.songPosition > length) {
					Sys.println('  [ Audio Pipeline ]   Stopping song playback due to rendering mode.\n');
					playField.onStopSong.dispatch(Chart.header);
				} else if (playField.songStarted && isStopped() && !playField.songEnded && !RenderingMode.enabled) {
					Sys.println('  [ Audio Pipeline ]   Stopping song playback due to stop condition.\n');
					playField.onStopSong.dispatch(Chart.header);
				}
			}

			if (!playField.songStarted || playField.songEnded || RenderingMode.enabled) {
				playField.songPosition += deltaTime * Mixer.speed;
			} else {
				var window = lime.app.Application.current.window;
				updateWithAudioTime(deltaTime, playField, window);
			}
		}
	}

	private static var __cachedLatency(default, null):Int = 100;
	private static var __cachedLatency_times(default, null):Int;

	static inline function latency():Int {
		__cachedLatency_times++;
		if (__cachedLatency_times > 300) {
			__cachedLatency = MiniAudio.detectLatency();
			__cachedLatency_times = 0;
		}
		return __cachedLatency;
	}
}

enum abstract MixerState(Int) from Int to Int {
	var PLAYING = 1;
	var STOPPED = 2;
	var FINISHED = 3;
}