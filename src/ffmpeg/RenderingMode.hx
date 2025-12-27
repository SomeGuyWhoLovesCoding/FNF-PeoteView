package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import sys.thread.Thread;
#if cpp
import cpp.Pointer;
import cpp.RawPointer;
import cpp.NativeProcess;
#end

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
	private static var cleanupLock:Bool = false;

	#if cpp
	private static var nativeProcessHandle:Dynamic = null;
	#end

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

		// This was a bit slower anyway so why bother doing it in the first place.
		// wasting so much time on something that I found only used more computational power. god damnit.
		/*#if FV_LIME_FORK
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
		#end*/
		
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
			Sys.println('Writer thread started');
			
			#if cpp
			// Get native process handle
			if (nativeProcessHandle != null) {
				Sys.println("Using direct NativeProcess.process_stdin_write() for maximum speed!");
			}
			#end
			
			var batchSize = 8; // Write 8 frames at once
			var batch:Array<Bytes> = [];
			
			while (!stopRequested) {
				// Collect batch
				while (batch.length < batchSize) {
					var frame = dequeueFrame();
					if (frame == null) break;
					batch.push(frame);
				}
				
				if (batch.length == 0) {
					if (stopRequested) break;
					Sys.sleep(0.0003);
					continue;
				}
				
				// Write entire batch directly
				try {
					#if cpp
					if (nativeProcessHandle != null) {
						// Direct native write - FASTEST!
						for (frame in batch) {
							var written = NativeProcess.process_stdin_write(
								nativeProcessHandle, 
								frame.getData(), 
								0, 
								frame.length
							);
							if (written != frame.length) {
								Sys.println("Incomplete write: " + written + "/" + frame.length);
							}
						}
					} else
					#end
					{
						// Fallback to normal write
						if (process != null && process.stdin != null) {
							for (frame in batch) {
								process.stdin.write(frame);
							}
							process.stdin.flush();
						}
					}
				} catch (e:Dynamic) {
					var err = Std.string(e);
					if (err.indexOf("EOF") != -1 || err.indexOf("Broken pipe") != -1) {
						Sys.println("FFmpeg pipe closed, stopping writer");
						break;
					}
				}
				
				// Return frames
				for (frame in batch) returnFrame(frame);
				batch = [];
			}
			
			Sys.println('Writer thread exiting');
		});
	}

	// ---------------- Pipe Frame (MAIN THREAD ONLY) ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || process == null || stopRequested) return;

		var buffer = getFreeFrame();
		if (buffer == null) return;

		if (pbos.length == PBO_BUFFERS) {
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
			{name:'h264_nvenc', args:[
				'-c:v','h264_nvenc',
				'-preset','p1',
				'-tune','ull',
				'-rc','constqp',
				'-qp','32',
				'-2pass','0',
				'-spatial-aq','0',
				'-temporal-aq','0',
				'-b_ref_mode','disabled',
				'-multipass','disabled'
			]},
			
			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','32',
				'-qp_p','32',
				'-preanalysis','false'
			]},
			
			{name:'h264_qsv', args:[
				'-c:v','h264_qsv',
				'-preset','veryfast',
				'-global_quality','32',
				'-async_depth','4'
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
			'-bufsize','1M','-thread_queue_size','256',
			'-max_muxing_queue_size','1024',
			'-fflags','+genpts+flush_packets',
		].concat(encoderSettings).concat([
			'-an',
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
		
		stopRequested = true;
		started = false;
		
		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in ${Tools.formatTime(renderTime*1000,true)}.');

		if (writerThread != null) {
			Sys.println("Waiting for writer thread to finish...");
			var startWait = haxe.Timer.stamp();
			while (frameQueue.length > 0 && (haxe.Timer.stamp() - startWait) < 5.0) {
				Sys.sleep(0.01);
			}
			Sys.println("Writer thread queue drained");
			Sys.sleep(0.1);
			writerThread = null;
		}

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