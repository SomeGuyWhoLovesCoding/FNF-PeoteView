package system;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;

@:publicFields
class RenderingMode {
	private static var ffmpegExists(default, null):Bool;

	static var process:Process;
	static var enabled:Bool = true;
	static var started:Bool = false;

	static var songName:String;

	static var renderTime(default, null):Float;

	static function getBestEncoder():Array<String> {
		var encoders = [
			{name: 'h264_nvenc', args: ['-c:v', 'h264_nvenc', '-preset', 'p4', '-b:v', '20M']},
			{name: 'h264_amf', args: ['-c:v', 'h264_amf', '-quality', 'balanced', '-b:v', '20M']},
			{name: 'h264_qsv', args: ['-c:v', 'h264_qsv', '-preset', 'medium', '-b:v', '20M']},
			{name: 'libx264', args: ['-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast']}
		];

		for (encoder in encoders) {
			try {
				// Actually test if the encoder works by trying to encode a single frame
				var testProcess = new Process('ffmpeg', [
					'-f', 'lavfi',
					'-i', 'color=black:s=64x64:d=0.1',
					'-c:v', encoder.name,
					'-f', 'null',
					'-'
				]);
				
				var exitCode = testProcess.exitCode();
				testProcess.close();
				
				if (exitCode == 0) {
					Sys.println('Rendering Mode System - Using encoder: ${encoder.name}');
					return encoder.args;
				}
			} catch (e:Dynamic) {
				// Encoder test failed, try next one
				continue;
			}
		}

		// Fallback to software encoding
		Sys.println('Rendering Mode System - Using encoder: libx264 (software fallback)');
		return ['-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast'];
	}

	static function initRender()
	{
		var ffmpeg = "ffmpeg";
		#if windows
		ffmpeg += ".exe";
		#end
		if (!FileSystem.exists(ffmpeg)) {
			throw 'Rendering Mode System - $ffmpeg not found! Is it located at the current working directory?';
			return;
		}

		if (!FileSystem.exists('assets/videos/rendered/')) { // In case you delete the videos/rendered folder
			Sys.println('Rendering Mode System - "assets/videos/rendered" folder not found! Recreating it...');
			FileSystem.createDirectory('assets/videos/rendered');
		}

		ffmpegExists = true;

		Sys.println("Rendering Mode System - Initializing...");

		songName = Chart.header.title;

		// Get best encoder settings
		var encoderSettings = getBestEncoder();

		// Build the full arguments array
		var args = [
			'-y', // START (removed -v quiet for debugging)
			'-f', 'rawvideo', // FILTER
			'-pix_fmt', 'rgba', // PIXEL FORMAT
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT, // DIMENSIONS
			'-r', '60', // FRAMERATE
			'-i', '-', // INPUT INIT
			'-vf', 'vflip', // Use video filter instead of display flags
		];

		// Add encoder settings
		args = args.concat(encoderSettings);

		// Add remaining settings
		args = args.concat([
			'-colorspace', 'bt709', // CONVERT TO BT709 COLORSPACE
			'-pix_fmt', 'yuv420p', // Ensure compatibility
			'assets/videos/rendered/' + songName + '.mp4' // END (FILEPATH)
		]);

		process = new Process('ffmpeg', args);

		renderTime = haxe.Timer.stamp();
		started = true;
		Sys.println("Rendering Mode System - Started!");
	}

	static var bytes:haxe.io.UInt8Array;
	static function pipeFrame()
	{
		if (!enabled || !started || !ffmpegExists || process == null)
			return;

		try {
			if (bytes == null) {
				bytes = new haxe.io.UInt8Array(Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4);
			}

			Main.current.peoteView.gl.readPixels(1, 1, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, bytes);
			process.stdin.write(untyped bytes.bytes);
		} catch (e:Dynamic) {
			Sys.println('Rendering Mode System - Error writing frame: $e');
			stopRender();
		}
	}

	static function stopRender()
	{
		if (!enabled && !started)
			return;

		started = false;

		if (process != null) {
			try {
				if (process.stdin != null)
					process.stdin.close();
			} catch (e:Dynamic) {
				// Ignore close errors
			}

			process.close();
			process.kill();
		}

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in just ${Tools.formatTime(renderTime * 1000)}.');
	}
}