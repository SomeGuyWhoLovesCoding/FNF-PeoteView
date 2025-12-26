package ffmpeg;

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
	static var frameRate:Float = 60;

	static var songName:String;

	static var renderTime(default, null):Float;

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

		songName = Chart.header.title;

		#if windows
		// Intel Quick Sync (QSV) for Windows
		process = new Process('ffmpeg', [
			'-v', 'quiet', '-y',
			'-f', 'rawvideo',
			'-pix_fmt', 'rgba',
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r', Std.string(frameRate),
			'-i', '-',
			'-vf', 'vflip,format=nv12', // Convert to NV12
			'-c:v', 'h264_qsv', // Intel Quick Sync encoder
			'-global_quality', '27', // Quality (lower = better, range 1-51)
			'-b:v', '2M',
			'-preset', 'fast',
			'-c:a', 'copy',
			'-colorspace', 'bt709',
			'assets/videos/rendered/' + songName + '.mp4'
		]);
		#else
		// VAAPI for Linux
		process = new Process('ffmpeg', [
			'-v', 'quiet', '-y',
			'-init_hw_device', 'vaapi=va:/dev/dri/renderD128',
			'-f', 'rawvideo',
			'-pix_fmt', 'rgba',
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r', Std.string(frameRate),
			'-i', '-',
			'-vf', 'format=nv12,hwupload',
			'-c:v', 'h264_vaapi',
			'-qp', '18',
			'-c:a', 'copy',
			'-colorspace', 'bt709',
			'assets/videos/rendered/' + songName + '.mp4'
		]);
		#end

		renderTime = haxe.Timer.stamp();
		started = true;
		Sys.println("Rendering Mode System - Started!");
	}

	static var bytes:haxe.io.UInt8Array;
	static function pipeFrame()
	{
		if (!enabled || !started || !ffmpegExists || process == null)
			return;

		if (bytes == null) {
			bytes = new haxe.io.UInt8Array(Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4);
		}

		Main.current.peoteView.gl.readPixels(1, 1, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, bytes);
		process.stdin.write(untyped bytes.bytes);
	}

	static function stopRender()
	{
		if (!enabled && !started)
			return;

		started = false;

		if (process != null) {
			if (process.stdin != null)
				process.stdin.close();

			process.close();
			process.kill();
		}

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in just ${Tools.formatTime(renderTime * 1000)}.');
	}
}