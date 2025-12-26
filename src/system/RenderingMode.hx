package system;

import sys.io.Process;
import sys.io.FileInput;
import sys.FileSystem;
import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import lime.app.Application;

@:publicFields
class RenderingMode
{
	// --------------------------------------------------
	// Configuration
	// --------------------------------------------------
	static inline var MAX_BUFFERED_FRAMES = 100;

	static var bytesPerFrame:Int;

	// --------------------------------------------------
	// State
	// --------------------------------------------------
	static var process:Process;
	static var frameBuffer = new BytesBuffer();
	static var started:Bool = false;
	static var enabled:Bool = true;
	static var ffmpegExists:Bool = false;

	static var songName:String;
	static var renderTime:Float;

	// --------------------------------------------------
	// Decoded frames RAM storage
	// --------------------------------------------------
	static var decodedFrames:Array<Bytes> = [];

	// --------------------------------------------------
	// Encoder detection (unchanged)
	// --------------------------------------------------
	static function getBestEncoder():Array<String>
	{
		var encoders = [
			{name: 'h264_nvenc', args: ['-c:v', 'h264_nvenc', '-preset', 'p4', '-b:v', '20M']},
			{name: 'h264_amf',   args: ['-c:v', 'h264_amf',   '-quality', 'balanced', '-b:v', '20M']},
			{name: 'h264_qsv',   args: ['-c:v', 'h264_qsv',   '-preset', 'medium', '-b:v', '20M']}
		];

		for (encoder in encoders) {
			var test = new Process('ffmpeg', [
				'-f', 'lavfi',
				'-i', 'color=black:s=64x64:d=0.1',
				'-c:v', encoder.name,
				'-f', 'null',
				'-'
			]);

			var code = test.exitCode();
			test.close();

			if (code == 0) {
				Sys.println('Rendering Mode System - Using encoder: ${encoder.name}');
				return encoder.args;
			}
		}

		Sys.println('Rendering Mode System - Using encoder: libx264 (fallback)');
		return ['-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast'];
	}

	// --------------------------------------------------
	// Initialize rendering
	// --------------------------------------------------
	static function initRender()
	{
		var ffmpeg = #if windows "ffmpeg.exe" #else "ffmpeg" #end;

		if (!FileSystem.exists(ffmpeg)) {
			throw 'Rendering Mode System - ffmpeg not found!';
		}

		if (!FileSystem.exists('assets/videos/rendered'))
			FileSystem.createDirectory('assets/videos/rendered');

		ffmpegExists = true;

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = true;
		#else
		Application.current.window.frameRate = 1000;
		#end

		songName = Chart.header.title;
		bytesPerFrame = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;

		Sys.println("Rendering Mode System - Selecting encoder...");
		var encoderArgs = getBestEncoder();

		// ------------------------------------------
		// Start FFmpeg for encoding normally
		// ------------------------------------------
		var args = [
			'-y',
			'-f', 'rawvideo',
			'-pix_fmt', 'rgba',
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r', '60',
			'-i', 'pipe:0'
		];

		args = args.concat(encoderArgs);
		args = args.concat([
			'-pix_fmt', 'yuv420p',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		process = new Process('ffmpeg', args);

		renderTime = haxe.Timer.stamp();
		started = true;

		Sys.println("Rendering Mode System - Recording started.");
	}

	// --------------------------------------------------
	// Pipe frame for encoding
	// --------------------------------------------------
	static function pipeFrame()
	{
		if (!enabled || !started || process == null)
			return;

		try {
			var frame = PBOManager.captureFrame(Main.current.peoteView.gl);

			if (frame != null) {
				frameBuffer.add(frame.bytes);

				if (frameBuffer.length >= bytesPerFrame * MAX_BUFFERED_FRAMES) {
					flushBuffer();
				}
			}
		}
		catch (e:Dynamic) {
			Sys.println("Rendering Mode System - Capture error: " + e);
			stopRender();
		}
	}

	// --------------------------------------------------
	// Flush buffer to FFmpeg
	// --------------------------------------------------
	static function flushBuffer()
	{
		try {
			var bytes = frameBuffer.getBytes();
			process.stdin.write(bytes);
			process.stdin.flush();
			frameBuffer = new BytesBuffer();
		}
		catch (e:Dynamic) {
			Sys.println("Rendering Mode System - Pipe write failed: " + e);
			stopRender();
		}
	}

	// --------------------------------------------------
	// Decode video into RAM
	// --------------------------------------------------
	static function decodeToRAM(videoPath:String)
	{
		if (!FileSystem.exists(videoPath)) {
			Sys.println("Rendering Mode System - Video file does not exist: $videoPath");
			return;
		}

		var args = [
			"-i", videoPath,
			"-f", "rawvideo",
			"-pix_fmt", "rgba",
			"pipe:1"
		];

		var decodeProc = new Process("ffmpeg", args);
		var stdout = decodeProc.stdout;
		decodedFrames = [];

		var frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;

		while (true) {
			var b = Bytes.alloc(frameSize);
			var read = stdout.read(b, 0, frameSize);
			if (read < frameSize) break; // EOF
			decodedFrames.push(b);
		}

		decodeProc.close();
		Sys.println("Rendering Mode System - Decoded ${decodedFrames.length} frames to RAM.");
	}

	// --------------------------------------------------
	// Stop rendering
	// --------------------------------------------------
	static function stopRender()
	{
		if (!started)
			return;

		started = false;

		try {
			if (frameBuffer.length > 0)
				flushBuffer();
		} catch (_) {}

		try {
			if (process != null)
				process.close();
		} catch (_) {}

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished in ${Tools.formatTime(renderTime * 1000)}.');
	}
}
