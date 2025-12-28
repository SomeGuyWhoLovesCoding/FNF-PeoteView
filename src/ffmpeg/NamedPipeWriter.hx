package ffmpeg;

import sys.FileSystem;
import sys.io.File;
import haxe.io.Output;
import haxe.io.Bytes;
import sys.thread.Thread;
#if windows
import sys.io.Process;
#end

/**
 * Cross-platform named pipe writer for FFmpeg integration.
 * Provides high-performance frame streaming using OS-native pipes.
 */
@:publicFields
class NamedPipeWriter {
	
	// Platform-specific pipe paths
	#if windows
	private static inline var PIPE_PREFIX:String = "\\\\.\\pipe\\";
	#else
	private static inline var PIPE_PREFIX:String = "/tmp/";
	#end
	
	private static var pipeName:String;
	private static var pipePath:String;
	private static var writerThread:Thread;
	private static var frameQueue:Array<Bytes> = [];
	private static var freeList:Array<Bytes> = [];
	private static var stopRequested:Bool = false;
	private static var isActive:Bool = false;
	
	#if windows
	private static var pipeServerProcess:Process;
	#end
	
	/**
	 * Initialize the named pipe for writing.
	 * @param name Unique identifier for this pipe
	 * @param frameSize Size of each frame in bytes
	 * @param queueSize Number of frames to pre-allocate
	 * @return The pipe path to pass to FFmpeg
	 */
	static function init(name:String, frameSize:Int, queueSize:Int):String {
		if (isActive) {
			Sys.println("NamedPipeWriter: Already initialized");
			return pipePath;
		}
		
		pipeName = name + "_" + Date.now().getTime();
		pipePath = PIPE_PREFIX + pipeName;
		
		// Initialize frame pool
		freeList = [];
		frameQueue = [];
		for (i in 0...queueSize) {
			freeList.push(Bytes.alloc(frameSize));
		}
		
		#if windows
		createWindowsPipe();
		#else
		createUnixPipe();
		#end
		
		isActive = true;
		stopRequested = false;
		
		Sys.println('NamedPipeWriter: Initialized pipe at ${pipePath}');
		return pipePath;
	}
	
	#if windows
	static function findPowerShellPath():String {
		var possiblePaths = [
			"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
			"C:\\Windows\\SysWOW64\\WindowsPowerShell\\v1.0\\powershell.exe",
			"powershell.exe"
		];
		
		for (path in possiblePaths) {
			if (sys.FileSystem.exists(path)) {
				Sys.println("Found PowerShell at: " + path);
				return path;
			}
		}
		
		return "powershell.exe";
	}

	/**
	 * Create a named pipe server on Windows.
	 * This server will accept connections from FFmpeg and receive data from our writer thread.
	 */
	private static function createWindowsPipe() {
		// PowerShell script that creates a bidirectional pipe server
		// It reads from stdin (our data) and writes to the pipe (for FFmpeg)
		var psScript = '$$errorActionPreference = "Stop"

$$pipeName = "' + pipeName + '"

Write-Host "Creating named pipe server: $$pipeName"

$$pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
    $$pipeName,
    [System.IO.Pipes.PipeDirection]::Out,
    1,
    [System.IO.Pipes.PipeTransmissionMode]::Byte,
    [System.IO.Pipes.PipeOptions]::Asynchronous
)

Write-Host "Waiting for FFmpeg to connect..."
$$pipe.WaitForConnection()
Write-Host "FFmpeg connected!"

$$stdin = [Console]::OpenStandardInput()
$$buffer = New-Object byte[] 4194304

try {
    while ($$true) {
        $$read = $$stdin.Read($$buffer, 0, $$buffer.Length)
        if ($$read -eq 0) { 
            Write-Host "No more input data"
            break 
        }
        $$pipe.Write($$buffer, 0, $$read)
        $$pipe.Flush()
    }
} catch {
    Write-Host "Pipe error: $$_"
} finally {
    $$pipe.Close()
    $$pipe.Dispose()
    Write-Host "Pipe server terminated"
}';
		
		// Save script to file
		var scriptPath = "namedpipe_server_" + pipeName + ".ps1";
		sys.io.File.saveContent(scriptPath, psScript);
		
		// Start the pipe server process
		pipeServerProcess = new Process(findPowerShellPath(), [
			"-NoProfile",
			"-ExecutionPolicy", "Bypass",
			"-File", scriptPath
		]);
		
