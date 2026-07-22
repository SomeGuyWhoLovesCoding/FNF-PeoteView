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
    static var loadQueue:Array<{key:String, path:String, disableAntialiasing:Bool, premultiply:Bool}> = [];

	/**
		Get an existing texture from the pool.
		@param key The texture to get from.
	**/
    inline static function getTexture(key:String) { return pool.get(key); }

	/**
		Set the program's texture to the texture and key.
		@param prgm The program to set its texture to.
		@param key The texture to get from.
		@param name The texture's new name.
	**/
    inline static function setTexture(prgm:CustomProgram, key:String, name:String) { prgm.setTexture(getTexture(key), name, true); }
    inline static function queueLength() { return loadQueue.length; }

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
    static function VRAMCounter():String {
        var bytes:Float = 0;
        
        for (key in pool.keys) {
            var texture = pool.get(key);
            if (texture != null) {
                // 1 byte per pixel for ASTC/BC7, 4 bytes for RGBA
                bytes += texture.width * texture.height * (texture.format.isCompressed ? 1 : 4);
            }
        }

        var val:Float = bytes;
        var unit = "B";

        // Standard memory division (1024)
        if (bytes >= 1000000000) { // GiB
            val = bytes / 1000000000.0;
            unit = "GB";
        } else if (bytes >= 1000000) { // MiB
            val = bytes / 1000000.0;
            unit = "MB";
        } else if (bytes >= 1000) { // KiB
            val = bytes / 1000.0;
            unit = "KB";
        }

        // If it's just bytes, return it as an integer
        if (unit == "B") {
            return Std.int(val) + unit;
        }

        // Safely format to exactly 1 decimal place without string splicing hacks
        var rounded = Std.int(val * 10);
        var intPart = Std.int(rounded / 10);
        var decPart = Std.int(rounded % 10);
        
        return '$intPart.$decPart$unit';
    }

	/**
		Create a texture and put it in the texture pool.
		This only accepts a single texture slot.
		@param key The texture's key.
		@param path The texture path.
	**/
    static function createTexture(key:String, path:String, disableAntialiasing:Bool = false, premultiply:Bool = false, saveToPool:Bool = false) {
        if (pool.exists(key)) return;

        #if !android
        if (Main.current.peoteView == null || Main.current.peoteView.gl == null && saveToPool) {
            loadQueue.push({key: key, path: path, disableAntialiasing: disableAntialiasing, premultiply: premultiply});
            return;
        }
        #end

        actuallyCreateTexture(key, path, disableAntialiasing, premultiply);
    }
    
    public static function processQueue() {
        while (loadQueue.length > 0) {
            var q = loadQueue.shift();
            actuallyCreateTexture(q.key, q.path, q.disableAntialiasing, q.premultiply);
        }
        
        // FIX: Now that all textures are uploaded and all intermediate bytes are orphaned,
        // force a single GC sweep to instantly reclaim the 180MB of spike memory.
        GC.run(1);
		// haxe.Timer.delay(() -> {
		// 	GC.run(5);
		// }, 100);
    }

    static function actuallyCreateTexture(key:String, path:String, disableAntialiasing:Bool = false, premultiply:Bool = false) {
        var currentSaveState = SaveData.state.graphics;
        var antialiasing = currentSaveState.antialiasing && !disableAntialiasing;

        var textureData:TextureData = null;
        var texPath = Paths.asset(path);
        var texPath2 = FVLZXEncoder.run(texPath);

        if (texPath2.endsWith('.fvlzas')) {
            textureData = FVLZXEncoder.loadTextureData(texPath2);
        } else {
            var image = Image.fromFile(texPath);
            textureData = !premultiply ? TextureData.fromLimeImage(image) : new TextureData(image.width, image.height, TextureFormat.RGBA);
            
            if (premultiply) {
                var bytes = image.data.toBytes();
                for (i in 0...textureData.bytes.length >> 2) {
                    var fullARGB = bytes.getInt32(i << 2);
                    var a = (fullARGB >>> 24) & 0xFF;
                    var r = (fullARGB >>> 16) & 0xFF;
                    var g = (fullARGB >>> 8)  & 0xFF;
                    var b = (fullARGB)        & 0xFF;
                    r = (r * a) >> 8;
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
        
        #if !android
        @:privateAccess texture.setNewGLContext(Main.current.peoteView.gl);
        #end
        
        texture.setData(textureData);

        pool.set(key, texture);
        textureData = null;
    }
}