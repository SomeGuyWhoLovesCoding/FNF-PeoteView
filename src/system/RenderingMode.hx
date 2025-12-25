package system;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.app.Application;
import sys.thread.Thread;
import sys.thread.Mutex;

@:publicFields
class RenderingMode {
	private static var ffmpegExists(default, null):Bool;

	static var process:Process;
	static var enabled:Bool = true;
	static var started:Bool = false;

	static var songName:String;

	static var renderTime(default, null):Float;
	
	// Parallel processing system
	static var BUFFER_POOL_SIZE:Int = 64;
	static var bufferPool:Array<haxe.io.UInt8Array> = [];
	
	// Circular buffer for frame storage
	static var frameBuffers:Array<haxe.io.UInt8Array> = [];
	static var frameIndices:Array<Int> = [];
	static var frameReady:Array<Bool> = [];
	static var nextWriteSlot:Int = 0; // Next buffer slot to write to
	static var nextReadSlot:Int = 0; // Next buffer slot to read from
	static var availableSlots:Int = BUFFER_POOL_SIZE; // Available buffer slots
	
	// Thread synchronization
	static var writerThread:Thread;
	static var running:Bool = false;
	static var bufferMutex = new Mutex();
	
	// Performance tracking
	static var framesCaptured:Int = 0;
	static var framesWritten:Int = 0;
	static var frameIndex:Int = 0;

