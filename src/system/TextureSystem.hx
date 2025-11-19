package system;

import lime.graphics.Image;
import sys.io.File;

/**
	The texture system.
**/
#if !debug
@:noDebug
#end
@:publicFields
class TextureSystem {
	/**
		The texture pool.
	**/
	static var pool:Map<String, Texture> = [];

	static var noteTex(default, null):Texture;
	static var sustainTex(default, null):Texture;

	/**
		The multitexture location map.
	**/
	static var multitexLocMap:Map<String, Array<Int>> = [];

	/**
		Get a pre-existing texture from pool.
		@param key The texture to get from.
	**/
	inline static function getTexture(key:String) {
		var tex = null;
		switch (key) {
			case "noteTex": tex = noteTex;
			case "sustainTex": tex = sustainTex;
			default: tex = pool[key];
		}
		return tex;
	}

	/**
		Set the program's texture to the texture and key.
		@param prgm The program to set its texture to.
		@param key The texture to get from.
		@param name The texture's new name.
	**/

	inline static function setTexture(prgm:Program, key:String, name:String) {
		prgm.setTexture(getTexture(key), name, true);
	}

	/**
		Set the program's texture to the texture and key.
		@param prgm The program to set its texture to.
		@param key The texture to get from.
		@param name The texture's new name.
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

		var image = Image.fromFile(Paths.asset(path));

		// I'm proud of this fix, but it couldn't be better be this:
		var textureData = !premultiply ? TextureData.fromLimeImage(image) : new TextureData(image.width, image.height, TextureFormat.RGBA);
		if (premultiply) {
			textureData.bytes = haxe.io.Bytes.alloc(image.width * image.height * 4);
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

		var texture = new Texture(textureData.width, textureData.height, null, {
			format: textureData.format,
			powerOfTwo: false,
			smoothExpand: antialiasing,
			smoothShrink: antialiasing
		});
		texture.setData(textureData);

		if (key == "noteTex") noteTex = texture;
		else if (key == "sustainTex") sustainTex = texture;
		else pool[key] = texture;
	}

	/**
		Create a tiled texture and put it in the texture pool.
		This accepts horizontal and/or vertical tiled textures.
		@param key The texture's key.
		@param path The texture path.
	**/
	static function createTiledTexture(key:String, path:String, tX:Int = 1, tY:Int = 1, disableAntialiasing:Bool = false, premultiply:Bool = false) {
		if (pool.exists(key)) {
			return;
		}

		var currentSaveState = SaveData.state.graphics;
		var antialiasing = currentSaveState.antialiasing && !disableAntialiasing;

		var image = Image.fromFile(Paths.asset(path));

		// I'm proud of this fix, but it couldn't be better be this:
		var textureData = !premultiply ? TextureData.fromLimeImage(image) : new TextureData(image.width, image.height, TextureFormat.RGBA);
		if (premultiply) {
			textureData.bytes = haxe.io.Bytes.alloc(image.width * image.height * 4);
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

		var texture = new Texture(textureData.width, textureData.height, null, {
			tilesX: tX,
			tilesY: tY,
			format: textureData.format,
			powerOfTwo: false,
			smoothExpand: antialiasing,
			smoothShrink: antialiasing
		});
		texture.setData(textureData);

		if (key == "noteTex") noteTex = texture;
		else if (key == "sustainTex") sustainTex = texture;
		pool[key] = texture;
	}
}