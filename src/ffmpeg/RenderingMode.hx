package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.app.Application;

@:publicFields
class RenderingMode {
	private static var ffmpegExists(default, null):Bool;

	static var process:Process;
	static var enabled:Bool = true;
	static var started:Bool = false;

	static var songName:String;

	static var renderTime(default, null):Float;
	static var frameRate:Float = 60;

	static function getBestEncoder():Array<String> {
		var encoders = [
			// NVIDIA NVENC - fastest preset
			{name: 'h264_nvenc', args: [
				'-c:v', 'h264_nvenc',
				'-preset', 'p1',           // p1 = fastest (was p4)
				'-tune', 'ull',            // ultra-low latency
				'-b:v', '12M',             // reduced bitrate for speed
				'-maxrate', '12M',
				'-bufsize', '30M'
			]},
			
			// AMD AMF - fastest preset
			{name: 'h264_amf', args: [
				'-c:v', 'h264_amf',
				'-quality', 'speed',       // speed mode (was balanced)
				'-b:v', '12M',
				'-maxrate', '12M',
				'-rc', 'vbr_latency'       // variable bitrate low latency
			]},
			
			// Intel QSV - fastest preset
			{name: 'h264_qsv', args: [
				'-c:v', 'h264_qsv',
				'-preset', 'veryfast',     // veryfast (was medium)
				'-global_quality', '25',   // lower quality = faster
				'-look_ahead', '0',        // disable lookahead for speed
				'-b:v', '12M'
			]}
		];

		for (encoder in encoders) {
			var testProcess = new Process('ffmpeg', [
				'-f', 'lavfi',
				'-v', 'quiet',
				'-i', 'color=black:s=64x64:d=0.1',
				'-c:v', encoder.name,
				'-f', 'null',
				'-'
			]);

			var stderr = testProcess.stderr.readAll().toString();
			var exitCode = testProcess.exitCode();
			
			if (stderr.indexOf('Conversion failed!') > -1 || exitCode != 0) {
				continue;
			} else {
				Sys.println('Rendering Mode System - Using encoder: ${encoder.name}');
				return encoder.args;
			}
		}

		// Software fallback - optimized for speed on low-end systems
		Sys.println('Rendering Mode System - Using encoder: libx264 (software fallback)');
		return [
			'-c:v', 'libx264',
			'-preset', 'ultrafast',    // fastest CPU preset (was veryfast)
			'-crf', '23',              // slightly lower quality for speed (was 18)
			'-tune', 'zerolatency',    // optimize for speed
			'-x264-params', 'ref=1:bframes=0:me=dia:subq=1:trellis=0' // minimal CPU processing
		];
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

		if (!FileSystem.exists('assets/videos/rendered/')) {
			Sys.println('Rendering Mode System - "assets/videos/rendered" folder not found! Recreating it...');
			FileSystem.createDirectory('assets/videos/rendered');
		}

		ffmpegExists = true;

		Sys.println("Rendering Mode System - Initializing...");

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = true;
		#else
		Application.current.window.frameRate = 1000;
		#end

		songName = Chart.header.title;

		Sys.println("Rendering Mode System - Deciding on what encoder to use for your system...");

		var encoderSettings = getBestEncoder();

		Sys.println("Rendering Mode System - Done. Now let's initialize the real stuff!");

		var args = [
			'-y',
			'-f', 'rawvideo',
			'-pix_fmt', 'rgba',
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r', Std.string(frameRate),
			'-i', '-',
			'-vf', 'vflip',
			'-flush_packets', '0'
		];

		args = args.concat(encoderSettings);

		args = args.concat([
			'-colorspace', 'bt709',
			'-pix_fmt', 'yuv420p',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		Sys.println("Rendering Mode System - Almost there. Just need to execute the process just like that...");

		process = new Process('ffmpeg', args);

		Sys.println("Rendering Mode System - Done.");

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

			// Read directly - this is synchronous but the most reliable method
			Main.current.peoteView.gl.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, bytes);
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

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in just ${Tools.formatTime(renderTime * 1000)}.');
	}
}