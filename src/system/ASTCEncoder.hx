package system;

import haxe.crypto.Sha256;
import sys.io.Process;
import sys.FileSystem;
import sys.io.File;
using StringTools;

/**
	Official ASTC encoder class for Funkin' View.
	Under the hood, it uses ASTCENC (ARM's ASTC encoder) that
	support multiple instruction sets, like SSE2, and all the
	way up to AVX2.

	Info: ASTC texture compression is natively supported on android
	whilst on desktop it's reserved for OpenGL extensions that
	have first been introduced since around 2014.
**/
@:final
@:publicFields
class ASTCEncoder {
	private static var VERSION = "avx2";
	private static var ENVPATH = "assets/images/tools/astcenc";
	private static var SUPPORT = true;

	// thx glm 5.2
    public static function checkAstcSupport(gl:PeoteGL):Bool {
        #if js
        return gl.getExtension("WEBGL_compressed_texture_astc") != null;
        #else
		//if (gl.getExtension("KHR_texture_compression_astc_ldr") != null) return true;
        var exts = gl.getSupportedExtensions();
        if (exts == null) return false;
        for (ext in exts) {
            if (ext == "KHR_texture_compression_astc_ldr") return true;
        }
        return false;
        #end
    }

	static function run(img:String) {
		var img_ktx = img.replace('.png', '.ktx');
		#if android // no phone compress textures on the phone itself. No, that would be extremely wasteful. That's reserved for PC only.
		if (FileSystem.exists(img_ktx)) return img_ktx;
		else if (FileSystem.exists(img)) return img;
		else throw 'No image called $img found.'; return "";
		#else
		SUPPORT = checkAstcSupport(Main.current.peoteView.gl);
		//trace('Is supported? $SUPPORT');
		if (!SUPPORT) return img;
		//if (!SaveData.state.graphics.compressTextures) return img;

		var pngBytes = File.getContent(img);
		var encoded = Sha256.encode(pngBytes);

		if (hashFileMatches(img, encoded) && FileSystem.exists(img_ktx))
			return img_ktx;
		else
			File.saveContent(getHashOfFile(img), encoded);

		if (FileSystem.exists(img_ktx)) return img_ktx;

		//Sys.println('[ System ] Running astc encoder step for $img');
		var args = buildArgs(img);
		//trace(args.join(" "));
		var processName = ENVPATH + '-' + VERSION;
		#if linux
		Sys.command("chmod", ["+x", processName])
		#end
		//var exitCode = Sys.command(processName, args);
		//trace("Attempted with exitCode: " + exitCode);
		var proc:Process = new Process(processName, args);
		if (proc.exitCode(true) != 0) { // unsuccessful or simd not supported
			Sys.exit(1);
			if (VERSION == "avx2") {
				trace("AVX2 not supported");
				VERSION = "sse4.1";
				run(img);
			}
			if (VERSION == "sse4.1") {
				trace("SSE4.1 not supported");
				VERSION = "sse2";
				run(img);
			}
			if (VERSION == "sse2") {
				trace("Can't support anything these days");
				SUPPORT = false; // Just don't at this point
			}
		} else {
			return img_ktx;
		}
		return img;
		#end
	}

	static function buildArgs(img:String) {
		var img_str = Sys.getCwd() + img;
		var img_ktx = img_str.replace('.png', '.ktx');
		return ['-cl', img_str, img_ktx, '4x4', '-fast', '-pp-premultiply'];
	}

	// SHA256 Coding

	inline static function getHashOfFile(img:String) {
		return img.replace(".png", "_hash.txt");
	}

	static function hashFileMatches(img:String, realPngHash:String) {
		var hash = getHashOfFile(img);
		if (!FileSystem.exists(hash)) {
			return false;
		}
		var pngHash = File.getContent(hash);
		return pngHash == realPngHash;
	}
}