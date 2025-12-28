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
import ffmpeg.NamedPipeWriter;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 5;
	static final QUEUE_SIZE:Int = 8;

	static var pbos:Array<GLBuffer> = [];
	static var pboIndex:Int = 0;
	static var pboTarget:Int = 0;
	static var frameSize:Int = 0;

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

	// ---------------- EXPERIMENTAL! ----------------
	static var useNamedPipe:Bool = true; 

	// ------------------ PBOs ------------------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;

		freeList = [];
		frameQueue = [];

		for (i in 0...QUEUE_SIZE) {
			var b = Bytes.alloc(frameSize);
			freeList.push(b);
		}

		pbos = [];
		pboTarget = 0x88EB;
		
		for (i in 0...PBO_BUFFERS) {
			var buf = GL.createBuffer();
			GL.bindBuffer(pboTarget, buf);
			
			GL.bufferData(pboTarget, frameSize, cast null, 0x88E2);
			pbos.push(buf);
		}
		GL.bindBuffer(pboTarget, null);
		
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
			
			var batchSize = 16; // Write 16 frames at once
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

		var buffer:Bytes;
		
		if (useNamedPipe) {
			buffer = NamedPipeWriter.getFreeFrame();
			if (buffer == null) return; // Queue full
		} else {
			buffer = getFreeFrame();
			if (buffer == null) return;
		}

		if (pbos.length == PBO_BUFFERS) {
			var readIndex = (pboIndex + 1) % PBO_BUFFERS;
			var writePBO = pbos[pboIndex];

			GL.bindBuffer(pboTarget, writePBO);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGB, GL.UNSIGNED_SHORT_5_6_5, cast null);

			var readPBO = pbos[readIndex];
			GL.bindBuffer(pboTarget, readPBO);
			try {
				GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
				GL.bindBuffer(pboTarget, null);
				
				if (useNamedPipe) {
					NamedPipeWriter.enqueueFrame(buffer);
				} else {
					enqueueFrame(buffer);
				}
			} catch (e:Dynamic) {
				Sys.println("PBO read failed: " + e);
				GL.bindBuffer(pboTarget, null);
				
				if (useNamedPipe) {
					NamedPipeWriter.returnFrame(buffer);
				} else {
					returnFrame(buffer);
				}
				return;
			}

			pboIndex = (pboIndex + 1) % PBO_BUFFERS;
		} else {
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
			
			if (useNamedPipe) {
				NamedPipeWriter.enqueueFrame(buffer);
			} else {
				enqueueFrame(buffer);
			}
		}

		// Only start stdin writer thread if not using named pipe
		if (!useNamedPipe && writerThread == null) {
			acquireWriter();
		}
	}

	// ------------------ Encoder ------------------
	static function getBestEncoder():Array<String> {
		var encoders = [
			{name:'h264_nvenc', args:[
				'-c:v','h264_nvenc',
				'-preset','p1',
				'-tune','ull',
				'-rc','constqp',
				'-qp','31',
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
				'-qp_i','31',
				'-qp_p','31',
				'-preanalysis','false'
			]},
			
			{name:'h264_qsv', args:[
				'-c:v','h264_qsv',
				'-preset','veryfast',
				'-global_quality','31',
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
		var inputSource:String;
		
		// Initialize named pipe if enabled
		if (useNamedPipe) {
			frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;
			inputSource = NamedPipeWriter.init("ffmpeg_render", frameSize, QUEUE_SIZE);
			Sys.println('Using named pipe: $inputSource');
		} else {
			inputSource = '-'; // stdin
		}
		
		var args = [
			'-y','-f','rawvideo','-pix_fmt','rgb565',
			'-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r',Std.string(frameRate),'-i',inputSource,
			'-vf','vflip',
			'-bufsize','1M','-thread_queue_size','1024',
			'-max_muxing_queue_size','4096',
			'-nostats',
			'-loglevel', 'quiet',
			'-hide_banner',
			'-xerror',
			'-avoid_negative_ts','make_zero',
			'-flags','+low_delay',
			'-strict','experimental'
		].concat(encoderSettings).concat([
			'-an',
			'-colorspace','bt709',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		process = new Process('ffmpeg', args);
		stopRequested = false;
		cleanupLock = false;

		if (!useNamedPipe) {
			#if cpp
			nativeProcessHandle = untyped process.stdin.p;
			#end
		}

		initPBOs();
		
		// Start named pipe writer after FFmpeg process is running
		if (useNamedPipe) {
			NamedPipeWriter.startWriter();
		}

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

		// Stop named pipe writer if enabled
		if (useNamedPipe) {
			NamedPipeWriter.stop();
		} else {
			// Original stdin writer cleanup
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
			}
		}

		Sys.println("FFmpeg close...");
		if (process != null) {
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
		
		if (!useNamedPipe) {
			freeList = [];
			frameQueue = [];
		}

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