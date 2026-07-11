package music;

import lime.ui.KeyCode;
import miniaudio.MiniAudio;
import miniaudio.StdVectorString;
import utils.Tools;
import lime.ui.Window;

/**
	# Music Playback Helper (Haxe + MiniAudio)

	This Haxe class is a **helper for managing music playback** using the **MiniAudio** library. It is tailored for **real-time applications**, such as games, and is designed with **performance and simplicity** in mind.

	---

	## 🎵 Core Features

	- Loads and manages **music files**
	- Allows starting and stopping of **music playback**
	- Tracks and adjusts **current playback time** to prevent drift
	- Smoothly updates playback time using **delta time**

	---

	## ⚙️ Design Details

	- Uses a default **sample rate of 44100 Hz** (can be adjusted)
	- Maintains:
	- Current **playback position**
	- Total **length** of the track
	- Utilizes the `MiniAudio` class for **low-level audio operations**

	### Main Methods:
	- `loadFiles()` – Initialize music from file paths
	- `startMusic()` / `stopMusic()` – Control playback
	- `destroyMusic()` – Clean up resources
	- `updateSmoothMusicTime()` – Simulate smooth audio time & prevent timing drift

	---

	## 🧠 Usage Considerations

	- Designed for **single-threaded use** (not thread-safe)
	- Optimized for **performance** (minimal overhead)
	- Intended for **real-time** playback (e.g., game loop)
	- Requires `MiniAudio` to be **properly initialized**
	- Should be used alongside other **music modules**
	- Handle **errors gracefully**, especially with file operations
	- Always call `destroyMusic()` when playback is no longer needed

	---

	## 📌 Notes

	- Acts as a **high-level abstraction** for music playback
	@since Development
 */
@:publicFields
@:noDebug
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
		return speed;
	}

	static function setTime(value:Float, playfield:PlayField) {
		var pcmFrame = Tools.betterInt64FromFloat(value * (sampleRate / 1000.0));
		MiniAudio.seekToPCMFrame(pcmFrame);
		if (playfield != null) {
			if (playfield.songEnded) playfield.songPosition = MiniAudio.getPlaybackPosition();
		}
	}

	static var loadedFiles:Array<String>;

	static public function load(files:Array<String>):Void {
		for (i in 0...files.length)
			files[i] = Paths.asset(files[i]);

		loadedFiles = files;
		MiniAudio.loadFiles(files);
		trackCount = files.length;
		length = MiniAudio.getDuration();
		Sys.println("  [ Audio Pipeline ]   Song initialized. (Length: " + Tools.formatTime(length, true) + ")");
	}

	static public function startMusic():Void {
		MiniAudio.start();
	}

	static public function stopMusic():Void {
		MiniAudio.stop();
	}

	static public function destroyMusic():Void {
		MiniAudio.destroy();
		while (loadedFiles.pop() != null) {}
		loadedFiles = null; // Clean up
	}

	private static var ogLatencyForImmediateChange(default, null):Int = 100;
	static public function updateSmoothMusicTime(deltaTime:Float, playfield:PlayField, window:Window):Void {
		if (playfield == null) return;
		if (isPlaying()) {
			var ogSongPos = playfield.songPosition + (deltaTime * speed);
			var latency = playfield.latencyCompensation - Mixer.latency();
			// note: do not add latency to rawPlaybackPosition.
			// and for the part where you set songPosition to ogSongPos, do not add latency to it as well.
			// That was the cause of the "glitch" halfwheat wanted fixed desperately
			// so instead I just set it on the note system class where everything processes.
			var rawPlaybackPosition = MiniAudio.getPlaybackPosition();
			if (playfield.songPosition - rawPlaybackPosition > 5 && rawPlaybackPosition < 50) {
				playfield.songPosition = ogSongPos;
			} else {
				playfield.songPosition += deltaTime * speed;

				var refreshRate = window.displayMode.refreshRate; // integer version if you're on vanilla lime
				var smoothedTimeMult:Float = ((1000 / window.frameRate) / (1000 / refreshRate)) * speed;
				if (RenderingMode.enabled) smoothedTimeMult = 1;

				var diff = ogSongPos - rawPlaybackPosition;
				var absDiff = Math.abs(diff);

				var smallest:Float = 3.75 * speed;
				var small:Float = 8.5 * speed;
				var big:Float = 17.5 * speed;
				var biggest:Float = 40 * speed;

				// Determine correction strength based on drift magnitude
				var multiply:Float = 0.05;
				var delayIsDifferent = ogLatencyForImmediateChange != __cachedLatency;
				if (delayIsDifferent) {
					multiply = 1.0; // immediately change if latency has changed
					playfield.songPosition = rawPlaybackPosition;
				} else {
					if (absDiff > smallest) multiply = 0.1 * smoothedTimeMult;
					if (absDiff > small) multiply = 0.325 * smoothedTimeMult;
					if (absDiff > big) multiply = 0.975 * smoothedTimeMult;
					if (absDiff > biggest) multiply = 1.0;

					var subtract = diff * multiply;
					ogSongPos -= Math.min(subtract, biggest); // Math.min here to prevent supernova from gc
					playfield.songPosition = ogSongPos;
				}
			}

			if (ogLatencyForImmediateChange != __cachedLatency) {
				playfield.songPosition = rawPlaybackPosition + deltaTime;
			}

			ogLatencyForImmediateChange = __cachedLatency;
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
				updateSmoothMusicTime(deltaTime, playField, window);
			}
		}
	}

	private static var __cachedLatency(default, null):Int = 100;

	// This is for optimization to reduce cpu usage. And yes, this is necessary because playback device connection times are not instant.
	private static var __cachedLatency_times(default, null):Int;
	//

	static inline function latency():Int {
		__cachedLatency_times++;
		if (__cachedLatency_times > 300) {
			__cachedLatency = MiniAudio.detectLatency();
			__cachedLatency_times = 0;
		}
		return __cachedLatency;
	}
}

/**
	- `0` - Undefined
	- `1` - Playing
	- `2` - Paused
	- `3` - Finished
*/
enum abstract MixerState(Int) from Int to Int {
	var PLAYING = 1;
	var STOPPED = 2;
	var FINISHED = 3;
}