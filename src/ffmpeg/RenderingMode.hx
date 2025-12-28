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
import ffmpeg.NetworkStreamer;
import lime.utils.DataPointer;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 5;
	static final QUEUE_SIZE:Int = 16; // Increased for better buffering
	static final BATCH_SIZE:Int = 64; // Number of frames to batch together
	static final MAX_QUEUE_LENGTH:Int = 64; // Prevent excessive memory usage

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

	static var useNetworkStreaming:Bool = false;
	static var networkHost:String = "192.168.1.100";
	static var networkPort:Int = 8888;

	// ---------------- Batch Buffer Pool ----------------
	private static var batchBufferPool:Array<Bytes> = [];
	private static var batchBufferSize:Int = 0;
	private static var bufferPoolMutex:Mutex = new Mutex();

	// ---------------- Performance Monitoring ----------------
	static var framesCaptured:Int = 0;
	static var framesWritten:Int = 0;
	static var lastLogTime:Float = 0;
	static var logInterval:Float = 5.0; // Log every 5 seconds

	// ------------------ PBOs ------------------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;
		batchBufferSize = frameSize * BATCH_SIZE;

		queueMutex = new Mutex();
		queueLock = new Lock();
		bufferPoolMutex = new Mutex();

		freeList = [];
		frameQueue = [];

		// Allocate frame pool
		for (i in 0...QUEUE_SIZE) {
			var b = Bytes.alloc(frameSize);
			freeList.push(b);
		}

		// Allocate batch buffer pool (3 buffers for triple buffering)
		batchBufferPool = [];
		for (i in 0...3) {
			var b = Bytes.alloc(batchBufferSize);
			batchBufferPool.push(b);
		}

		pbos = [];
		pboTarget = 0x88EB; // GL_PIXEL_PACK_BUFFER

		// Check if buffer mapping is available
		#if FV_LIME_FORK
		var extensions = GL.getSupportedExtensions();
		var hasMapBuffer = (extensions != null && extensions.indexOf("GL_ARB_pixel_buffer_object") != -1);

		if (hasMapBuffer) {
			Sys.println("Using PBO with buffer mapping (fast path)");
		} else {
			Sys.println("Using PBO with getBufferSubData (slow path)");
		}
		#end

		for (i in 0...PBO_BUFFERS) {
			var buf = GL.createBuffer();
			GL.bindBuffer(pboTarget, buf);


			// Allocate PBO memory
			GL.bufferData(pboTarget, frameSize, cast null, 0x88E2); // GL_STREAM_READ

			pbos.push(buf);
		}
		GL.bindBuffer(pboTarget, null);

		Sys.println("Rendering Mode System - PBOs initialized successfully.");
		Sys.println('Frame size: ${frameSize} bytes, Batch buffer: ${batchBufferSize} bytes');
		Sys.println('Queue capacity: ${QUEUE_SIZE} frames');
	}

	// ---------------- Frame Pool (Thread-safe) ----------------
	static inline function getFreeFrame():Bytes {
		queueMutex.acquire();
		var frame = if (freeList.length > 0) freeList.pop() else null;
		queueMutex.release();

		if (frame == null) {
			// Allocate new frame if pool is empty (should be rare with proper QUEUE_SIZE)
			frame = Bytes.alloc(frameSize);
		}
		return frame;
	}

	static inline function returnFrame(frame:Bytes) {
		if (frame != null) {
			queueMutex.acquire();
			freeList.push(frame);
			queueMutex.release();
		}
	}

	// ---------------- Batch Buffer Pool (Thread-safe) ----------------
	static inline function getFreeBatchBuffer():Bytes {
		bufferPoolMutex.acquire();
		var buffer = if (batchBufferPool.length > 0) batchBufferPool.pop() else null;
		bufferPoolMutex.release();

		if (buffer == null) {
			// Allocate new buffer if pool is empty
			buffer = Bytes.alloc(batchBufferSize);
		}
		return buffer;
	}

	static inline function returnBatchBuffer(buffer:Bytes) {
		if (buffer != null) {
			bufferPoolMutex.acquire();
			batchBufferPool.push(buffer);
			bufferPoolMutex.release();
		}
	}

	// ---------------- Queue (Thread-safe with condition variable) ----------------
	static inline function enqueueFrame(frame:Bytes) {
		queueMutex.acquire();

		// Prevent queue from growing too large
		if (frameQueue.length < MAX_QUEUE_LENGTH) {
			frameQueue.push(frame);
			framesCaptured++;

			// Signal writer thread if it's waiting
			if (frameQueue.length == 1) {
				queueLock.release();
			}
		} else {
			// Queue full, drop frame
			returnFrame(frame);
		}

		queueMutex.release();
	}

	static inline function dequeueFrame():Bytes {
		queueMutex.acquire();
		var frame = if (frameQueue.length > 0) frameQueue.shift() else null;
		queueMutex.release();
		return frame;
	}

	static inline function waitForFrames(timeout:Float):Bool {
		return queueLock.wait(timeout);
	}

	// ---------------- Writer Thread with Optimized Batch Processing ----------------
	static function acquireWriter() {
		if (writerThread != null) return;

		writerThread = Thread.create(function() {
			Sys.println('Writer thread started');

			#if cpp
			if (nativeProcessHandle != null) {
				Sys.println("Using direct NativeProcess with batch optimization");
			}
			#end

			var batch:Array<Bytes> = [];
			var batchBuffer:Bytes = null;
			var lastStatsTime = haxe.Timer.stamp();
			var framesInBatch:Int = 0;

			while (!stopRequested) {
				// Wait for frames with timeout
				if (batch.length == 0) {
					if (!waitForFrames(0.002)) {
						if (stopRequested) break;
						continue;
					}
				}

				// Collect frames into batch
				queueMutex.acquire();
				while (batch.length < BATCH_SIZE && frameQueue.length > 0) {
					var frame = frameQueue.shift();
					if (frame != null) {
						batch.push(frame);
						framesInBatch++;
					}
				}
				queueMutex.release();

				if (batch.length == 0) {
					if (stopRequested) break;
					continue;
				}

				// Get batch buffer from pool
				batchBuffer = getFreeBatchBuffer();
				var framesToWrite = batch.length;

				// Blit all frames into batch buffer
				var offset:Int = 0;
				for (i in 0...framesToWrite) {
					var frame = batch[i];
					batchBuffer.blit(offset, frame, 0, frameSize);
					offset += frameSize;
				}

				// Write batch
				try {
					#if cpp
					if (nativeProcessHandle != null) {
						// Direct native write - single system call for entire batch
						var totalBytes = frameSize * framesToWrite;
						var written = NativeProcess.process_stdin_write(
							nativeProcessHandle,
							batchBuffer.getData(),
							0,
							totalBytes
						);
						if (written != totalBytes) {
							Sys.println("Warning: Incomplete batch write: " + written + "/" + totalBytes);
						}
						framesWritten += framesToWrite;
					} else
					#end
					{
						// Fallback to normal write
						if (process != null && process.stdin != null) {
							var totalBytes = frameSize * framesToWrite;
							process.stdin.write(batchBuffer.sub(0, totalBytes));
							process.stdin.flush();
							framesWritten += framesToWrite;
						}
					}
				} catch (e:Dynamic) {
					var err = Std.string(e);
					if (err.indexOf("EOF") != -1 || err.indexOf("Broken pipe") != -1) {
						Sys.println("FFmpeg pipe closed, stopping writer");
						break;
					} else {
						Sys.println("Write error: " + err);
					}
				}

				// Return resources to pools
				returnBatchBuffer(batchBuffer);
				batchBuffer = null;

				for (frame in batch) returnFrame(frame);
				batch = [];

				// Log performance stats periodically
				var now = haxe.Timer.stamp();
				if (now - lastStatsTime >= logInterval) {
					var elapsed = now - lastStatsTime;
					var fps = framesInBatch / elapsed;
					Sys.println('Writer: ${fps}fps, Queue: ${frameQueue.length}/${QUEUE_SIZE}');
					lastStatsTime = now;
					framesInBatch = 0;
				}
			}

			// Final flush if we have remaining frames
			if (batch.length > 0) {
				try {
					var totalBytes = frameSize * batch.length;
					if (process != null && process.stdin != null) {
						var tempBuffer = Bytes.alloc(totalBytes);
						var offset = 0;
						for (frame in batch) {
							tempBuffer.blit(offset, frame, 0, frameSize);
							offset += frameSize;
						}
						process.stdin.write(tempBuffer);
						process.stdin.flush();
						framesWritten += batch.length;
					}
				} catch (e:Dynamic) {}

				for (frame in batch) returnFrame(frame);
			}

			if (batchBuffer != null) returnBatchBuffer(batchBuffer);

			Sys.println('Writer thread exiting. Frames written: ${framesWritten}');
		});
	}

	// ---------------- Pipe Frame with Correct PBO Mapping ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || stopRequested) return;
		
		// Get buffer from appropriate source
		var buffer:Bytes;
		if (useNetworkStreaming) {
			buffer = NetworkStreamer.getFreeFrame();
			if (buffer == null) return;
		} else {
			buffer = getFreeFrame();
			if (buffer == null) return;
		}

		// PBO readback with double buffering
		if (pbos.length == PBO_BUFFERS) {
			var readIndex = (pboIndex + 3) % PBO_BUFFERS;
			var writeIndex = pboIndex;
			
			// Start async readback to write PBO
			GL.bindBuffer(pboTarget, pbos[writeIndex]);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 
				GL.RGB, GL.UNSIGNED_SHORT_5_6_5, cast null);
			
			// Try buffer mapping (fastest)
			GL.bindBuffer(pboTarget, pbos[readIndex]);
			
			/*#if FV_LIME_FORK
			var mappedPtr#if cpp :cpp.RawPointer<cpp.UInt8> #else :hl.NativeArray<hl.UI8> #end = @:privateAccess lime._internal.backend.native.NativeCFFI.fv_gl_map_buffer_range_pbo(frameSize);
			if (mappedPtr != null) {
				if (useNetworkStreaming) {
					NetworkStreamer.enqueueFrame(buffer);
				} else {
					enqueueFrame(buffer);
				}
				GL.bindBuffer(pboTarget, null);
				pboIndex = (pboIndex + 1) % PBO_BUFFERS;
			} else
			#end
			{*/
				// Fallback: Use getBufferSubData
				try {
					GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
					
					if (useNetworkStreaming) {
						NetworkStreamer.enqueueFrame(buffer);
					} else {
						enqueueFrame(buffer);
					}
				} catch (e:Dynamic) {
					Sys.println("getBufferSubData failed: " + e);
					
					// Ultimate fallback: direct readPixels
					GL.bindBuffer(pboTarget, null);
					GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 
						GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
						
					if (useNetworkStreaming) {
						NetworkStreamer.enqueueFrame(buffer);
					} else {
						enqueueFrame(buffer);
					}
				}
				
				GL.bindBuffer(pboTarget, null);
				pboIndex = (pboIndex + 1) % PBO_BUFFERS;
			//}
		} else {
			// Direct synchronous read
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 
				GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
			
			if (useNetworkStreaming) {
				NetworkStreamer.enqueueFrame(buffer);
			} else {
				enqueueFrame(buffer);
			}
		}

		// Start writer thread if needed
		if (!useNetworkStreaming && writerThread == null) {
			acquireWriter();
		}
	}

	// ------------------ Encoder ------------------
	static function getBestEncoder():Array<String> {
		#if linux
		// Test for Linux hardware encoders first
		var linuxEncoders = [
			// Raspberry Pi (v4l2_m2m)
			{name:'h264_v4l2m2m', args:[
				'-c:v','h264_v4l2m2m',
				'-num_output_buffers','64',
				'-num_capture_buffers','64',
				'-qp','28'
			]},

			// Intel VAAPI
			{name:'h264_vaapi', args:[
				'-c:v','h264_vaapi',
				'-qp','28',
				'-global_quality','28',
				'-low_power','1'
			]},

			// AMD AMF on Linux
			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','28',
				'-qp_p','28',
				'-usage','ultralowlatency'
			]}
		];

		for (encoder in linuxEncoders) {
			var testProcess = new Process('ffmpeg', [
				'-f','lavfi','-v','quiet','-i','color=black:s=64x64:d=0.1',
				'-c:v',encoder.name,'-f','null','-'
			]);
			var exitCode = testProcess.exitCode();
			if (exitCode == 0) {
				Sys.println('Rendering Mode System - Using Linux encoder: ${encoder.name}');
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
				'-rc-lookahead', '0',
				'-surfaces', '1',
				'-bf', '0',
			]},

			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','28',
				'-qp_p','28',
				'-preanalysis','false'
			]},

			{name:'h264_qsv', args:[
				'-c:v','h264_qsv',
				'-preset','veryfast',
				'-global_quality','28',
				'-look_ahead', '0',
				'-look_ahead_depth', '0',
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
		#end

		// Fallback to libx264
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

		songName = Chart.header.title;
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;

		// Reset performance counters
		framesCaptured = 0;
		framesWritten = 0;
		lastLogTime = haxe.Timer.stamp();

		Application.current.window.resizable = false;
		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = true;
		#else
		Application.current.window.frameRate = 1000;
		#end

		if (useNetworkStreaming) {
			Sys.println("=== NETWORK STREAMING MODE ===");

			NetworkStreamer.printLocalIPInfo();
			networkHost = NetworkStreamer.getLocalIPs()[1];

			Sys.println('Connecting to: $networkHost:$networkPort');

			if (!NetworkStreamer.init(networkHost, networkPort, frameSize, QUEUE_SIZE)) {
				Sys.println("Failed to connect to remote encoder!");
				Sys.println("Start FFmpeg on the remote machine first:");
				Sys.println(NetworkStreamer.getRemoteFFmpegCommand(
					Main.VARIABLE_WIDTH,
					Main.VARIABLE_HEIGHT,
					frameRate,
					'output.mp4'
				));
				throw "Network streaming initialization failed";
			}

			ffmpegExists = true;
			process = null;
		} else {
			if (!FileSystem.exists(ffmpeg)) throw '$ffmpeg not found!';
			if (!FileSystem.exists('assets/videos/rendered/'))
				FileSystem.createDirectory('assets/videos/rendered');

			ffmpegExists = true;

			var encoderSettings = getBestEncoder();
			var inputSource = '-';

			var args = [
				'-y','-f','rawvideo','-pix_fmt','rgb565le',
				'-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
				'-r',Std.string(frameRate),'-i',inputSource,
				'-vf','vflip',
				'-bufsize','1M','-thread_queue_size','1024',
				'-max_muxing_queue_size','4096',
				'-nostats','-loglevel', 'quiet','-hide_banner',
				'-xerror','-avoid_negative_ts','make_zero'
			].concat(encoderSettings).concat([
				'-an','-colorspace','bt709',
				'assets/videos/rendered/' + songName + '.mp4'
			]);

			process = new Process('ffmpeg', args);

			#if cpp
			nativeProcessHandle = untyped process.stdin.p;
			#end
		}

		stopRequested = false;
		cleanupLock = false;
		writerThread = null;

		initPBOs();

		if (useNetworkStreaming) {
			NetworkStreamer.startWriter();
		}

		started = true;
		renderTime = haxe.Timer.stamp();
		Sys.println("Rendering Mode System - Started with optimized threading!");
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
		Sys.println('Performance: ${framesCaptured} captured, ${framesWritten} written');

		if (useNetworkStreaming) {
			NetworkStreamer.stop();
		} else {
			// Signal writer thread to wake up and exit
			queueLock.release();

			if (writerThread != null) {
				Sys.println("Waiting for writer thread to finish...");
				var startWait = haxe.Timer.stamp();
				var maxWaitTime = 10.0; // Maximum 10 seconds

				while ((haxe.Timer.stamp() - startWait) < maxWaitTime) {
					queueMutex.acquire();
					var queueEmpty = frameQueue.length == 0;
					queueMutex.release();

					if (queueEmpty) break;
					Sys.sleep(0.002);
				}

				Sys.println("Writer thread cleanup complete");
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

		if (process != null) {
			Sys.println("FFmpeg close...");
			try {
				process.close();
			} catch (e:Dynamic) {}
			try {
				process.kill();
			} catch (e:Dynamic) {}
			Sys.println("FFmpeg process terminated");
			process = null;
		}

		Sys.println("Cleaning up GL resources...");
		for (pbo in pbos) {
			try {
				GL.deleteBuffer(pbo);
			} catch (e:Dynamic) {}
		}
		pbos = [];

		if (!useNetworkStreaming) {
			freeList = [];
			frameQueue = [];
			batchBufferPool = [];
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