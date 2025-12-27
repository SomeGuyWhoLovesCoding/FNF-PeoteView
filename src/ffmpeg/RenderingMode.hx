package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import sys.thread.Thread;
import lime.utils.DataPointer;

@:publicFields
class RenderingMode {
	static final PBO_BUFFERS:Int = 32;
	static final QUEUE_SIZE:Int = 12;
	
	// Add flags for persistent mapping
	static final MAP_READ_BIT:Int = 0x0001;
	static final MAP_WRITE_BIT:Int = 0x0002;
	static final MAP_PERSISTENT_BIT:Int = 0x0040;
	static final MAP_COHERENT_BIT:Int = 0x0080;
	static final CLIENT_STORAGE_BIT:Int = 0x0200;
	
	static var pbos:Array<GLBuffer> = [];
	static var pboMappedPtrs:Array<DataPointer> = []; // Store mapped pointers
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
		pboMappedPtrs = [];
		pboTarget = 0x88EB; // GL_PIXEL_PACK_BUFFER
		
		var flags = MAP_READ_BIT | MAP_WRITE_BIT | MAP_PERSISTENT_BIT | MAP_COHERENT_BIT;
		
		// First test if we can use bufferStorage
		var usePersistentMapping = false;
		#if FV_LIME_FORK
		#if (cpp || hl)
		try {
			// Test if bufferStorage is available
			var testBuf = GL.createBuffer();
			GL.bindBuffer(pboTarget, testBuf);
			GL.bufferStorage(pboTarget, 16, cast null, flags);
			GL.deleteBuffer(testBuf);
			usePersistentMapping = true;
			Sys.println("Rendering Mode System - Using GL.bufferStorage for persistent mapping");
		} catch (e:Dynamic) {
			Sys.println("Rendering Mode System - GL.bufferStorage not available, using traditional PBOs");
		}
		#end
		#end
		
