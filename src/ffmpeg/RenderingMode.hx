package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import sys.thread.Thread;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 2;
	static final QUEUE_SIZE:Int = 3;

	static var pbos:Array<GLBuffer> = [];
	static var pboIndex:Int = 0;
	static var pboTarget:Int = 0;
	static var frameSize:Int = 0;
	static var useBufferStorage:Bool = false;

	private static var ffmpegExists(default, null):Bool;
	static var process:Process;
	static var enabled:Bool = true;
	static var started:Bool = false;
	static var songName:String;
	static var renderTime(default, null):Float;
	static var frameRate:Float = 60;

	// ---------------- Frame Pool & Queue ----------------
	private static var freeList:Array<Bytes> = [];
	private static var frameQueue:Array<Bytes> = [];

	private static var writerThread:Thread;
	private static var stopRequested:Bool = false;
	private static var cleanupLock:Bool = false; // ADD: Prevent concurrent cleanup

	// ------------------ PBOs ------------------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;

		freeList = [];
		frameQueue = [];

		for (i in 0...QUEUE_SIZE) {
			var b = Bytes.alloc(frameSize);
			freeList.push(b);
		}

		pbos = [];
		pboTarget = 0x88EB;
		
		useBufferStorage = false;
		#if FV_LIME_FORK
		#if (cpp || hl)
		try {
			var testBuf = GL.createBuffer();
			GL.bindBuffer(pboTarget, testBuf);
			GL.bufferStorage(pboTarget, 16, cast null, 0x0001 | 0x0002 | 0x0040 | 0x0080);
			GL.deleteBuffer(testBuf);
			useBufferStorage = true;
			Sys.println("Rendering Mode System - Using GL.bufferStorage");
		} catch (e:Dynamic) {
			Sys.println("Rendering Mode System - Using traditional bufferData");
		}
		#end
		#end
		
		for (i in 0...PBO_BUFFERS) {
			var buf = GL.createBuffer();
			GL.bindBuffer(pboTarget, buf);
			
			if (useBufferStorage) {
				GL.bufferStorage(pboTarget, frameSize, cast null, 0x0001 | 0x0002 | 0x0040 | 0x0080);
			} else {
				GL.bufferData(pboTarget, frameSize, cast null, 0x88E2);
			}
			pbos.push(buf);
		}
		GL.bindBuffer(pboTarget, null);
		
		GL.pixelStorei(GL.PACK_ALIGNMENT, 4);
		
		Sys.println("Rendering Mode System - PBOs initialized successfully.");
	}

	// ---------------- Frame Pool ----------------
	static inline function getFreeFrame():Bytes {
		if (freeList.length > 0) return freeList.pop();
		return Bytes.alloc(frameSize);
	}

	static inline function returnFrame(frame:Bytes) {
		if (frame != null) freeList.push(frame);
	}

	// ---------------- Queue ----------------
	static inline function enqueueFrame(frame:Bytes) {
		frameQueue.push(frame);
	}

	static inline function dequeueFrame():Bytes {
		if (frameQueue.length > 0) return frameQueue.shift();
		return null;
	}

	// ---------------- Writer Thread ----------------
	static function acquireWriter() {
		if (writerThread != null) return;
		writerThread = Thread.create(function() {
			var threadId = 0;
			Sys.println('Writer thread started (ID: $threadId)');
			
			while (!stopRequested) {
				var frame = dequeueFrame();
				if (frame == null) {
					if (stopRequested) break;
					Sys.sleep(0.001);
					continue;
				}
				try {
					if (process != null && process.stdin != null) {
						process.stdin.write(frame);
					}
				} catch (e:Dynamic) {
					var err = Std.string(e);
					if (err.indexOf("EOF") != -1 || err.indexOf("Broken pipe") != -1) {
						Sys.println("FFmpeg pipe closed, stopping writer");
						break;
					}
				}
				returnFrame(frame);
			}
			
			// Drain remaining frames if any
			while (frameQueue.length > 0 && !cleanupLock) {
				var frame = dequeueFrame();
				if (frame != null) returnFrame(frame);
			}
			
			Sys.println('Writer thread exiting (ID: $threadId)');
		});
	}

	// ---------------- Pipe Frame (MAIN THREAD ONLY) ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || process == null || stopRequested) return;

		var buffer = getFreeFrame();
		if (buffer == null) return;

		if (pbos.length == PBO_BUFFERS) {
			// Read from previous frame (1 frame latency instead of 3)
			var readIndex = (pboIndex + 1) % PBO_BUFFERS;
			var writePBO = pbos[pboIndex];

			GL.bindBuffer(pboTarget, writePBO);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, cast 0);

			var readPBO = pbos[readIndex];
			GL.bindBuffer(pboTarget, readPBO);
			try {
				GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
				GL.bindBuffer(pboTarget, null);
				enqueueFrame(buffer);
			} catch (e:Dynamic) {
				Sys.println("PBO read failed: " + e);
				GL.bindBuffer(pboTarget, null);
				returnFrame(buffer);
				return;
			}

			pboIndex = (pboIndex + 1) % PBO_BUFFERS;
		} else {
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, buffer);
			enqueueFrame(buffer);
		}

		if (writerThread == null) acquireWriter();
	}

	// ------------------ Encoder ------------------
	static function getBestEncoder():Array<String> {
		var encoders = [
			// NVENC - Absolute fastest settings
			{name:'h264_nvenc', args:[
				'-c:v','h264_nvenc',
				'-preset','p1',           // Fastest preset
				'-tune','ull',            // Ultra low latency
				'-rc','constqp',          // Constant QP (faster than VBR)
				'-qp','28',               // Quality level
				'-2pass','0',             // Disable 2-pass
				'-spatial-aq','0',        // Disable spatial AQ
				'-temporal-aq','0',       // Disable temporal AQ
				'-b_ref_mode','disabled', // Disable B-frame references
				'-multipass','disabled'   // Disable multipass
			]},
			
			// AMF - Speed priority
			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','28',
				'-qp_p','28',
				'-preanalysis','false'
			]},
			
			// QSV - Fastest
			{name:'h264_qsv', args:[
				'-c:v','h264_qsv',
				'-preset','veryfast',
				'-global_quality','28',
				'-look_ahead','0',
				'-async_depth','2'  // Reduced from 7
			]}
		];

		for (encoder in encoders) {
			var testProcess = new Process('ffmpeg', [
				'-f','lavfi','-v','quiet','-i','color=black:s=64x64:d=0.1',
				'-c:v',encoder.name,'-f','null','-'
			]);
			var stderr = testProcess.stderr.readAll().toString();
			var exitCode = testProcess.exitCode();
			if (stderr.indexOf('Conversion failed!') == -1 && exitCode == 0) {
				Sys.println('Rendering Mode System - Using encoder: ${encoder.name}');
				return encoder.args;
			}
		}

		Sys.println('Rendering Mode System - Using encoder: libx264 (software fallback)');
		return [
			'-c:v','libx264',
			'-preset','ultrafast',
			'-crf','28',
			'-tune','zerolatency',
			'-x264-params','rc-lookahead=0:ref=1:bframes=0:me=dia:subq=0:trellis=0:weightp=0'
		];
	}

	// ------------------ Init Render ------------------
	static function initRender() {
		var ffmpeg = "ffmpeg";
		#if windows ffmpeg += ".exe"; #end
		if (!FileSystem.exists(ffmpeg)) throw '$ffmpeg not found!';
		if (!FileSystem.exists('assets/videos/rendered/')) FileSystem.createDirectory('assets/videos/rendered');

		ffmpegExists = true;
		songName = Chart.header.title;

		Application.current.window.resizable = false;
		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = true;
		#else
		Application.current.window.frameRate = 1000;
		#end

		var encoderSettings = getBestEncoder();
		var args = [
			'-y','-f','rawvideo','-pix_fmt','bgra',
			'-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r',Std.string(frameRate),'-i','-',
			'-vf','vflip',
			'-bufsize','2M','-threads','0','-thread_queue_size','512'
		].concat(encoderSettings).concat([
			'-colorspace','bt709',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		process = new Process('ffmpeg', args);
		stopRequested = false;
		cleanupLock = false;

		initPBOs();

		started = true;
		renderTime = haxe.Timer.stamp();
		Sys.println("Rendering Mode System - Started!");
	}

	// ------------------ Stop Render ------------------
	static function stopRender() {
		if (!started || cleanupLock) return;
		cleanupLock = true;
		
		Sys.println("StopRender called - beginning cleanup...");
		
		// Step 1: Signal stop
		stopRequested = true;
		started = false;
		
		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in ${Tools.formatTime(renderTime*1000,true)}.');

		// Step 2: Wait for writer thread to finish
		if (writerThread != null) {
			Sys.println("Waiting for writer thread to finish...");
			var startWait = haxe.Timer.stamp();
			// Give it a reasonable timeout (5 seconds)
			while (frameQueue.length > 0 && (haxe.Timer.stamp() - startWait) < 5.0) {
				Sys.sleep(0.01);
			}
			Sys.println("Writer thread queue drained");
			// Small delay to ensure thread exits cleanly
			Sys.sleep(0.1);
			writerThread = null;
		}

		// Step 3: Close ffmpeg stdin
		Sys.println("Closing ffmpeg stdin...");
		if (process != null) {
			try {
				if (process.stdin != null) {
					process.stdin.close();
					Sys.println("stdin closed");
				}
			} catch (e:Dynamic) {
				Sys.println("Error closing stdin: " + e);
			}

			Sys.println("FFmpeg close...");
			process.close();
			process.kill();
			Sys.println("FFmpeg exited with code: " + process.exitCode());
			
			process = null;
		}

		// Rest of cleanup...
		Sys.println("Cleaning up GL resources...");
		for (pbo in pbos) {
			try {
				GL.deleteBuffer(pbo);
			} catch (e:Dynamic) {}
		}
		pbos = [];
		
		freeList = [];
		frameQueue = [];
		
		GL.pixelStorei(GL.PACK_ALIGNMENT, 4);

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end
		Application.current.window.resizable = true;
		
		cleanupLock = false;
		
		Sys.println("Rendering Mode System - Cleanup complete!");
	}
}