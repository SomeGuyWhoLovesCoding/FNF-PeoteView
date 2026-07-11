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
	- `updateWithAudioTime()` – Simulate smooth audio time internally & prevent timing drift

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
		
		// Clean up window system state
		accumulatedTime = 0;
		audioTimeWindow = [];
		windowIndex = 0;
	}

	// =========================================================================
	//  Audio Time Window System (100ms / 4000 Timestamps)
	// =========================================================================
	
	/** Circular buffer storing the last ~4000 audio timestamps (approx 100ms at 44.1kHz) */
	static var audioTimeWindow:Array<Float> = [];
	static var windowIndex:Int = 0;
	static var accumulatedTime:Float = 0;
	static inline var WINDOW_SIZE:Int = 4000;
	
	static public function updateWithAudioTime(deltaTime:Float, playfield:PlayField, window:Window):Void {
		if (playfield == null) return;
		
		if (isPlaying()) {
			// 1. Accumulate audio time based on delta time (prediction)
			accumulatedTime += deltaTime * speed;
			
			// 2. Get the actual audio playback position
			var audioTime = MiniAudio.getPlaybackPosition();
			
			// 3. Store the real timestamp in our 4000-size circular buffer
			if (audioTimeWindow.length < WINDOW_SIZE) {
				audioTimeWindow.push(audioTime);
			} else {
				audioTimeWindow[windowIndex] = audioTime;
			}
			windowIndex = (windowIndex + 1) % WINDOW_SIZE;
			
			// 4. Choose the best timestamp from the window
			// We find the timestamp in the buffer that is closest to our accumulated prediction
			var bestTime = audioTime;
			var minDiff = Math.POSITIVE_INFINITY;
			
			// Note: Iterating 4000 floats in Haxe takes <0.1ms, so this is extremely lightweight
			for (i in 0...audioTimeWindow.length) {
				var t = audioTimeWindow[i];
				var diff = Math.abs(t - accumulatedTime);
				if (diff < minDiff) {
					minDiff = diff;
					bestTime = t;
				}
			}
			
			// 5. Smoothly correct the accumulated time towards the chosen timestamp
			var drift = bestTime - accumulatedTime;
			
			if (Math.abs(drift) > 50.0) {
				// Large drift (e.g., after a manual seek), snap directly to prevent desync
				accumulatedTime = bestTime;
			} else {
				// Small drift: apply smooth correction to eliminate jitter without going overboard
				accumulatedTime += drift * 0.1; // Adjust 0.1 to change correction strength
			}
			
			playfield.songPosition = accumulatedTime;
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