		for (i in 0...PBO_BUFFERS) {
			var buf = GL.createBuffer();
			GL.bindBuffer(pboTarget, buf);
			
			if (usePersistentMapping) {
				// Use bufferStorage for persistent mapped buffers
				GL.bufferStorage(pboTarget, frameSize, cast null, flags | CLIENT_STORAGE_BIT);
				
				// Map the buffer persistently
				var ptr = GL.mapBufferRange(pboTarget, 0, frameSize, flags);
				pboMappedPtrs.push(ptr);
			} else {
				// Fallback: use traditional bufferData
				GL.bufferData(pboTarget, frameSize, cast null, GL.STREAM_COPY);
				// Store null to indicate no persistent mapping
				pboMappedPtrs.push(cast 0);
			}
			
			pbos.push(buf);
		}
		GL.bindBuffer(pboTarget, null);
		Sys.println("Rendering Mode System - PBOs initialized successfully.");
	}

	// ---------------- Frame Pool ----------------
	static function getFreeFrame():Bytes {
		if (freeList.length > 0) return freeList.pop();
		return Bytes.alloc(frameSize); // fallback
	}

	static function returnFrame(frame:Bytes) {
		freeList.push(frame);
	}

	// ---------------- Queue ----------------
	static function enqueueFrame(frame:Bytes) {
		frameQueue.push(frame);
	}

	static function dequeueFrame():Bytes {
		if (frameQueue.length > 0) return frameQueue.shift();
		return null;
	}

	// ---------------- Writer Thread ----------------
	static function acquireWriter() {
		if (writerThread != null) return;
		writerThread = Thread.create(function() {
			while (started || frameQueue.length > 0) {
				var frame = dequeueFrame();
				if (frame == null) {
					Sys.sleep(0);
					continue;
				}
				try {
					process.stdin.write(frame);
				} catch (e:Dynamic) {
					Sys.println("Writer blocked, dropping frame: " + e);
				}
				returnFrame(frame);
			}
		});
	}

	// ---------------- Pipe Frame (MAIN THREAD ONLY) ----------------
	static function pipeFrame() {
		if (!enabled || !started || !ffmpegExists || process == null) return;

		var buffer = getFreeFrame();

		if (pbos.length == PBO_BUFFERS) {
			var readIndex = (pboIndex + PBO_BUFFERS - 3) % PBO_BUFFERS; // read PBO written 3 frames ago
			var writePBO = pbos[pboIndex];
			var readPBO = pbos[readIndex];
			var mappedPtr = pboMappedPtrs[readIndex];

			// Write pixels into current PBO
			GL.bindBuffer(pboTarget, writePBO);
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, cast null);
			GL.bindBuffer(pboTarget, null);

			// Copy data from PBO to buffer
			if (mappedPtr != cast 0) {
				// With persistent mapping - we need to synchronize access
				// Use GL_FENCE to ensure the data is ready
				#if (cpp || hl)
				// We can't use glMemoryBarrier as requested, so we rely on the 3-frame offset
				// and hope the GPU finishes writing in time
				
				// Direct memory copy from the persistently mapped buffer
				// This requires platform-specific code
				#if cpp
				// For C++ target
				var byteArray = new lime.utils.UInt8Array(buffer);
				var ptr_int:cpp.RawPointer<Int> = untyped __cpp__("(int*)(uintptr_t){0}", mappedPtr);
				cpp.Native.memcpy(byteArray.buffer, ptr_int, frameSize);
				#elseif hl
				// For HashLink target
				var hlBytes:hl.Bytes = buffer;
				var ptrInt:Int64 = cast mappedPtr;
				buffer = hl.Bytes.fromAddress(ptrInt).toBytes(frameSize);
				#end
				#else
				// Fallback for other targets
				GL.bindBuffer(pboTarget, readPBO);
				GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
				GL.bindBuffer(pboTarget, null);
				#end
			} else {
				// Fallback without persistent mapping
				GL.bindBuffer(pboTarget, readPBO);
				try {
					GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
				} catch (e:Dynamic) {
					Sys.println("Warning: getBufferSubData failed, disabling PBOs");
					pbos = [];
					pboMappedPtrs = [];
					pboTarget = 0;
				}
				GL.bindBuffer(pboTarget, null);
			}

			enqueueFrame(buffer);
			pboIndex = (pboIndex + 1) % PBO_BUFFERS;

		} else {
			// fallback without PBO
			GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, buffer);
			enqueueFrame(buffer);
		}

		haxe.Timer.delay(acquireWriter, 500);
	}

	// ------------------ Encoder ------------------
	static function getBestEncoder():Array<String> {
		var encoders = [
			{name:'h264_nvenc', args:['-c:v','h264_nvenc','-preset','p1','-tune','ull','-b:v','3M','-maxrate','4M','-bufsize','1M']},
			{name:'h264_amf', args:['-c:v','h264_amf','-quality','speed','-b:v','3M','-maxrate','4M','-rc','vbr_latency']},
			{name:'h264_qsv', args:['-c:v','h264_qsv','-preset','veryfast','-global_quality','28','-look_ahead','0','-async_depth','7','-b:v','3M']}
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
		return ['-c:v','libx264','-preset','ultrafast','-crf','27','-tune','zerolatency','-x264-params','ref=1:bframes=0:me=dia:subq=1:trellis=0'];
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
			'-vf','vflip','-fflags','nobuffer','-flags','low_delay',
			'-bufsize','8M','-threads','0','-thread_queue_size','8192'
		].concat(encoderSettings).concat([
			'-colorspace','bt709',
			'assets/videos/rendered/' + songName + '.mp4'
		]);

		process = new Process('ffmpeg', args);

		initPBOs();
		GL.pixelStorei(GL.PACK_ALIGNMENT, 16);

		started = true;
		renderTime = haxe.Timer.stamp();
		Sys.println("Rendering Mode System - Started!");
	}

	// ------------------ Stop Render ------------------
	static function stopRender() {
		if (!started) return;
		started = false;

		renderTime = haxe.Timer.stamp() - renderTime;
		Sys.println('Rendering Mode System - Finished Rendering in ${Tools.formatTime(renderTime*1000,true)}.');

		while(frameQueue.length > 0) Sys.sleep(0.003);
		writerThread = null;

		if (process != null) {
			try { if(process.stdin != null) process.stdin.close(); } catch(_) {}
			process.close();
			process.kill();
		}

		// Clean up PBOs
		for (i in 0...pbos.length) {
			var pbo = pbos[i];
			var ptr = pboMappedPtrs[i];
			if (ptr != cast 0) {
				GL.bindBuffer(pboTarget, pbo);
				GL.unmapBuffer(pboTarget);
				GL.bindBuffer(pboTarget, null);
			}
			GL.deleteBuffer(pbo);
		}
		pbos = [];
		pboMappedPtrs = [];
		freeList = [];
		frameQueue = [];
		GL.pixelStorei(GL.PACK_ALIGNMENT,4);

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end
		Application.current.window.resizable = true;
	}
}