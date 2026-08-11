package system;

import haxe.io.Bytes;
import lime.graphics.Image;
import sys.FileSystem;
import sys.io.File;
import utils.Sha256;

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

	static var loadQueue:Array<{
		key:String,
		path:String,
		disableAntialiasing:Bool,
		premultiply:Bool
	}> = [];

	/**
		Get an existing texture from the pool.
		@param key The texture to get from.
	**/
	inline static function getTexture(key:String) {
		return pool.get(key);
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

	inline static function queueLength() {
		return loadQueue.length;
	}

	/**
		Destroy the texture to free up VRAM.
		@param key The texture to destroy.
	**/
	static function disposeTexture(key:String) {
		if (!pool.exists(key))
			return;
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
				// 1 byte per pixel for ASTC/BPTC, 4 bytes for RGBA
				bytes += texture.width * texture.height * texture.format.bytesPerPixel;
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
		if (pool.exists(key))
			return;

		#if !android
		if (Main.current.peoteView == null || Main.current.peoteView.gl == null && saveToPool) {
			loadQueue.push({
				key: key,
				path: path,
				disableAntialiasing: disableAntialiasing,
				premultiply: premultiply
			});
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
		//BOTTLENECK: [mid] two full stop-the-world GC sweeps (cpp.vm.Gc.run(false)+run(true)) per queue batch -> GC pause stall on load/state-switch path | FIX: trigger GC on idle frame hook instead of inline; single sweep only
		GC.run(1);
		// haxe.Timer.delay(() -> {
		// 	GC.run(5);
		// }, 100);
	}

	static function actuallyCreateTexture(key:String, path:String, disableAntialiasing:Bool = false, premultiply:Bool = false) {
		var currentSaveState = SaveData.state;
		var antialiasing = currentSaveState.preferences.antialiasing && !disableAntialiasing;
		var compressTextures = currentSaveState.graphics.compressTextures;

		var textureData:TextureData = null;
		var texPath = Paths.asset(path);
		//BOTTLENECK: [ultra] synchronous external-process spawn (astcenc/bc7) + blocking encode/disk IO on main thread for EVERY texture load, including mid-gameplay actor/noteskin swaps -> multi-second framerate hitch | FIX: run texture load+encode on a worker/async thread, cache compressed artifacts, only block on GPU upload
		// FIX: safe-scope subset - reuse a verified-fresh compressed artifact (skips the encoder subprocess entirely) and never invoke the encoder when compression is disabled
		var compTexRun:Null<String> = null;
		if (compressTextures) {
			if (texPath.endsWith(".png")) {
				compTexRun = getCachedCompressedTexture(texPath);
				if (compTexRun == null) {
					var hadBC7 = FileSystem.exists(compressedPath(texPath, "fvlzbc"));
					var hadASTC = FileSystem.exists(compressedPath(texPath, "fvlza"));
					compTexRun = FVLZXEncoder.run(texPath);
					if (compTexRun != null) {
						var fresh = compTexRun.endsWith(".fvlzbc") ? !hadBC7 : compTexRun.endsWith(".fvlza") ? !hadASTC : false;
						if (fresh)
							writeCompressedArtifactMeta(texPath, compTexRun);
					}
				}
			} else {
				compTexRun = FVLZXEncoder.run(texPath);
			}
		}

		if (compTexRun != null && compressTextures) {
			textureData = FVLZXEncoder.loadTextureData(texPath);
		} else {
			var image = Image.fromFile(texPath);
			if (!premultiply) {
				textureData = TextureData.fromLimeImage(image);
			} else {
				var bytes = image.data.toBytes();
				//BOTTLENECK: [high] per-pixel premultiply loop = getInt32/setInt32 native call per pixel (~2-12M calls on a 2048x2048 atlas) plus a full image.data.toBytes() copy of every loaded texture | FIX: premultiply in-place on the image buffer with a tight byte loop, or vectorize per-row; reuse one scratch buffer
				premultiplyAlphaInPlace(bytes);
				textureData = new TextureData(image.width, image.height, TextureFormat.RGBA, 0, bytes);
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

	// FIX: safe-scope compressed-artifact cache (see [ultra] marker in actuallyCreateTexture).
	// A sidecar "<artifact>.meta" stores "<settingsSignature>\n<pngSha256>\n"; a hit needs
	// the artifact AND sidecar present AND both fields to match, so a stale artifact is never served.
	static function compressedPath(texPath:String, ext:String):String {
		return texPath.replace(".png", "." + ext);
	}

	static function getCachedCompressedTexture(texPath:String):Null<String> {
		var bc7 = compressedPath(texPath, "fvlzbc");
		var astc = compressedPath(texPath, "fvlza");
		if (FileSystem.exists(bc7) && artifactIsFresh(texPath, bc7))
			return bc7;
		if (FileSystem.exists(astc) && artifactIsFresh(texPath, astc))
			return astc;
		return null;
	}

	static function artifactIsFresh(texPath:String, artifactPath:String):Bool {
		var sidecar = artifactPath + ".meta";
		if (!FileSystem.exists(sidecar))
			return false;
		var expected = artifactSettingsSignature(artifactPath) + "\n" + pngSha256(texPath) + "\n";
		return File.getContent(sidecar) == expected;
	}

	static function writeCompressedArtifactMeta(texPath:String, artifactPath:String):Void {
		// Only called right after FVLZXEncoder freshly produced the artifact, so the
		// recorded PNG hash + settings signature provably describe that artifact.
		try {
			var meta = artifactSettingsSignature(artifactPath) + "\n" + pngSha256(texPath) + "\n";
			File.saveContent(artifactPath + ".meta", meta);
		} catch (e:Dynamic) {
			// Immutable/read-only assets dir: cache just never engages.
		}
	}

	static function artifactSettingsSignature(artifactPath:String):String {
		// MUST mirror FVLZXEncoder.buildArgs()/runBC7() flags; bump the version when those change.
		if (artifactPath.endsWith(".fvlzbc"))
			return "bc7:v1:pmalpha";
		return "astc:v1:4x4:fast:pp-premultiply";
	}

	static function pngSha256(texPath:String):String {
		var fin = File.read(texPath);
		var hashBytes = Sha256.makeFromInput(fin, FileSystem.stat(texPath).size);
		fin.close();
		return hashBytes.toHex();
	}

	static inline function premultiplyAlphaInPlace(bytes:Bytes):Void {
		var n = bytes.length;
		var p = 0;
		while (p < n) {
			var r = bytes.get(p);
			var g = bytes.get(p + 1);
			var b = bytes.get(p + 2);
			var a = bytes.get(p + 3);
			bytes.set(p, (r * a) >> 8);
			bytes.set(p + 1, (g * a) >> 8);
			bytes.set(p + 2, (b * a) >> 8);
			p += 4;
		}
	}
}
