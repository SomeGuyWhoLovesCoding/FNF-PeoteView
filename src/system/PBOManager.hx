package system;

import lime.graphics.opengl.GL;

@:publicFields
class PBOManager {
	static var buffers:Array<haxe.io.UInt8Array>;
	static var bufferIndex:Int = 0;
	static var bufferSize:Int;
	static var width:Int;
	static var height:Int;
	static var initialized:Bool = false;
	static var firstFrame:Bool = true;
	
	static function init(w:Int, h:Int) {
		width = w;
		height = h;
		bufferSize = width * height * 4;
		
		Sys.println('PBOManager - Initializing double-buffer for ${width}x${height} (${Math.ceil(bufferSize * 2 / 1024 / 1024)}MB total)...');
		
		// Create 2 buffers for ping-pong
		buffers = [];
		buffers.push(new haxe.io.UInt8Array(bufferSize));
		buffers.push(new haxe.io.UInt8Array(bufferSize));
		
		bufferIndex = 0;
		firstFrame = true;
		initialized = true;
		
		Sys.println('PBOManager - Initialized (Note: True PBOs not supported by Lime, using double-buffer)');
	}
	
	// Capture current frame into one buffer, return previous frame from other buffer
	static function captureFrame(gl:PeoteGL):haxe.io.UInt8Array {
		if (!initialized) return null;
		
		var writeBuffer = buffers[bufferIndex];
		var readIndex = (bufferIndex + 1) % 2;
		var readBuffer = buffers[readIndex];
		
		// Read current frame into write buffer
		gl.readPixels(0, 0, width, height, GL.RGBA, GL.UNSIGNED_BYTE, writeBuffer);
		
		var result:haxe.io.UInt8Array = null;
		
		// Return previous frame (except on first frame)
		if (!firstFrame) {
			result = readBuffer;
		} else {
			firstFrame = false;
		}
		
		// Swap buffers
		bufferIndex = readIndex;
		
		return result;
	}
	
	static function cleanup() {
		if (!initialized) return;
		
		Sys.println('PBOManager - Cleaning up...');
		
		buffers = null;
		initialized = false;
		firstFrame = true;
		
		Sys.println('PBOManager - Cleaned up');
	}
}