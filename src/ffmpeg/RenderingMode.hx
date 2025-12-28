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
import ffmpeg.NetworkStreamer;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 6;
	static final QUEUE_SIZE:Int = 16;
	static final BATCH_SIZE:Int = 128; // Number of frames to batch together

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

	static var useNetworkStreaming:Bool = false;
	static var networkHost:String = "192.168.1.100";
	static var networkPort:Int = 8888;

	// ---------------- Batch Buffer Pool ----------------
	private static var batchBufferPool:Array<Bytes> = [];
	private static var batchBufferSize:Int = 0;

	// ------------------ PBOs ------------------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 2;
		batchBufferSize = frameSize * BATCH_SIZE;

		freeList = [];
		frameQueue = [];

		// Allocate frame pool
		for (i in 0...QUEUE_SIZE) {
			var b = Bytes.alloc(frameSize);
			freeList.push(b);
		}

		// Allocate batch buffer pool (2 buffers for double buffering)
		batchBufferPool = [];
		for (i in 0...2) {
			var b = Bytes.alloc(batchBufferSize);
			batchBufferPool.push(b);
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
		Sys.println('Batch buffer size: ${batchBufferSize} bytes (${BATCH_SIZE} frames)');
	}

	// ---------------- Frame Pool ----------------
	static inline function getFreeFrame():Bytes {
		if (freeList.length > 0) return freeList.pop();
		return Bytes.alloc(frameSize);
	}

	static inline function returnFrame(frame:Bytes) {
		if (frame != null) freeList.push(frame);
	}

	// ---------------- Batch Buffer Pool ----------------
	static inline function getFreeBatchBuffer():Bytes {
		if (batchBufferPool.length > 0) return batchBufferPool.pop();
		return Bytes.alloc(batchBufferSize);
	}

	static inline function returnBatchBuffer(buffer:Bytes) {
		if (buffer != null) batchBufferPool.push(buffer);
	}

	// ---------------- Queue ----------------
	static inline function enqueueFrame(frame:Bytes) {
		frameQueue.push(frame);
	}

	static inline function dequeueFrame():Bytes {
		if (frameQueue.length > 0) return frameQueue.shift();
		return null;
	}

	// ---------------- Writer Thread with Batch Blitting ----------------
	static function acquireWriter() {
		if (writerThread != null) return;
		writerThread = Thread.create(function() {
			Sys.println('Writer thread started with batch blitting');
			
			#if cpp
			if (nativeProcessHandle != null) {
				Sys.println("Using direct NativeProcess.process_stdin_write() with batch blitting!");
			}
			#end
			
			var batch:Array<Bytes> = [];
			var batchBuffer:Bytes = null;
			var framesBatched:Int = 0;
			
			while (!stopRequested) {
				// Collect frames into batch array
				while (batch.length < BATCH_SIZE) {
					var frame = dequeueFrame();
					if (frame == null) break;
					batch.push(frame);
				}
				
				// If no frames, wait or exit
				if (batch.length == 0) {
					if (stopRequested) break;
					Sys.sleep(0.0003);
					continue;
				}
				
				// Get a batch buffer from pool
				batchBuffer = getFreeBatchBuffer();
				framesBatched = batch.length;
				
				// Blit all frames into the batch buffer
				var offset:Int = 0;
				for (i in 0...framesBatched) {
					var frame = batch[i];
					batchBuffer.blit(offset, frame, 0, frameSize);
					offset += frameSize;
				}
				
				// Write the entire batch buffer in one system call
				try {
					#if cpp
					if (nativeProcessHandle != null) {
						// Direct native write - single call for entire batch!
						var totalBytes = frameSize * framesBatched;
						var written = NativeProcess.process_stdin_write(
							nativeProcessHandle, 
							batchBuffer.getData(), 
							0, 
							totalBytes
						);
						if (written != totalBytes) {
							Sys.println("Incomplete batch write: " + written + "/" + totalBytes);
						}
					} else
					#end
					{
						// Fallback to normal write - still batched
						if (process != null && process.stdin != null) {
							var totalBytes = frameSize * framesBatched;
							process.stdin.write(batchBuffer.sub(0, totalBytes));
							process.stdin.flush();
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
				
				// Return batch buffer to pool
				returnBatchBuffer(batchBuffer);
				batchBuffer = null;
				
				// Return individual frames to pool
				for (frame in batch) returnFrame(frame);
				batch = [];
			}
			
			// Cleanup any remaining batch buffer
			if (batchBuffer != null) {
				returnBatchBuffer(batchBuffer);
			}
			
			Sys.println('Writer thread exiting');
		});
	}

	// ---------------- Pipe Frame (MAIN THREAD ONLY) ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || stopRequested) return;
		
		// Check if we can get a buffer
		var buffer:Bytes;
		if (useNetworkStreaming) {
			buffer = NetworkStreamer.getFreeFrame();
			if (buffer == null) {
				return;
			}
		} else {
			buffer = getFreeFrame();
			if (buffer == null) return;
		}

		// PBO readback (unchanged)
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
				
				// Enqueue to appropriate output
				if (useNetworkStreaming) {
					NetworkStreamer.enqueueFrame(buffer);
				} else {
					enqueueFrame(buffer);
				}
			} catch (e:Dynamic) {
				Sys.println("PBO read failed: " + e);
				GL.bindBuffer(pboTarget, null);
				
				if (useNetworkStreaming) {
					NetworkStreamer.returnFrame(buffer);
				} else {
					returnFrame(buffer);
				}
				return;
			}

			pboIndex = (pboIndex + 1) % PBO_BUFFERS;
		} else {
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGB, GL.UNSIGNED_SHORT_5_6_5, buffer);
			
			if (useNetworkStreaming) {
				NetworkStreamer.enqueueFrame(buffer);
			} else {
				enqueueFrame(buffer);
			}
		}

		// Start stdin writer if needed
		if (!useNetworkStreaming && writerThread == null) {
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

		initPBOs();
		
		if (useNetworkStreaming) {
			NetworkStreamer.startWriter();
		}

		started = true;
		renderTime = haxe.Timer.stamp();
		Sys.println("Rendering Mode System - Started with batch blitting!");
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

		if (useNetworkStreaming) {
			NetworkStreamer.stop();
		} else {
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

		if (process != null) {
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