// src/ffmpeg/PersistentPBO.hx
package ffmpeg;

import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.utils.DataPointer;

class PersistentPBO {
	// GL constants
	static public final PIXEL_PACK_BUFFER = 0x88EB;
	static public final MAP_READ_BIT = 0x0001;
	static public final MAP_WRITE_BIT = 0x0002;
	static public final MAP_PERSISTENT_BIT = 0x0040;
	static public final MAP_COHERENT_BIT = 0x0080;
	static public final CLIENT_STORAGE_BIT = 0x0200;
	
	public var buffer:GLBuffer;
	public var mappedPtr:DataPointer;
	public var size:Int;
	public var index:Int;
	
	public function new(size:Int, index:Int, usePersistent:Bool) {
		this.size = size;
		this.index = index;
		
		buffer = GL.createBuffer();
		GL.bindBuffer(PIXEL_PACK_BUFFER, buffer);
		
		if (usePersistent) {
			var flags = MAP_READ_BIT | MAP_WRITE_BIT | MAP_PERSISTENT_BIT | MAP_COHERENT_BIT | CLIENT_STORAGE_BIT;
			GL.bufferStorage(PIXEL_PACK_BUFFER, size, cast null, flags);
			mappedPtr = GL.mapBufferRange(PIXEL_PACK_BUFFER, 0, size, flags);
		} else {
			GL.bufferData(PIXEL_PACK_BUFFER, size, cast null, GL.STREAM_COPY);
			mappedPtr = cast null;
		}
		
		GL.bindBuffer(PIXEL_PACK_BUFFER, null);
	}
	
	public function bind() {
		GL.bindBuffer(PIXEL_PACK_BUFFER, buffer);
	}
	
	public function unbind() {
		GL.bindBuffer(PIXEL_PACK_BUFFER, null);
	}
	
	public function readPixels(x:Int, y:Int, width:Int, height:Int) {
		bind();
		GL.readPixels(x, y, width, height, 0x80E1, GL.UNSIGNED_BYTE, cast 0);
		unbind();
	}
	
	public function destroy() {
		if (mappedPtr != cast null) {
			bind();
			GL.unmapBuffer(PIXEL_PACK_BUFFER);
			unbind();
		}
		GL.deleteBuffer(buffer);
	}
}