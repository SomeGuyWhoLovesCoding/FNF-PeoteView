package ffmpeg;

import sys.net.Socket;
import sys.net.Host;
import haxe.io.Bytes;
import sys.thread.Thread;

/**
 * Network streamer for sending raw video frames to a remote FFmpeg encoder.
 * Allows offloading encoding to another machine for better performance.
 */
@:publicFields
class NetworkStreamer {
	
	private static var socket:Socket;
	private static var writerThread:Thread;
	private static var frameQueue:Array<Bytes> = [];
	private static var freeList:Array<Bytes> = [];
	private static var stopRequested:Bool = false;
	private static var isActive:Bool = false;
	private static var connected:Bool = false;
	
	private static var host:String;
	private static var port:Int;
	
	/**
	 * Initialize network streaming.
	 * @param targetHost IP address or hostname of encoding machine
	 * @param targetPort Port number (default 8888)
	 * @param frameSize Size of each frame in bytes
	 * @param queueSize Number of frames to pre-allocate
	 */
	static function init(targetHost:String, targetPort:Int, frameSize:Int, queueSize:Int):Bool {
		if (isActive) {
			Sys.println("NetworkStreamer: Already initialized");
			return true;
		}
		
		host = targetHost;
		port = targetPort;
		
		// Initialize frame pool
		freeList = [];
		frameQueue = [];
		for (i in 0...queueSize) {
			freeList.push(Bytes.alloc(frameSize));
		}
		
		// Connect to remote encoder
		try {
			Sys.println('NetworkStreamer: Connecting to $host:$port...');
			socket = new Socket();
			socket.connect(new Host(host), port);
			socket.setBlocking(true);
			socket.setFastSend(true); // Disable Nagle's algorithm
			connected = true;
			Sys.println('NetworkStreamer: Connected!');
		} catch (e:Dynamic) {
			Sys.println('NetworkStreamer: Connection failed: $e');
			Sys.println('NetworkStreamer: Make sure FFmpeg is listening on $host:$port');
			return false;
		}
		
		isActive = true;
		stopRequested = false;
		
		return true;
	}
	
