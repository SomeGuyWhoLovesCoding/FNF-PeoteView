package system;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;

@:publicFields
class RenderingMode {
	private static var ffmpegExists(default, null):Bool;

	static var process:Process;
	static var enabled:Bool = false;

	static var songName:String;

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

		process = new Process('ffmpeg', [
			'-v', 'quiet', '-y', // START
			'-f', 'rawvideo', // FILTER
			'-pix_fmt', 'rgba', // PIXEL FORMAT
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT, // DIMENSIONS
			'-r', '60', // FRAMERATE
			'-display_hflip', '-display_rotation', '180', // This is here because the original output is mirrored and upside down
			'-i', '-', // INPUT INIT
			'-vcodec', 'libx264', // ENCODER
			'-crf', '0', // CRF
			'-preset', 'ultrafast', // PRESET
			'-c:a', 'copy', // COPY,
			'-colorspace', 'bt709', // CONVERT TO BT709 COLORSPACE
			'assets/videos/rendered/' + songName + '.mp4' // END (FILEPATH)
		]);

		Sys.println("Rendering Mode System - Done!");
	}

	static var bytes:haxe.io.UInt8Array;
	static function pipeFrame()
	{
		if (!enabled || !ffmpegExists || process == null)
			return;

		if (bytes == null) {
			bytes = new haxe.io.UInt8Array(Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4);
		}

		Main.current.peoteView.gl.readPixels(1, 1, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, bytes);
		process.stdin.write(untyped bytes.bytes);
	}

	static function stopRender()
	{
		if (!enabled)
			return;

		if (process != null) {
			if (process.stdin != null)
				process.stdin.close();

			process.close();
			process.kill();

			Sys.println("Rendering Mode System - Finished!");
		}
	}
}