		// Give the server time to start
		Sys.sleep(0.5);
		Sys.println("NamedPipeWriter: Windows named pipe server started");
	}
	#else
	/**
	 * Create a FIFO (named pipe) on Unix-like systems.
	 */
	private static function createUnixPipe() {
		// Remove existing pipe if it exists
		if (FileSystem.exists(pipePath)) {
			try {
				FileSystem.deleteFile(pipePath);
			} catch (e:Dynamic) {
				Sys.println('NamedPipeWriter: Warning - could not delete existing pipe: $e');
			}
		}
		
		// Create FIFO using mkfifo command
		var mkfifo = new sys.io.Process('mkfifo', [pipePath]);
		var exitCode = mkfifo.exitCode();
		mkfifo.close();
		
		if (exitCode != 0) {
			throw 'NamedPipeWriter: Failed to create FIFO at ${pipePath}';
		}
		
		Sys.println('NamedPipeWriter: Created FIFO at ${pipePath}');
	}
	#end
	
	/**
	 * Start the writer thread that processes the frame queue.
	 */
	static function startWriter() {
		if (writerThread != null) return;
		
		writerThread = Thread.create(function() {
			Sys.println('NamedPipeWriter: Writer thread started');
			
			var pipeOutput:Output = null;
			
			// Open connection to pipe
			try {
				#if windows
				// Windows: Write to the PowerShell server's stdin
				// which will relay it to the named pipe for FFmpeg
				Sys.println('NamedPipeWriter: Connecting to pipe server stdin...');
				pipeOutput = pipeServerProcess.stdin;
				Sys.println('NamedPipeWriter: Connected to pipe server');
				#else
				// Unix: open the FIFO for writing (blocks until FFmpeg opens for reading)
				Sys.println('NamedPipeWriter: Opening FIFO for writing...');
				pipeOutput = File.write(pipePath, true);
				Sys.println('NamedPipeWriter: FIFO opened');
				#end
			} catch (e:Dynamic) {
				Sys.println('NamedPipeWriter: Failed to open pipe: $e');
				return;
			}
			
			var batchSize = 8;
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
				
				// Write batch to pipe
				try {
					for (frame in batch) {
						pipeOutput.write(frame);
					}
					pipeOutput.flush();
				} catch (e:Dynamic) {
					var err = Std.string(e);
					if (err.indexOf("EOF") != -1 || err.indexOf("Broken pipe") != -1 || err.indexOf("closed") != -1) {
						Sys.println("NamedPipeWriter: Pipe closed by reader");
						break;
					}
					Sys.println('NamedPipeWriter: Write error: $e');
					break;
				}
				
				// Return frames to pool
				for (frame in batch) returnFrame(frame);
				batch = [];
			}
			
			// Cleanup
			try {
				if (pipeOutput != null) pipeOutput.close();
			} catch (e:Dynamic) {}
			
			Sys.println('NamedPipeWriter: Writer thread exiting');
		});
	}
	
	/**
	 * Get a free frame buffer from the pool.
	 */
	static inline function getFreeFrame():Bytes {
		if (freeList.length > 0) return freeList.pop();
		return null;
	}
	
	/**
	 * Return a frame buffer to the pool.
	 */
	static inline function returnFrame(frame:Bytes) {
		if (frame != null) freeList.push(frame);
	}
	
	/**
	 * Enqueue a frame for writing.
	 */
	static function enqueueFrame(frame:Bytes) {
		frameQueue.push(frame);
	}
	
	/**
	 * Dequeue a frame for writing (thread-safe).
	 */
	static function dequeueFrame():Bytes {
		if (frameQueue.length > 0) return frameQueue.shift();
		return null;
	}
	
	/**
	 * Check if the writer is ready to accept frames.
	 */
	static inline function isReady():Bool {
		return isActive && !stopRequested;
	}
	
	/**
	 * Get queue status for monitoring.
	 */
	static function getQueueStatus():{queued:Int, free:Int} {
		return {
			queued: frameQueue.length,
			free: freeList.length
		};
	}
	
	/**
	 * Stop the writer and cleanup resources.
	 */
	static function stop() {
		if (!isActive) return;
		
		Sys.println("NamedPipeWriter: Stopping...");
		stopRequested = true;
		
		// Wait for queue to drain
		if (writerThread != null) {
			var startWait = haxe.Timer.stamp();
			while (frameQueue.length > 0 && (haxe.Timer.stamp() - startWait) < 5.0) {
				Sys.sleep(0.01);
			}
			Sys.sleep(0.1);
			writerThread = null;
		}
		
		// Cleanup pipe file (Unix only)
		#if !windows
		try {
			if (FileSystem.exists(pipePath)) {
				FileSystem.deleteFile(pipePath);
			}
		} catch (e:Dynamic) {
			Sys.println('NamedPipeWriter: Could not delete pipe file: $e');
		}
		#end
		
		// Cleanup on Windows
		#if windows
		try {
			if (pipeServerProcess != null) {
				pipeServerProcess.stdin.close();
				pipeServerProcess.kill();
				pipeServerProcess.close();
				pipeServerProcess = null;
			}
		} catch (e:Dynamic) {
			Sys.println('NamedPipeWriter: Error stopping pipe server: $e');
		}
		
		// Clean up script file
		try {
			var serverScriptPath = "namedpipe_server_" + pipeName + ".ps1";
			if (FileSystem.exists(serverScriptPath)) {
				FileSystem.deleteFile(serverScriptPath);
			}
		} catch (e:Dynamic) {}
		#end
		
		// Clear buffers
		frameQueue = [];
		freeList = [];
		
		isActive = false;
		Sys.println("NamedPipeWriter: Stopped");
	}
}