package music;

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
	- `updateSmoothMusicTime()` – Prevent timing drift

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
#if (FV_LIME_FORK && lime_cffi)
import lime._internal.backend.native.NativeCFFI;
@:access(lime._internal.backend.native.NativeCFFI)
#end
@:publicFields
@:noDebug
class Mixer {
	static var trackCount:Int;
	static inline var sampleRate:Int = 44100;

	static var length(default, null):Float;

	static var speed(default, set):Float = 1;

	// Even then, this real-time audio must have this because miniaudio's sound stuff won't start immediately
	private static var offsetBetweenExpectedAndReality(default, null):Float;
	static var __isPlaying(default, null):Bool; // this here too
	static var calibratedMirroringOffset(default, null):Bool; // and this here too

	private static var hasSubLoopTick(default, null):Bool;

	static function set_speed(value:Float) {
		speed = Math.max(value, 0.1);
		MiniAudio.setPlaybackRate(speed);
		return speed;
	}

	static function setTime(value:Float, playfield:PlayField) {
		calibratedMirroringOffset = false;
		MiniAudio.seekToPCMFrame(Tools.betterInt64FromFloat(value * 0.001) * sampleRate);
		if (playfield != null) {
			if (playfield.songEnded) playfield.songPosition = MiniAudio.getPlaybackPosition();
		}
	}

	static var loadedFiles:Array<String>; // Add this

	static public function load(files:Array<String>):Void {
		for (i in 0...files.length)
			files[i] = Paths.asset(files[i]);

		loadedFiles = files; // Keep a reference to prevent GC
		MiniAudio.loadFiles(files);
		trackCount = files.length;
		length = MiniAudio.getDuration();
		enableSubLoop();
		__isPlaying = calibratedMirroringOffset = false;
		offsetBetweenExpectedAndReality = 0;
	}

	inline static function enableSubLoop() {
		#if FV_LIME_FORK
		hasSubLoopTick = true;
		#if lime_cffi
		var backend = @:privateAccess lime.app.Application.current.__backend;
		@:privateAccess NativeCFFI.lime_subloop_event_manager_register(subLoopTick_init, backend.subLoopTickEventInfo);
		#end
		#end
	}

	inline static function disableSubLoop() {
		#if FV_LIME_FORK
		hasSubLoopTick = false;
		#if lime_cffi
		var backend = @:privateAccess lime.app.Application.current.__backend;
		@:privateAccess NativeCFFI.lime_subloop_event_manager_register(backend.handleSubLoopEvent, backend.subLoopTickEventInfo);
		#end
		#end
	}

	#if (FV_LIME_FORK && lime_cffi)
	inline static function subLoopTick_init() {
		var backend = @:privateAccess lime.app.Application.current.__backend;
		@:privateAccess subLoopTick(backend.subLoopTickEventInfo.timestamp);
	}
	#end

	static public function startMusic():Void {
		__isPlaying = true;
		MiniAudio.start();
	}

	static public function stopMusic():Void {
		__isPlaying = calibratedMirroringOffset = false;
		MiniAudio.stop();
	}

	static public function destroyMusic():Void {
		__isPlaying = calibratedMirroringOffset = false;
		offsetBetweenExpectedAndReality = 0;
		MiniAudio.destroy();
		while (loadedFiles.pop() != null) {}
		loadedFiles = null; // Clean up
		disableSubLoop();
	}

