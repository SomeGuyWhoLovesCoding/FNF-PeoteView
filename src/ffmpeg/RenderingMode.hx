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
	static final PBO_BUFFERS:Int = 5;
	static final QUEUE_SIZE:Int = 16;

	static var pbos:Array<GLBuffer> = [];
	static var pboIndex:Int = 0;
	static var pboTarget:Int = 0;
	static var frameSize:Int = 0;

	private static var ffmpegExists(default, null):Bool;
	static var process:Process;
	static var enabled:Bool = false;
	static var started:Bool = false;
	static var songName:String;
	static var renderTime(default, null):Float;
	static var frameRate:Float = 60;

	// ---------------- Frame Pool & Queue ----------------
	private static var freeList:Array<Bytes> = [];
	private static var frameQueue:Array<Bytes> = [];
	// Both freeList and frameQueue are touched from two threads —
	// they each need their own mutex.
	private static var freeListMutex:sys.thread.Mutex = new sys.thread.Mutex();
	private static var queueMutex:sys.thread.Mutex = new sys.thread.Mutex();

	private static var writerThread:Thread;
	private static var stopRequested:Bool = false;
	private static var cleanupLock:Bool = false;

	#if cpp
	private static var nativeProcessHandle:Dynamic = null;
	#end

	// ------------------ PBOs ------------------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;

		freeListMutex.acquire();
		freeList = [];
		freeListMutex.release();

		queueMutex.acquire();
		frameQueue = [];
		queueMutex.release();

		for (i in 0...QUEUE_SIZE) {
			freeList.push(Bytes.alloc(frameSize));
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

		Sys.println("            vvvvvvvvv\n  [ Rendering Mode System ]   PBOs initialized successfully.");
	}

	// ---------------- Frame Pool ----------------
	// Returns null when pool is empty — callers must drop the frame rather than allocate.
	// Allocating on exhaustion is what caused the original memory leak.
	static inline function getFreeFrame():Null<Bytes> {
		freeListMutex.acquire();
		var frame = if (freeList.length > 0) freeList.pop() else null;
		freeListMutex.release();
		return frame;
	}

	static inline function returnFrame(frame:Bytes) {
		if (frame == null) return;
		freeListMutex.acquire();
		if (freeList.length < QUEUE_SIZE)
			freeList.push(frame);
		freeListMutex.release();
	}

	// ---------------- Queue ----------------
	static inline function enqueueFrame(frame:Bytes) {
		queueMutex.acquire();
		frameQueue.push(frame);
		queueMutex.release();
	}

	static inline function dequeueFrame():Null<Bytes> {
		queueMutex.acquire();
		var frame = if (frameQueue.length > 0) frameQueue.shift() else null;
		queueMutex.release();
		return frame;
	}

	static inline function queueLength():Int {
		queueMutex.acquire();
		var len = frameQueue.length;
		queueMutex.release();
		return len;
	}

	// ---------------- Writer Thread ----------------
	static function acquireWriter() {
		if (writerThread != null) return;
		writerThread = Thread.create(function() {
			Sys.println('Writer thread started');

			#if cpp
			if (nativeProcessHandle != null)
				Sys.println("Using NativeProcess.process_stdin_write()");
			#end

			var batchSize = 16;
			var batch:Array<Bytes> = [];
			var batchBuffer:Bytes = null;

			while (!stopRequested) {
				// Collect a batch from the mutex-guarded queue
				while (batch.length < batchSize) {
					var frame = dequeueFrame();
					if (frame == null) break;
					batch.push(frame);
				}

				if (batch.length == 0) {
					Sys.sleep(0.0003);
					continue;
				}

				var totalSize = 0;
				for (frame in batch) totalSize += frame.length;

				if (batchBuffer == null || batchBuffer.length < totalSize)
					batchBuffer = Bytes.alloc(totalSize);

				var offset = 0;
				for (frame in batch) {
					batchBuffer.blit(offset, frame, 0, frame.length);
					offset += frame.length;
				}

				try {
					#if cpp
					if (nativeProcessHandle != null) {
						var written = NativeProcess.process_stdin_write(
							nativeProcessHandle,
							batchBuffer.getData(),
							0,
							totalSize
						);
						if (written != totalSize)
							Sys.println("Incomplete write: " + written + "/" + totalSize);
					} else
					#end
					{
						if (process != null && process.stdin != null) {
							process.stdin.writeBytes(batchBuffer, 0, totalSize);
							process.stdin.flush();
						}
					}
				} catch (e:Dynamic) {
					var err = Std.string(e);
					if (err.indexOf("EOF") != -1 || err.indexOf("Broken pipe") != -1) {
						Sys.println("FFmpeg pipe closed, stopping writer");
						for (frame in batch) returnFrame(frame);
						batch = [];
						break;
					}
				}

				for (frame in batch) returnFrame(frame);
				batch = [];
			}

			// Drain any remaining frames on exit so pool stays intact
			var leftover = dequeueFrame();
			while (leftover != null) {
				returnFrame(leftover);
				leftover = dequeueFrame();
			}

			Sys.println('Writer thread exiting');
		});
	}

	// ---------------- Pipe Frame (MAIN THREAD ONLY) ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || process == null || stopRequested) return;

		// Start writer before enqueueing so it's always ready to consume
		if (writerThread == null) acquireWriter();

		var buffer = getFreeFrame();
		if (buffer == null) {
			Sys.println("[ Rendering Mode System ]   Frame pool exhausted, dropping frame");
			return;
		}

		if (pbos.length == PBO_BUFFERS/* && !PeoteGL.Version.isES3 /* Doesn't work on ES3/. sad. */) {
			var readIndex = (pboIndex + 1) % PBO_BUFFERS;
			var writePBO = pbos[pboIndex];

			GL.bindBuffer(pboTarget, writePBO);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGB, GL.UNSIGNED_SHORT_5_6_5, cast null);

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
			// Warmup — PBOs not yet fully filled
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
			enqueueFrame(buffer);
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
				Sys.println('            vvvvvvvvv\n  [ Rendering Mode System ]   Using encoder: ${encoder.name}\n');
				return encoder.args;
			}
		}

		Sys.println('            vvvvvvvvv\n  [ Rendering Mode System ]   Using encoder: libx264 (software fallback)\n');
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
			'-y','-f','rawvideo','-pix_fmt','rgb565',
			'-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
			'-r',Std.string(frameRate),'-i','-',
			'-vf','vflip',
			'-bufsize','1M','-thread_queue_size','1024',
			'-max_muxing_queue_size','4096',
			'-nostats',
			'-loglevel','quiet',
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

		#if cpp
		nativeProcessHandle = untyped process?.stdin?.p;
		#end

		initPBOs();

		started = true;
		renderTime = haxe.Timer.stamp();
		Sys.println("            vvvvvvvvv\n  [ Rendering Mode System ]   Started!");
	}

	// ------------------ Stop Render ------------------
	static function stopRender() {
		if (!started || cleanupLock) return;
		cleanupLock = true;

		Sys.println("StopRender called - beginning cleanup...");

		stopRequested = true;
		started = false;

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('            vvvvvvvvv\n  [ Rendering Mode System ]   Finished Rendering in ${Tools.formatTime(renderTime*1000,true)}.');

		if (writerThread != null) {
			Sys.println("Waiting for writer thread to finish...");
			var startWait = haxe.Timer.stamp();
			// Wait for queue to drain, but cap at 5s
			while (queueLength() > 0 && (haxe.Timer.stamp() - startWait) < 5.0) {
				Sys.sleep(0.01);
			}
			if (queueLength() > 0)
				Sys.println("Warning: " + queueLength() + " frames still in queue at shutdown");
			Sys.sleep(0.1); // let writer finish its current batch write
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
			try { GL.deleteBuffer(pbo); } catch (e:Dynamic) {}
		}
		pbos = [];

		freeListMutex.acquire();
		freeList = [];
		freeListMutex.release();

		queueMutex.acquire();
		frameQueue = [];
		queueMutex.release();

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.state.graphics.frameRate;
		#end
		Application.current.window.resizable = true;

		cleanupLock = false;

		Sys.println("            vvvvvvvvv\n  [ Rendering Mode System ]   Cleanup complete!");
	}
}
