package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.app.Application;
#if windows
import sys.io.FileOutput;
import sys.io.FileInput;
import cpp.NativeProcess;
#end
using StringTools;

@:publicFields
class RenderingMode {
	private static var ffmpegExists(default, null):Bool;
	private static var pipePath:String = null; // Store pipe path for cleanup
	#if windows
	private static var pipeServer:Process = null; // Windows pipe server process
	#end

	static var process:Process;
	static var enabled:Bool = true;
	static var started:Bool = false;

	static var songName:String;

	static var renderTime(default, null):Float;

	static function getBestEncoder():Array<String> {
		var encoders = [
			// NVIDIA NVENC - fastest preset
			{name: 'h264_nvenc', args: [
				'-c:v', 'h264_nvenc',
				'-preset', 'p1',
				'-tune', 'ull',
				'-b:v', '12M',
				'-maxrate', '12M',
				'-bufsize', '30M'
			]},
			
			// AMD AMF - fastest preset
			{name: 'h264_amf', args: [
				'-c:v', 'h264_amf',
				'-quality', 'speed',
				'-b:v', '12M',
				'-maxrate', '12M',
				'-rc', 'vbr_latency'
			]},
			
			// Intel QSV - fastest preset
			{name: 'h264_qsv', args: [
				'-c:v', 'h264_qsv',
				'-preset', 'veryfast',
				'-global_quality', '25',
				'-look_ahead', '0',
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
			'-preset', 'ultrafast',
			'-crf', '23',
			'-tune', 'zerolatency',
			'-x264-params', 'ref=1:bframes=0:me=dia:subq=1:trellis=0'
		];
	}
    
    static function findPowerShellPath():String {
        // Common PowerShell paths
        var possiblePaths = [
            "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "C:\\Windows\\SysWOW64\\WindowsPowerShell\\v1.0\\powershell.exe",
            "powershell.exe" // Try again
        ];
        
        for (path in possiblePaths) {
            if (sys.FileSystem.exists(path)) {
                trace("Found PowerShell at: " + path);
                return path;
            }
        }
        
        trace("Warning: PowerShell not found. Some checks will be limited.");
        return "powershell.exe"; // Will fail but we handle it
    }

	static function createNamedPipe():String {
		#if windows
		// Windows: Use a simpler approach with a Python script or direct C++ approach
		// Let's use a different approach - create a temporary file and use it as a pipe
		// Actually, let's use a different method: use FFmpeg's pipe protocol directly
		
		// Create a unique pipe name
		var pipeName = 'ffmpeg_pipe_' + Std.string(haxe.Timer.stamp()).replace('.', '_');
		var pipeFullName = '\\\\.\\pipe\\' + pipeName;
		
		// For Windows, we'll use a different approach - let FFmpeg read from stdin directly
		// But if we want named pipes, we need to create a helper executable
		// Since we can't easily create named pipe servers in Haxe, let's use a workaround:
		
		// Option 1: Use FFmpeg's "pipe:" protocol with a custom named pipe (less reliable)
		// Option 2: Stick with stdin but improve buffering
		// Option 3: Use a temporary file as a circular buffer
		
		// For now, let's implement Option 3 for better performance
		var tempFile = 'temp_video_pipe_' + Std.string(haxe.Timer.stamp()).replace('.', '_') + '.raw';
		pipePath = tempFile;
		Sys.println('Rendering Mode System - Created temporary file pipe: ' + pipePath);
		return pipePath;
		
		#elseif android
		// Android: Use app's data directory
		var pipePath = '/data/data/' + Application.current.meta.get('packageName') + '/files/ffmpeg_pipe';
		var result = Sys.command('mkfifo', [pipePath]);
		if (result == 0) {
			this.pipePath = pipePath;
			Sys.println('Rendering Mode System - Created Android named pipe: ' + pipePath);
			return pipePath;
		} else {
			throw 'Failed to create named pipe on Android';
		}
		
		#else
		// Linux/macOS/Unix: Use mkfifo
		var pipePath = Sys.getCwd() + '/ffmpeg_pipe_' + Std.string(haxe.Timer.stamp()).replace('.', '_');
		var result = Sys.command('mkfifo', [pipePath]);
		if (result == 0) {
			this.pipePath = pipePath;
			Sys.println('Rendering Mode System - Created Unix named pipe: ' + pipePath);
			return pipePath;
		} else {
			// Fallback to temp directory if current dir fails
			pipePath = '/tmp/ffmpeg_pipe_' + Std.string(haxe.Timer.stamp()).replace('.', '_');
			result = Sys.command('mkfifo', [pipePath]);
			if (result == 0) {
				this.pipePath = pipePath;
				Sys.println('Rendering Mode System - Created Unix named pipe in /tmp: ' + pipePath);
				return pipePath;
			} else {
				throw 'Failed to create named pipe on Unix system';
			}
		}
		#end
	}

	static function cleanupNamedPipe() {
		if (pipePath != null) {
			try {
				#if windows
				// Windows: Delete temporary file
				if (FileSystem.exists(pipePath)) {
					FileSystem.deleteFile(pipePath);
					Sys.println('Rendering Mode System - Cleaned up temporary file: ' + pipePath);
				}
				#else
				// Unix/Linux/Android: Delete the pipe file
				if (FileSystem.exists(pipePath)) {
					FileSystem.deleteFile(pipePath);
					Sys.println('Rendering Mode System - Cleaned up named pipe: ' + pipePath);
				}
				#end
			} catch (e:Dynamic) {
				// Ignore cleanup errors
			}
			pipePath = null;
		}
		
		#if windows
		// Kill PowerShell pipe server if it exists
		if (pipeServer != null) {
			try {
				pipeServer.kill();
				pipeServer.close();
			} catch (e:Dynamic) {
				// Ignore
			}
			pipeServer = null;
		}
		#end
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

		Sys.println("Rendering Mode System - Setting up video pipe...");

		// Create pipe or temporary file
		var pipePath = createNamedPipe();

		Sys.println("Rendering Mode System - Done. Now let's initialize the real stuff!");

		// Choose the input method based on platform
		var inputSource:String;
		#if windows
		// On Windows, use the original stdin method for reliability
		// But we can use a memory buffer approach
		inputSource = '-';
		#else
		// On Unix systems, use the named pipe
		inputSource = pipePath;
		#end

		var args = [
			'-y',
			'-f', 'rawvideo',
			'-pix_fmt', 'rgba',
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r', '60',
			'-i', inputSource,  // Use appropriate input source
			'-vf', 'vflip'
		];

		args = args.concat(encoderSettings);

		args = args.concat([
			'-colorspace', 'bt709',
			'-pix_fmt', 'yuv420p',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		Sys.println("Rendering Mode System - Starting FFmpeg process...");

		// Start FFmpeg process
		process = new Process('ffmpeg', args);
		
		// For Unix systems, we need to open the pipe
		#if !windows
		if (pipePath != null && pipePath.startsWith('/')) {
			// Open the pipe for writing
			try {
				pipeOutput = sys.io.File.write(pipePath, false);
				Sys.println('Rendering Mode System - Opened Unix pipe for writing');
			} catch (e:Dynamic) {
				Sys.println('Rendering Mode System - Error opening pipe: $e');
			}
		}
		#end

		Sys.println("Rendering Mode System - Done.");

		renderTime = haxe.Timer.stamp();
		started = true;
		Sys.println("Rendering Mode System - Started!");
	}

	static var bytes:haxe.io.UInt8Array;
	static var pipeOutput:sys.io.FileOutput = null;
	static var frameCount:Int = 0;
	
	static function pipeFrame()
	{
		if (!enabled || !started || !ffmpegExists || process == null)
			return;

		try {
			if (bytes == null) {
				bytes = new haxe.io.UInt8Array(Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4);
			}

			// Read pixels
			Main.current.peoteView.gl.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, bytes);
			
			// Write frame data
			#if windows
			// Windows: Write directly to FFmpeg's stdin
			if (process.stdin != null) {
				process.stdin.writeFullBytes(untyped bytes.bytes, 0, bytes.length);
				process.stdin.flush();
			}
			#else
			// Unix/Linux/Android: Write to the named pipe
			if (pipeOutput != null) {
				pipeOutput.writeFullBytes(untyped bytes.bytes, 0, bytes.length);
				pipeOutput.flush();
			}
			#end
			
			frameCount++;
			if (frameCount % 60 == 0) {
				Sys.println('Rendering Mode System - Processed $frameCount frames');
			}
			
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

		// Close pipe output (Unix systems)
		#if !windows
		if (pipeOutput != null) {
			try {
				pipeOutput.close();
			} catch (e:Dynamic) {
				// Ignore close errors
			}
			pipeOutput = null;
		}
		#end

		// Close stdin (Windows)
		#if windows
		if (process != null && process.stdin != null) {
			try {
				process.stdin.close();
			} catch (e:Dynamic) {
				// Ignore close errors
			}
		}
		#end

		// Wait a moment for FFmpeg to finish reading
		Sys.sleep(0.1);

		// Kill FFmpeg process
		if (process != null) {
			try {
				process.close();
				process.kill();
			} catch (e:Dynamic) {
				// Ignore kill errors
			}
		}

		// Clean up named pipe/temporary file
		cleanupNamedPipe();

		// Reset frame rate
		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end

		renderTime = haxe.Timer.stamp() - renderTime;
		var fps = frameCount / renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in just ${Tools.formatTime(renderTime * 1000)}. Average FPS: ${Math.round(fps)}');
	}
}