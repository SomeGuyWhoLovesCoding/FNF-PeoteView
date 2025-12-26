package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.utils.UInt8Array;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 4; // Triple buffering for better pipeline utilization
	
	static var pbos:Array<GLBuffer> = [];
	static var pboIndex:Int = 0;
	static var pboTarget:Int = 0;
	static var frameSize:Int = 0;
	static var dataBuffer:Bytes; // Reuse buffer to avoid allocations
	
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;
		
		// Pre-allocate reusable buffer
		dataBuffer = Bytes.alloc(frameSize);
		
		// Determine the correct PBO target based on OpenGL version
		#if (lime >= "8.0.0")
		var glVersion = GL.getParameter(GL.VERSION);
		pboTarget = 0x88EB; // GL_PIXEL_PACK_BUFFER
		#else
		pboTarget = 0x88EB;
		#end
		
		if (pboTarget != 0) {
			Sys.println('Rendering Mode System - Initializing ${PBO_BUFFERS} PBOs for triple buffering...');
			
			for (i in 0...PBO_BUFFERS) {
				pbos[i] = GL.createBuffer();
				GL.bindBuffer(pboTarget, pbos[i]);
				// Use STREAM_READ for CPU reads, consider STREAM_COPY if staying on GPU
				GL.bufferData(pboTarget, frameSize, cast null, GL.STREAM_COPY);
			}
			
			GL.bindBuffer(pboTarget, null);
			Sys.println('Rendering Mode System - PBOs initialized successfully');
		} else {
			Sys.println('Rendering Mode System - PBOs not supported, using direct readPixels');
		}
	}

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
				'-preset', 'p1',
				'-tune', 'ull',
				'-b:v', '3M',
				'-maxrate', '4M',
				'-bufsize', '1M'
			]},
			
			// AMD AMF - fastest preset
			{name: 'h264_amf', args: [
				'-c:v', 'h264_amf',
				'-quality', 'speed',
				'-b:v', '3M',
				'-maxrate', '4M',
				'-rc', 'vbr_latency'
			]},
			
			// Intel QSV - fastest preset
			{name: 'h264_qsv', args: [
				'-c:v', 'h264_qsv',
				'-preset', 'veryfast',
				'-global_quality', '28',
				'-look_ahead', '0',
				'-b:v', '3M'
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

		Sys.println('Rendering Mode System - Using encoder: libx264 (software fallback)');
		return [
			'-c:v', 'libx264',
			'-preset', 'ultrafast',
			'-crf', '27',
			'-tune', 'zerolatency',
			'-x264-params', 'ref=1:bframes=0:me=dia:subq=1:trellis=0'
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
			'-pix_fmt', 'bgra',
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r', Std.string(frameRate),
			'-i', '-',
			'-vf', 'vflip,format=nv12',
			'-fflags', 'nobuffer',
			'-flags', 'low_delay',
			'-bufsize', '8M',  // Larger buffer
			'-threads', '0',    // Use all CPU cores
			'-thread_queue_size', '512'
		];

		args = args.concat(encoderSettings);

		args = args.concat([
			'-colorspace', 'bt709',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		Sys.println("Rendering Mode System - Almost there. Just need to execute the process just like that...");

		process = new Process('ffmpeg', args);

		Sys.println("Rendering Mode System - Done.");

		initPBOs();

		renderTime = haxe.Timer.stamp();
		started = true;
		Sys.println("Rendering Mode System - Started!");
	}

	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || process == null)
			return;
		
		if (pboTarget != 0 && pbos.length == PBO_BUFFERS) {
			// Triple-buffered PBO readback for maximum throughput
			// Buffer 0: Currently being read by CPU
			// Buffer 1: Being filled by GPU (this frame)
			// Buffer 2: Ready to read (from 2 frames ago)
			
			var readPBO = pbos[pboIndex];
			var writePBO = pbos[(pboIndex + 2) % PBO_BUFFERS];
			
			// Start async GPU read into writePBO for this frame
			GL.bindBuffer(pboTarget, writePBO);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, cast 0);
			
			// Read from readPBO (data from 2 frames ago, should be ready now)
			GL.bindBuffer(pboTarget, readPBO);
			
			#if (cpp || hl)
			try {
				// Reuse pre-allocated buffer to avoid GC pressure
				GL.getBufferSubData(pboTarget, 0, frameSize, dataBuffer);
				
				// Write directly without creating intermediate Bytes object if possible
				var bytes:haxe.io.Bytes = dataBuffer;
				//Sys.println(bytes);
				if (bytes != null) process.stdin.write(bytes);
			} catch (e:Dynamic) {
				Sys.println('Rendering Mode System - Warning: getBufferSubData failed, disabling PBOs\nVideo is now corrupted');
				pboTarget = 0;
			}
			#else
			Sys.println('Rendering Mode System - Warning: PBO readback not implemented for this platform');
			pboTarget = 0;
			#end
			
			GL.bindBuffer(pboTarget, null);
			
			// Advance to next buffer in ring
			pboIndex = (pboIndex + 1) % PBO_BUFFERS;
		} else {
			// Fallback: direct synchronous readPixels (blocks GPU pipeline)
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, dataBuffer);
			process.stdin.write(dataBuffer);
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
		
		// Clean up PBOs
		if (pbos.length > 0) {
			for (pbo in pbos) {
				GL.deleteBuffer(pbo);
			}
			pbos = [];
		}
		
		// Clear reusable buffer
		dataBuffer = null;

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in just ${Tools.formatTime(renderTime * 1000)}.');
	}
}