	/**
	 * Start the writer thread that streams frames over the network.
	 */
	static function startWriter() {
		if (writerThread != null) return;
		
		writerThread = Thread.create(function() {
			Sys.println('NetworkStreamer: Writer thread started');
			
			var batchSize = 32; // Larger batches for network efficiency
			var batch:Array<Bytes> = [];
			var totalBytes:Int = 0;
			var frameCount:Int = 0;
			var lastReport:Float = haxe.Timer.stamp();
			
			while (!stopRequested && connected) {
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
				
				// Send batch over network
				try {
					for (frame in batch) {
						socket.output.write(frame);
						totalBytes += frame.length;
						frameCount++;
					}
					socket.output.flush();
					
					// Report stats every 5 seconds
					var now = haxe.Timer.stamp();
					if (now - lastReport >= 5.0) {
						var mbps = (totalBytes / (1024 * 1024)) / (now - lastReport) * 8;
						var fps = frameCount / (now - lastReport);
						Sys.println('NetworkStreamer: ${Math.round(fps)} fps, ${Math.round(mbps)} Mbps, queue: ${frameQueue.length}');
						totalBytes = 0;
						frameCount = 0;
						lastReport = now;
					}
				} catch (e:Dynamic) {
					var err = Std.string(e);
					Sys.println('NetworkStreamer: Send error: $e');
					connected = false;
					break;
				}
				
				// Return frames to pool
				for (frame in batch) returnFrame(frame);
				batch = [];
			}
			
			Sys.println('NetworkStreamer: Writer thread exiting');
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
	 * Enqueue a frame for streaming.
	 */
	static function enqueueFrame(frame:Bytes) {
		frameQueue.push(frame);
	}
	
	/**
	 * Dequeue a frame for streaming (thread-safe).
	 */
	static function dequeueFrame():Bytes {
		if (frameQueue.length > 0) return frameQueue.shift();
		return null;
	}
	
	/**
	 * Check if the streamer is ready to accept frames.
	 */
	static inline function isReady():Bool {
		return isActive && connected && !stopRequested;
	}
	
	/**
	 * Get queue and connection status.
	 */
	static function getStatus():{queued:Int, free:Int, connected:Bool} {
		return {
			queued: frameQueue.length,
			free: freeList.length,
			connected: connected
		};
	}
	
	/**
	 * Stop streaming and cleanup.
	 */
	static function stop() {
		if (!isActive) return;
		
		Sys.println("NetworkStreamer: Stopping...");
		stopRequested = true;
		
		// Wait for queue to drain
		if (writerThread != null) {
			var startWait = haxe.Timer.stamp();
			while (frameQueue.length > 0 && (haxe.Timer.stamp() - startWait) < 5.0) {
				Sys.sleep(0.01);
			}
			Sys.println('NetworkStreamer: Queue drained, ${frameQueue.length} frames remaining');
			Sys.sleep(0.1);
			writerThread = null;
		}
		
		// Close socket
		try {
			if (socket != null) {
				socket.close();
				socket = null;
			}
		} catch (e:Dynamic) {
			Sys.println('NetworkStreamer: Error closing socket: $e');
		}
		
		// Clear buffers
		frameQueue = [];
		freeList = [];
		
		connected = false;
		isActive = false;
		Sys.println("NetworkStreamer: Stopped");
	}
	
	/**
	 * Get the FFmpeg command for the remote encoding machine.
	 */
	static function getRemoteFFmpegCommand(width:Int, height:Int, fps:Float, outputFile:String):String {
		return 'ffmpeg -listen 1 -f rawvideo -pix_fmt rgb565 -s ${width}x${height} -r $fps -i tcp://0.0.0.0:$port?listen -vf vflip -c:v h264_nvenc -preset p1 -tune ull -rc constqp -qp 31 -an "$outputFile"';
	}
	
	/**
	 * Get local machine's IP addresses.
	 * Returns all non-loopback IPv4 addresses found.
	 */
	static function getLocalIPs():Array<String> {
		var ips:Array<String> = [];
		
		try {
			#if windows
			// Windows: use ipconfig
			var process = new sys.io.Process('ipconfig', []);
			var output = process.stdout.readAll().toString();
			process.close();
			
			// Parse IPv4 addresses from ipconfig output
			var lines = output.split('\n');
			for (line in lines) {
				line = StringTools.trim(line);
				if (line.indexOf('IPv4') != -1) {
					// Extract IP from line like "   IPv4 Address. . . . . . . . . . . : 192.168.1.100"
					var parts = line.split(':');
					if (parts.length >= 2) {
						var ip = StringTools.trim(parts[1]);
						// Remove any trailing junk
						ip = ip.split('(')[0];
						ip = StringTools.trim(ip);
						if (ip != '' && ip != '127.0.0.1') {
							ips.push(ip);
						}
					}
				}
			}
			#elseif (linux || mac)
			// Linux/Mac: use ip addr or ifconfig
			var cmd = sys.FileSystem.exists('/sbin/ip') ? 'ip' : 'ifconfig';
			var args = cmd == 'ip' ? ['addr'] : [];
			
			var process = new sys.io.Process(cmd, args);
			var output = process.stdout.readAll().toString();
			process.close();
			
			// Parse IPs using regex
			var ipRegex = ~/inet\s+(\d+\.\d+\.\d+\.\d+)/g;
			while (ipRegex.match(output)) {
				var ip = ipRegex.matched(1);
				if (ip != '127.0.0.1') {
					ips.push(ip);
				}
				output = ipRegex.matchedRight();
			}
			#else
			// Fallback: try to detect via socket connection
			try {
				var testSocket = new Socket();
				testSocket.connect(new Host('8.8.8.8'), 53); // Connect to Google DNS
				var localAddr = testSocket.host();
				testSocket.close();
				if (localAddr.ip != 0 && localAddr.toString() != '127.0.0.1') {
					ips.push(localAddr.toString());
				}
			} catch (e:Dynamic) {}
			#end
		} catch (e:Dynamic) {
			Sys.println('NetworkStreamer: Could not detect local IPs: $e');
		}
		
		// If we found nothing, add localhost as fallback
		if (ips.length == 0) {
			ips.push('127.0.0.1');
		}
		
		return ips;
	}
	
	/**
	 * Print local IP information for user convenience.
	 */
	static function printLocalIPInfo() {
		Sys.println("");
		Sys.println("=== LOCAL IP ADDRESSES ===");
		var ips = getLocalIPs();
		for (i in 0...ips.length) {
			Sys.println('  [${i+1}] ${ips[i]}');
		}
		Sys.println("");
		Sys.println("On your encoding machine, run:");
		Sys.println('  ffmpeg -listen 1 -f rawvideo -pix_fmt rgb565 \\');
		Sys.println('    -s WIDTHxHEIGHT -r FPS \\');
		Sys.println('    -i tcp://0.0.0.0:$port?listen \\');
		Sys.println('    -vf vflip -c:v h264_nvenc -preset p1 \\');
		Sys.println('    -tune ull -rc constqp -qp 31 -an output.mp4');
		Sys.println("");
		Sys.println("Then connect from this machine (${ips[0]}) to encoding machine's IP");
		Sys.println("==========================");
		Sys.println("");
	}
}