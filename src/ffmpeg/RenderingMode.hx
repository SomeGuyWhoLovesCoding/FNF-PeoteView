package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import sys.thread.Thread;
import sys.thread.Mutex;
import sys.thread.Lock;
#if cpp
import cpp.Pointer;
import cpp.RawPointer;
import cpp.NativeProcess;
#end
import lime.utils.DataPointer;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 3; // Triple buffering is optimal
	static final QUEUE_SIZE:Int = 32; // Balanced queue size
	static final BATCH_SIZE:Int = 128; // Larger batches = fewer system calls
	static final MAX_QUEUE_LENGTH:Int = 48;

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
	private static var queueMutex:Mutex = new Mutex();
	private static var queueLock:Lock = new Lock();

	// ---------------- Thread Management ----------------
	private static var writerThread:Thread;
	private static var stopRequested:Bool = false;
	private static var cleanupLock:Bool = false;

	#if cpp
	private static var nativeProcessHandle:Dynamic = null;
	#end

	// ---------------- Batch Buffer Pool ----------------
	private static var batchBufferPool:Array<Bytes> = [];
	private static var batchBufferSize:Int = 0;
	private static var bufferPoolMutex:Mutex = new Mutex();

	// ---------------- Performance Monitoring ----------------
	static var framesCaptured:Int = 0;
	static var framesWritten:Int = 0;
	static var framesDropped:Int = 0;
	static var lastLogTime:Float = 0;
	static var logInterval:Float = 5.0;

	// ------------------ PBOs ------------------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;
		batchBufferSize = frameSize * BATCH_SIZE;

		queueMutex = new Mutex();
		queueLock = new Lock();
		bufferPoolMutex = new Mutex();

		freeList = [];
		frameQueue = [];

		// Pre-allocate frame pool
		for (i in 0...QUEUE_SIZE) {
			freeList.push(Bytes.alloc(frameSize));
		}

		// Pre-allocate batch buffers (4 for better pipelining)
		batchBufferPool = [];
		for (i in 0...4) {
			batchBufferPool.push(Bytes.alloc(batchBufferSize));
		}

		pbos = [];
		pboTarget = 0x88EB; // GL_PIXEL_PACK_BUFFER

		// Create PBO ring buffer
		for (i in 0...PBO_BUFFERS) {
			var buf = GL.createBuffer();
			GL.bindBuffer(pboTarget, buf);
			GL.bufferData(pboTarget, frameSize, cast null, 0x88E8); // GL_STREAM_COPY (better for GPU->CPU)
			pbos.push(buf);
		}
		GL.bindBuffer(pboTarget, null);

		Sys.println("Rendering Mode System - PBOs initialized successfully.");
		Sys.println('Frame size: ${frameSize} bytes, Batch size: ${BATCH_SIZE} frames (${Math.round(batchBufferSize/1024/1024)}MB)');
		Sys.println('Queue capacity: ${QUEUE_SIZE} frames, Max queue: ${MAX_QUEUE_LENGTH}');
	}

	// ---------------- Frame Pool (Lock-free where possible) ----------------
	static inline function getFreeFrame():Bytes {
		queueMutex.acquire();
		var frame = freeList.length > 0 ? freeList.pop() : null;
		queueMutex.release();

		// Emergency allocation (should rarely happen)
		return frame != null ? frame : Bytes.alloc(frameSize);
	}

	static inline function returnFrame(frame:Bytes) {
		if (frame != null && frame.length == frameSize) {
			queueMutex.acquire();
			if (freeList.length < QUEUE_SIZE * 2) { // Prevent unbounded growth
				freeList.push(frame);
			}
			queueMutex.release();
		}
	}

	// ---------------- Batch Buffer Pool ----------------
	static inline function getFreeBatchBuffer():Bytes {
		bufferPoolMutex.acquire();
		var buffer = batchBufferPool.length > 0 ? batchBufferPool.pop() : null;
		bufferPoolMutex.release();

		return buffer != null ? buffer : Bytes.alloc(batchBufferSize);
	}

	static inline function returnBatchBuffer(buffer:Bytes) {
		if (buffer != null && buffer.length == batchBufferSize) {
			bufferPoolMutex.acquire();
			if (batchBufferPool.length < 8) {
				batchBufferPool.push(buffer);
			}
			bufferPoolMutex.release();
		}
	}

	// ---------------- Queue with Backpressure ----------------
	static inline function enqueueFrame(frame:Bytes) {
		var shouldRelease = false;
		
		queueMutex.acquire();
		if (frameQueue.length < MAX_QUEUE_LENGTH) {
			frameQueue.push(frame);
			framesCaptured++;
			
			// Signal writer only when it was empty
			if (frameQueue.length == 1) {
				shouldRelease = true;
			}
		} else {
			// Backpressure: drop oldest frame to make room
			var dropped = frameQueue.shift();
			if (dropped != null) {
				returnFrame(dropped);
				framesDropped++;
			}
			frameQueue.push(frame);
			framesCaptured++;
		}
		queueMutex.release();
		
		if (shouldRelease) {
			queueLock.release();
		}
	}

	static inline function dequeueBatch(maxFrames:Int):Array<Bytes> {
		queueMutex.acquire();
		var batch = [];
		var count = Std.int(Math.min(maxFrames, frameQueue.length));
		
		for (i in 0...count) {
			var frame = frameQueue.shift();
			if (frame != null) batch.push(frame);
		}
		queueMutex.release();
		
		return batch;
	}

	static inline function waitForFrames(timeout:Float):Bool {
		return queueLock.wait(timeout);
	}

	// ---------------- Optimized Writer Thread ----------------
	static function acquireWriter() {
		if (writerThread != null) return;

		writerThread = Thread.create(function() {
			Sys.println('Writer thread started with batch size: ${BATCH_SIZE}');

			var batchBuffer:Bytes = null;
			var lastStatsTime = haxe.Timer.stamp();
			var statsFrames = 0;

			while (!stopRequested) {
				// Wait for work (with timeout to check stopRequested)
				queueMutex.acquire();
				var hasFrames = frameQueue.length > 0;
				queueMutex.release();
				
				if (!hasFrames) {
					if (!waitForFrames(0.001)) { // ~60fps check
						if (stopRequested) break;
						continue;
					}
				}

				// Dequeue batch
				var batch = dequeueBatch(BATCH_SIZE);
				if (batch.length == 0) {
					if (stopRequested) break;
					continue;
				}

				// Get batch buffer
				batchBuffer = getFreeBatchBuffer();
				var framesToWrite = batch.length;

				// Fast memory copy: blit all frames
				var offset = 0;
				for (frame in batch) {
					batchBuffer.blit(offset, frame, 0, frameSize);
					offset += frameSize;
				}

				// Single write operation
				var totalBytes = frameSize * framesToWrite;
				var writeSuccess = false;

				try {
					#if cpp
					if (nativeProcessHandle != null) {
						// Direct write (fastest path)
						var written = NativeProcess.process_stdin_write(
							nativeProcessHandle,
							batchBuffer.getData(),
							0,
							totalBytes
						);
						writeSuccess = (written == totalBytes);
						if (!writeSuccess) {
							Sys.println('Warning: Partial write ${written}/${totalBytes}');
						}
					} else
					#end
					{
						// Fallback
						if (process != null && process.stdin != null) {
							process.stdin.writeBytes(batchBuffer, 0, totalBytes);
							writeSuccess = true;
						}
					}

					if (writeSuccess) {
						framesWritten += framesToWrite;
						statsFrames += framesToWrite;
					}
				} catch (e:Dynamic) {
					var err = Std.string(e);
					if (err.indexOf("EOF") != -1 || err.indexOf("Broken pipe") != -1) {
						Sys.println("FFmpeg pipe closed");
						break;
					}
					Sys.println("Write error: " + err);
				}

				// Return resources
				returnBatchBuffer(batchBuffer);
				batchBuffer = null;
				for (frame in batch) returnFrame(frame);

				// Periodic stats
				var now = haxe.Timer.stamp();
				if (now - lastStatsTime >= logInterval) {
					var elapsed = now - lastStatsTime;
					var fps = statsFrames / elapsed;
					queueMutex.acquire();
					var queueLen = frameQueue.length;
					queueMutex.release();
					
					Sys.println('Writer: ${Math.round(fps)}fps | Queue: ${queueLen}/${MAX_QUEUE_LENGTH} | Dropped: ${framesDropped}');
					lastStatsTime = now;
					statsFrames = 0;
				}
			}

			// Final flush
			var remaining = dequeueBatch(QUEUE_SIZE);
			if (remaining.length > 0) {
				try {
					var tempBuffer = getFreeBatchBuffer();
					var offset = 0;
					for (frame in remaining) {
						tempBuffer.blit(offset, frame, 0, frameSize);
						offset += frameSize;
					}
					
					if (process != null && process.stdin != null) {
						process.stdin.writeBytes(tempBuffer, 0, frameSize * remaining.length);
						framesWritten += remaining.length;
					}
					
					returnBatchBuffer(tempBuffer);
					for (frame in remaining) returnFrame(frame);
				} catch (e:Dynamic) {
					Sys.println("Final flush error: " + e);
				}
			}

			if (batchBuffer != null) returnBatchBuffer(batchBuffer);
			Sys.println('Writer thread exiting. Total written: ${framesWritten}');
		});
	}

	// ---------------- Optimized PBO Pipelining ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || stopRequested) return;

		var buffer = getFreeFrame();
		if (buffer == null) return;

		if (pbos.length == PBO_BUFFERS) {
			// Proper ring buffer indexing
			var writeIndex = pboIndex;
			var readIndex = (pboIndex + 1) % PBO_BUFFERS; // Read from next buffer (completed async transfer)
			
			// Initiate async GPU->PBO transfer for current frame
			GL.bindBuffer(pboTarget, pbos[writeIndex]);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 
				GL.RGB, GL.UNSIGNED_SHORT_5_6_5, cast null);
			
			// Read from previously filled PBO (should be ready now)
			GL.bindBuffer(pboTarget, pbos[readIndex]);
			
			try {
				// Fast path: direct buffer read
				GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
				enqueueFrame(buffer);
			} catch (e:Dynamic) {
				// Fallback: synchronous read (slower but works)
				GL.bindBuffer(pboTarget, null);
				GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 
					GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
				enqueueFrame(buffer);
			}
			
			GL.bindBuffer(pboTarget, null);
			pboIndex = (pboIndex + 1) % PBO_BUFFERS; // Fixed: was +4
		} else {
			// No PBOs: direct synchronous read
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 
				GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
			enqueueFrame(buffer);
		}

		// Lazy writer thread start
		if (writerThread == null) {
			acquireWriter();
		}
	}

	// ------------------ Encoder Selection ------------------
	static function getBestEncoder():Array<String> {
		#if linux
		var linuxEncoders = [
			{name:'h264_vaapi', args:[
				'-c:v','h264_vaapi',
				'-qp','28',
				'-vaapi_device','/dev/dri/renderD128',
				'-vf','format=rgb565le,hwupload',
			]},
			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','28',
				'-qp_p','28',
			]}
		];

		for (encoder in linuxEncoders) {
			var testProcess = new Process('ffmpeg', [
				'-f','lavfi','-v','quiet','-i','color=black:s=64x64:d=0.1',
				'-c:v',encoder.name,'-f','null','-'
			]);
			if (testProcess.exitCode() == 0) {
				Sys.println('Using Linux encoder: ${encoder.name}');
				return encoder.args;
			}
		}
		#else
		var encoders = [
			{name:'h264_nvenc', args:[
				'-c:v','h264_nvenc',
				'-preset','p1',
				'-tune','ull',
				'-rc','constqp',
				'-qp','28',
				'-2pass','0',
				'-spatial-aq','0',
				'-temporal-aq','0',
				'-b_ref_mode','disabled',
				'-multipass','disabled',
				'-rc-lookahead','0',
				'-bf','0',
			]},
			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','28',
				'-qp_p','28',
			]},
			{name:'h264_qsv', args:[
				'-c:v','h264_qsv',
				'-preset','veryfast',
				'-global_quality','28',
				'-look_ahead','0',
			]}
		];

		for (encoder in encoders) {
			var testProcess = new Process('ffmpeg', [
				'-f','lavfi','-v','quiet','-i','color=black:s=64x64:d=0.1',
				'-c:v',encoder.name,'-f','null','-'
			]);
			if (testProcess.exitCode() == 0) {
				Sys.println('Using encoder: ${encoder.name}');
				return encoder.args;
			}
		}
		#end

		Sys.println('Using encoder: libx264 (software)');
		return [
			'-c:v','libx264',
			'-preset','ultrafast',
			'-crf','23',
			'-tune','zerolatency',
		];
	}

	// ------------------ Init Render ------------------
	static function initRender() {
		var ffmpeg = "ffmpeg";
		#if windows ffmpeg += ".exe"; #end

		songName = Chart.header.title;
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;

		framesCaptured = 0;
		framesWritten = 0;
		framesDropped = 0;
		lastLogTime = haxe.Timer.stamp();

		Application.current.window.resizable = false;
		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = true;
		#else
		Application.current.window.frameRate = 1000;
		#end

		if (!FileSystem.exists(ffmpeg)) throw '$ffmpeg not found!';
		if (!FileSystem.exists('assets/videos/rendered/'))
			FileSystem.createDirectory('assets/videos/rendered');

		ffmpegExists = true;

		var encoderSettings = getBestEncoder();
		var args = [
			'-y','-f','rawvideo','-pix_fmt','rgb565le',
			'-s','${Main.VARIABLE_WIDTH}x${Main.VARIABLE_HEIGHT}',
			'-r',Std.string(frameRate),'-i','-',
			'-vf','vflip',
			'-bufsize','4M',
			'-thread_queue_size','2048',
			'-max_muxing_queue_size','8192',
			'-nostats','-loglevel','warning','-hide_banner',
		].concat(encoderSettings).concat([
			'-an','-movflags','+faststart',
			'-colorspace','bt709',
			'assets/videos/rendered/${songName}.mp4'
		]);

		process = new Process('ffmpeg', args);

		#if cpp
		nativeProcessHandle = untyped process?.stdin?.p;
		#end

		stopRequested = false;
		cleanupLock = false;
		writerThread = null;

		initPBOs();

		started = true;
		renderTime = haxe.Timer.stamp();
		Sys.println("Rendering started!");
	}

	// ------------------ Stop Render ------------------
	static function stopRender() {
		if (!started || cleanupLock) return;
		cleanupLock = true;

		Sys.println("Stopping render...");
		stopRequested = true;
		started = false;

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Finished in ${Tools.formatTime(renderTime*1000,true)}');
		Sys.println('Stats: ${framesCaptured} captured, ${framesWritten} written, ${framesDropped} dropped');

		// Wake writer thread
		queueLock.release();

		// Wait for queue drain (max 10 seconds)
		if (writerThread != null) {
			var waitStart = haxe.Timer.stamp();
			while ((haxe.Timer.stamp() - waitStart) < 10.0) {
				queueMutex.acquire();
				var empty = frameQueue.length == 0;
				queueMutex.release();
				if (empty) break;
				Sys.sleep(0.01);
			}
		}

		// Close FFmpeg
		if (process != null) {
			try { process.stdin.close(); } catch (_:Dynamic) {}
			try { process.close(); } catch (_:Dynamic) {}
			try { process.kill(); } catch (_:Dynamic) {}
			process = null;
		}

		// Cleanup GL
		for (pbo in pbos) {
			try { GL.deleteBuffer(pbo); } catch (_:Dynamic) {}
		}
		pbos = [];

		// Clear pools
		freeList = [];
		frameQueue = [];
		batchBufferPool = [];

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end
		Application.current.window.resizable = true;

		cleanupLock = false;
		Sys.println("Cleanup complete!");
	}
}