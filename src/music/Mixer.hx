package music;

import miniaudio.MiniAudio;
import miniaudio.StdVectorString;
import utils.Tools;

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
	- Does **not** perform low-level audio processing directly
	@since Development
 */
@:publicFields
class Mixer {
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
		MiniAudio.seekToPCMFrame(Tools.betterInt64FromFloat(value * 0.001) * sampleRate);
		if (playfield != null) {
			if (playfield.songEnded) playfield.songPosition = MiniAudio.getPlaybackPosition();
		}
	}

	static public function load(files:Array<String>):Void { // Don't rename this to `loadFiles` as it will conflict with the MiniAudio extern class
		MiniAudio.loadFiles(files);
		trackCount = files.length;
		length = MiniAudio.getDuration();
	}

	static public function startMusic():Void {
		MiniAudio.start();
	}

	static public function stopMusic():Void {
		MiniAudio.stop();
	}

	static public function destroyMusic():Void {
		MiniAudio.destroy();
	}

	static public function updateSmoothMusicTime(deltaTime:Float, playfield:PlayField):Void {
		if (isPlaying()) {
			var window = lime.app.Application.current.window;
			var rawPlaybackPosition = MiniAudio.getPlaybackPosition() + Main.conductor.offset;
			playfield.songPosition += deltaTime;
			var multiply = 0.05; // Default drift adjustment value
			var diff = playfield.songPosition - rawPlaybackPosition;
			#if FV_LIME_FORK
			var frameTimeDiff:Float = (1000 / window.frameRate) / (1000 / window.renderFrameRate);
			#else
			var refreshRate = window.displayMode.refreshRate; // integer version if you're on vanilla lime
			var frameTimeDiff:Float = (1000 / window.frameRate) / (1000 / refreshRate);
			#end
			var smallest:Float = 5;
			var small:Float = 12.5;
			var big:Float = 25;
			var biggest:Float = 50;
			if (speed != 1) {
				smallest *= speed;
				small *= speed;
				big *= speed;
				biggest *= speed;
			}
			//Sys.println(frameTimeDiff);
			if (diff > smallest || diff < -smallest) multiply = 0.1 * frameTimeDiff;
			if (diff > small || diff < small) multiply = 0.325 * frameTimeDiff;
			if (diff > big || diff < -big) multiply = 0.975 * frameTimeDiff;
			if (diff > biggest || diff < -biggest) multiply = 1.0 * frameTimeDiff;
			var subtract = diff * multiply;
			playfield.songPosition -= subtract;
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
					Sys.println('Stopping song playback due to rendering mode.');
					playField.onStopSong.dispatch(Chart.header);
				} else if (playField.songStarted && isStopped() && !playField.songEnded) {
					Sys.println('Stopping song playback due to stop condition.');
					playField.onStopSong.dispatch(Chart.header);
				}
			}

			if (!playField.songStarted || playField.songEnded || RenderingMode.enabled) {
				playField.songPosition += deltaTime * Mixer.speed;
			} else {
				updateSmoothMusicTime(deltaTime, playField);
			}
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