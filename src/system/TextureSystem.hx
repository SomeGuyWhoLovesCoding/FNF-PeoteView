package system;

import lime.graphics.Image;
import sys.io.File;
using StringTools;

/**
	The texture system.
	@since Development
**/
#if !debug
@:noDebug
#end
@:final
@:publicFields
class TextureSystem {
	/**
		Where all the cached texture come from.
	**/
	static var pool:FakeStringMap<Texture> = new FakeStringMap<Texture>();

	/**
		Get an existing texture from the pool.
		@param key The texture to get from.
	**/
	inline static function getTexture(key:String) {
		var tex = pool.get(key);
		return tex;
	}

	/**
		Set the program's texture to the texture and key.
		@param prgm The program to set its texture to.
		@param key The texture to get from.
		@param name The texture's new name.
	**/
	inline static function setTexture(prgm:CustomProgram, key:String, name:String) {
		prgm.setTexture(getTexture(key), name, true);
	}

	/**
		Destroy the texture to free up VRAM.
		@param key The texture to destroy.
	**/
	static function disposeTexture(key:String) {
		if (!pool.exists(key)) return;
		var tex = getTexture(key);
		tex.dispose();
		pool.remove(key);
		tex = null;
	}

	/**
		Create a texture and put it in the texture pool.
		This only accepts a single texture slot.
		@param key The texture's key.
		@param path The texture path.
	**/
	static function createTexture(key:String, path:String, disableAntialiasing:Bool = false, premultiply:Bool = false) {
		if (pool.exists(key)) {
			return;
		}

		var currentSaveState = SaveData.state.graphics;
		var antialiasing = currentSaveState.antialiasing && !disableAntialiasing;

		var textureData:TextureData = null;
		var texPath = Paths.asset(path);
		var texPath2 = ASTCEncoder.run(texPath); // currentSaveState.compressTextures ? ASTCEncoder.run(texPath) : texPath;
		trace(texPath2);

        if (texPath2.endsWith('.ktx')) {
            var imgWidth:Int = 0;
            var imgHeight:Int = 0;
            var astcBytes:haxe.io.Bytes = null;
            
            // Open file in binary read mode
            var input= File.read(texPath2, true);
            
            try {
                // Check magic bytes
                if (input.readByte() != 0xAB || input.readByte() != 0x4B || input.readByte() != 0x54 || input.readByte() != 0x58) {
                    throw "Invalid KTX file";
                }
                
                // Seek to byte 36 to read width and height
                input.seek(36, SeekBegin);
                imgWidth = input.readInt32();
                imgHeight = input.readInt32();
                
                // Seek to byte 60 to read key-value data size
                input.seek(60, SeekBegin);
                var kvdSize:Int = input.readInt32();
                
                // Seek to the start of the image data size block
                var imageDataOffset:Int = 64 + kvdSize;
                input.seek(imageDataOffset, SeekBegin);
                var imageSize:Int = input.readInt32();
                
                // Allocate exactly the memory needed for the ASTC payload ONLY
                astcBytes = haxe.io.Bytes.alloc(imageSize);
                
                // Read directly from the file into our final buffer
                var bytesRead:Int = input.readBytes(astcBytes, 0, imageSize);
                if (bytesRead != imageSize) throw "Error: Reached end of KTX file unexpectedly.";
            } catch(e:Dynamic) {
                input.close();
                throw e;
            }
            
            // Close the file handle
            input.close();
            
            // Pass the cleanly extracted data to TextureData
            textureData = new TextureData(imgWidth, imgHeight, TextureFormat.ASTC_44, 0, astcBytes);
		} else {
			//trace("TEX PATH " + texPath);
			var image = Image.fromFile(texPath);

			// I'm proud of this fix, but it couldn't be better be this:
			textureData = !premultiply ? TextureData.fromLimeImage(image) : new TextureData(image.width, image.height, TextureFormat.RGBA);
			if (premultiply) {
				var bytes = image.data.toBytes();
				for (i in 0...textureData.bytes.length >> 2) {
					var fullARGB = bytes.getInt32(i << 2);

					var a = (fullARGB >>> 24) & 0xFF;
					var r = (fullARGB >>> 16) & 0xFF;
					var g = (fullARGB >>> 8)  & 0xFF;
					var b = (fullARGB)        & 0xFF;

					// Scale RGB by alpha
					r = (r * a) >> 8; // divide by 255
					g = (g * a) >> 8;
					b = (b * a) >> 8;

					var premul = (a << 24) | (r << 16) | (g << 8) | b;
					textureData.bytes.setInt32(i << 2, premul);
				}
			}
		}

		var texture = new Texture(textureData.width, textureData.height, null, {
			format: textureData.format,
			powerOfTwo: false,
			smoothExpand: antialiasing,
			smoothShrink: antialiasing
		});
		texture.setData(textureData);

		pool.set(key, texture);
	}
}