	static function getBestEncoder():Array<String> {
		var encoders = [
			{name: 'h264_nvenc', args: ['-c:v', 'h264_nvenc', '-preset', 'p4', '-b:v', '20M']},
			{name: 'h264_amf', args: ['-c:v', 'h264_amf', '-quality', 'balanced', '-b:v', '20M']},
			{name: 'h264_qsv', args: ['-c:v', 'h264_qsv', '-preset', 'medium', '-b:v', '20M']},
			{name: 'libx264', args: ['-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast']}
		];

		for (encoder in encoders) {
			try {
				// Actually test if the encoder works by trying to encode a single frame
				var testProcess = new Process('ffmpeg', [
					'-f', 'lavfi',
					'-i', 'color=black:s=64x64:d=0.1',
					'-c:v', encoder.name,
					'-f', 'null',
					'-'
				]);

				var exitCode = testProcess.exitCode();
				testProcess.kill();
				testProcess.close();

				if (exitCode == 0) {
					Sys.println('Rendering Mode System - Using encoder: ${encoder.name}');
					return encoder.args;
				}
			} catch (e:Dynamic) {
				// Encoder test failed, try next one
				continue;
			}
		}

		// Fallback to software encoding
		Sys.println('Rendering Mode System - Using encoder: libx264 (software fallback)');
		return ['-c:v', 'libx264', '-crf', '18', '-preset', 'veryfast'];
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

		if (!FileSystem.exists('assets/videos/rendered/')) { // In case you delete the videos/rendered folder
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

		// Get best encoder settings
		var encoderSettings = getBestEncoder();

		Sys.println("Rendering Mode System - Done. Now let's initialize the real stuff!");

		// Build the full arguments array
		var args = [
			'-y', // START
			'-f', 'rawvideo', // FILTER
			'-pix_fmt', 'rgba', // PIXEL FORMAT
			'-s', Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT, // DIMENSIONS
			'-r', '60', // FRAMERATE
			'-i', '-', // INPUT INIT
			'-vf', 'vflip', // Use video filter instead of display flags
		];

		// Add encoder settings
		args = args.concat(encoderSettings);

		// Add remaining settings
		args = args.concat([
			'-colorspace', 'bt709', // CONVERT TO BT709 COLORSPACE
			'-pix_fmt', 'yuv420p', // Ensure compatibility
			'assets/videos/rendered/' + songName + '.mp4' // END (FILEPATH)
		]);

		Sys.println("Rendering Mode System - Almost there. Just need to execute the process just like that...");

		process = new Process('ffmpeg', args);

		Sys.println("Rendering Mode System - Done.");

		// Initialize circular buffer system
		var bufferSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;
		frameBuffers = [];
		frameIndices = [];
		frameReady = [];
		
		for (i in 0...BUFFER_POOL_SIZE) {
			var buffer = new haxe.io.UInt8Array(bufferSize);
			bufferPool.push(buffer);
			frameBuffers.push(buffer);
			frameIndices.push(-1);
			frameReady.push(false);
		}
		
		// Reset state
		nextWriteSlot = 0;
		nextReadSlot = 0;
		availableSlots = BUFFER_POOL_SIZE;
		framesCaptured = 0;
		framesWritten = 0;
		frameIndex = 0;
		
		// Start writer thread
		running = true;
		writerThread = Thread.create(function() {
			var expectedFrameIndex = 0;
			
			while (running) {
				var hasWork = false;
				var bufferToWrite = null;
				var frameIdx = -1;
				
				// Check if next frame is ready
				bufferMutex.acquire();
				if (availableSlots < BUFFER_POOL_SIZE) { // There are frames to process
					if (frameReady[nextReadSlot] && frameIndices[nextReadSlot] == expectedFrameIndex) {
						hasWork = true;
						bufferToWrite = frameBuffers[nextReadSlot];
						frameIdx = frameIndices[nextReadSlot];
						
						// Mark buffer as consumed
						frameReady[nextReadSlot] = false;
						frameIndices[nextReadSlot] = -1;
						
						// Move read pointer and update available slots
						nextReadSlot = (nextReadSlot + 1) % BUFFER_POOL_SIZE;
						availableSlots++;
						
						expectedFrameIndex++;
					}
				}
				bufferMutex.release();
				
				if (hasWork && bufferToWrite != null) {
					// Write frame to ffmpeg
					try {
						process.stdin.write(untyped bufferToWrite.bytes);
						framesWritten++;
						
						// Log progress every 100 frames
						if (framesWritten % 100 == 0) {
							Sys.println('Rendering Mode System - Progress: ${framesWritten} frames written');
						}
					} catch (e:Dynamic) {
						Sys.println('Rendering Mode System - Writer thread error: $e');
						running = false;
						break;
					}
				} else {
					// No frame ready, sleep briefly to avoid busy waiting
					Sys.sleep(0.001); // 1ms sleep
				}
			}
			
			// Write any remaining frames
			while (availableSlots < BUFFER_POOL_SIZE) {
				bufferMutex.acquire();
				var bufferToWrite = null;
				var frameIdx = -1;
				
				// Find next frame in order
				for (i in 0...BUFFER_POOL_SIZE) {
					var idx = (nextReadSlot + i) % BUFFER_POOL_SIZE;
					if (frameReady[idx] && frameIndices[idx] == expectedFrameIndex) {
						bufferToWrite = frameBuffers[idx];
						frameIdx = frameIndices[idx];
						frameReady[idx] = false;
						frameIndices[idx] = -1;
						nextReadSlot = (idx + 1) % BUFFER_POOL_SIZE;
						availableSlots = BUFFER_POOL_SIZE; // All slots available after cleanup
						expectedFrameIndex++;
						break;
					}
				}
				bufferMutex.release();
				
				if (bufferToWrite != null) {
					try {
						process.stdin.write(untyped bufferToWrite.bytes);
						framesWritten++;
					} catch (e:Dynamic) {
						// Ignore errors during cleanup
						break;
					}
				} else {
					// No more frames in order, break
					break;
				}
			}
			
			Sys.println('Rendering Mode System - Writer thread finished');
		});

		renderTime = haxe.Timer.stamp();
		started = true;
		Sys.println("Rendering Mode System - Started with parallel processing!");
	}

	static function pipeFrame()
	{
		if (!enabled || !started || !ffmpegExists || process == null || !running)
			return;

		try {
			// Wait for available buffer slot
			var bufferSlot = -1;
			var attempts = 0;
			
			while (bufferSlot < 0 && attempts < 100) {
				bufferMutex.acquire();
				if (availableSlots > 0) {
					// Find next available slot
					for (i in 0...BUFFER_POOL_SIZE) {
						var slot = (nextWriteSlot + i) % BUFFER_POOL_SIZE;
						if (!frameReady[slot]) {
							bufferSlot = slot;
							break;
						}
					}
				}
				bufferMutex.release();
				
				if (bufferSlot < 0) {
					// Very short sleep to avoid CPU hogging
					Sys.sleep(0.0001); // 0.1ms
					attempts++;
				}
			}
			
			if (bufferSlot < 0) {
				// If we still don't have a slot, wait more
				while (bufferSlot < 0) {
					bufferMutex.acquire();
					if (availableSlots > 0) {
						// Find available slot
						for (i in 0...BUFFER_POOL_SIZE) {
							var slot = (nextWriteSlot + i) % BUFFER_POOL_SIZE;
							if (!frameReady[slot]) {
								bufferSlot = slot;
								break;
							}
						}
					}
					bufferMutex.release();
					
					if (bufferSlot < 0) {
						Sys.sleep(0.001); // 1ms
					}
				}
			}
			
			// Get buffer for this slot
			var buffer = frameBuffers[bufferSlot];
			
			// Read pixels from GPU
			Main.current.peoteView.gl.readPixels(1, 1, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, GL.RGBA, GL.UNSIGNED_BYTE, buffer);
			
			// Store frame in buffer with index
			bufferMutex.acquire();
			frameIndices[bufferSlot] = frameIndex;
			frameReady[bufferSlot] = true;
			frameIndex++;
			framesCaptured++;
			availableSlots--;
			
			// Update write pointer to next slot
			nextWriteSlot = (bufferSlot + 1) % BUFFER_POOL_SIZE;
			bufferMutex.release();
			
		} catch (e:Dynamic) {
			Sys.println('Rendering Mode System - Error capturing frame: $e');
			stopRender();
		}
	}

	static function stopRender()
	{
		if (!enabled && !started)
			return;

		started = false;
		running = false;
		
		// Give writer thread time to finish
		var startWait = haxe.Timer.stamp();
		while (framesCaptured > framesWritten && (haxe.Timer.stamp() - startWait) < 5.0) {
			var remaining = framesCaptured - framesWritten;
			if (remaining > 0) {
				if (remaining % 100 == 0) {
					Sys.println('Rendering Mode System - Waiting for $remaining frames to write...');
				}
				Sys.sleep(0.01); // 10ms sleep
			}
		}
		
		// Additional wait for thread to finish
		Sys.sleep(0.05);
		
		// Clean up buffers
		bufferPool = [];
		frameBuffers = [];
		frameIndices = [];
		frameReady = [];

		if (process != null) {
			try {
				if (process.stdin != null) {
					process.stdin.close();
				}
			} catch (e:Dynamic) {
				// Ignore close errors
			}

			try {
				process.close();
			} catch (e:Dynamic) {}
			
			try {
				process.kill();
			} catch (e:Dynamic) {}
		}

		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.graphics.frameRate;
		#end

		renderTime = haxe.Timer.stamp() - renderTime;
		var fps = framesWritten / renderTime;
		var efficiency = framesCaptured > 0 ? (framesWritten / framesCaptured) * 100 : 100;
		Sys.println('Rendering Mode System - Finished Rendering in just ${Tools.formatTime(renderTime * 1000)}.');
		Sys.println('Rendering Mode System - Captured ${framesCaptured} frames, wrote ${framesWritten} frames.');
		Sys.println('Rendering Mode System - Efficiency: ${Std.int(efficiency)}%');
		Sys.println('Rendering Mode System - Average FPS: ${Math.round(fps)}');
		Sys.println('Rendering Mode System - Using ${BUFFER_POOL_SIZE} buffers for parallel processing.');
		
		// Reset static variables
		writerThread = null;
	}
}