	inline static public function updateSmoothMusicTime(deltaTime:Float, playfield:PlayField, window:Window):Void {
		if (isPlaying()) {
			var rawPlaybackPosition = MiniAudio.getPlaybackPosition() + Main.conductor.offset;
			playfield.songPosition += deltaTime;

			#if FV_LIME_FORK
			var smoothedTimeMult:Float = deltaTime / (1000 / window.renderFrameRate);
			#else
			var refreshRate = window.displayMode.refreshRate; // integer version if you're on vanilla lime
			var smoothedTimeMult:Float = (1000 / window.frameRate) / (1000 / refreshRate);
			#end

			var diff = playfield.songPosition - rawPlaybackPosition;
			var absDiff = Math.abs(diff);
			//Sys.println(absDiff);

			// Thresholds scaled by speed to maintain consistent correction behavior
			var speedFactor = speed;
			var smallest:Float = 3.75 * speedFactor;
			var small:Float = 8.5 * speedFactor;
			var big:Float = 17.5 * speedFactor;
			var biggest:Float = 40 * speedFactor;

			// Determine correction strength based on drift magnitude
			var multiply:Float = 0.05;
			if (absDiff > smallest) multiply = 0.1 * smoothedTimeMult;
			if (absDiff > small) multiply = 0.325 * smoothedTimeMult;
			if (absDiff > big) multiply = 0.975 * smoothedTimeMult;
			if (absDiff > biggest) multiply = 1.0 * smoothedTimeMult;

			var subtract = diff * multiply;
			if (calibratedMirroringOffset && __isPlaying) {
				subtract -= offsetBetweenExpectedAndReality;
			}
			playfield.songPosition -= subtract;
		}
	}

	#if FV_LIME_FORK
	static var lastTimestamp:Int64 = 0;
	static var lastTimestamp1s:Int64 = 0;
	static var obear_t:Int64; // long: offsetBetweenExpectedAndReality_timestamp
	static function subLoopTick(timestamp:Int64):Void {
		if (__isPlaying) {
			if (!calibratedMirroringOffset) {
				if (obear_t == 0) {
					obear_t = timestamp;
				}
				if (isPlaying()) {
					var value = timestamp - obear_t;
					offsetBetweenExpectedAndReality = Tools.int64ToFloat(value) / 100000.0;
					obear_t = 0;
					calibratedMirroringOffset = true;
				}
			}
		}

		var window = lime.app.Application.current.window;
		var renderDelta = 1000 / window.renderFrameRate;
		var playField = Main.current.playField;
		if (lastTimestamp == 0) lastTimestamp = timestamp;
		if (lastTimestamp1s == 0) lastTimestamp1s = timestamp;
		var deltaTime:Float = Tools.int64ToFloat(timestamp - lastTimestamp) / 100000;
		if (deltaTime < 0.0001) deltaTime = 0.0001;
		if (playField != null) {
			var field = playField.field;
			if (field != null) {
				if (!field.isInGameOver) {
					// If the song hasn't started yet, update the countdown conductor only.
					// Do NOT apply latency compensation here — countdownDisp.conductor must see a pure musical timeline.
					if (!playField.songStarted && !playField.songEnded) {
						// Mixer already advanced playfield.songPosition during pre-start,
						// so simply push that time to the countdown conductor.
						if (playField.countdownDisp != null) {
							if (playField.countdownDisp.conductor != null)
								playField.countdownDisp.conductor.time = playField.songPosition;
						}
					}
					if (!playField.paused) {
						if (!playField.songStarted || playField.songEnded || RenderingMode.enabled) {
							if (deltaTime > renderDelta) deltaTime = renderDelta;
							playField.songPosition += deltaTime * Mixer.speed;
						} else {
							updateSmoothMusicTime(deltaTime, playField, window);
						}
					}

					Main.conductor.time = playField.songPosition - playField.latencyCompensation - Mixer.latency();
				} else {
					field.updateGameOver();
				}
			}
		}

		if (timestamp - lastTimestamp1s > 100000000) {
			lastTimestamp1s = timestamp;
		}
		lastTimestamp = timestamp;
	}
	#end

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
					Sys.println('Stopping song playback due to rendering mode.');
					playField.onStopSong.dispatch(Chart.header);
				} else if (playField.songStarted && isStopped() && !playField.songEnded) {
					Sys.println('Stopping song playback due to stop condition.');
					playField.onStopSong.dispatch(Chart.header);
				}
			}

			#if !FV_LIME_FORK
			if (!playField.songStarted || playField.songEnded || RenderingMode.enabled) {
				playField.songPosition += deltaTime * Mixer.speed;
			} else {
				var window = lime.app.Application.current.window;
				updateSmoothMusicTime(deltaTime, playField, window);
			}
			#end
		}
	}

	static inline function latency():Int {
		return MiniAudio.detectLatency();
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