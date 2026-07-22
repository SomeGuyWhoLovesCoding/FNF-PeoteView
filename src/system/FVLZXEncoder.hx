package system;

import sys.FileSystem;
import sys.io.File;
import sys.io.Process;
import haxe.io.Bytes;
import utils.LZ4;
import utils.Sha256;
import utils.MemoryTracker;
using StringTools;

/**
	Official ASTC+BC7 encoder class for Funkin' View.
	Under the hood, it uses ASTCENC (ARM's ASTC encoder) that
	support multiple instruction sets, like SSE2, and all the
	way up to AVX2. And, it also uses texconv (windows)

	Info: ASTC texture compression is natively supported on android
	whilst on desktop it's reserved for OpenGL extensions that
	have first been introduced since around 2014. Meanwhile,
    a secondary PC-primary BC7 texture compression is used by
    default and a png is compressed to it the background in parallel.
**/
@:final
@:publicFields
class FVLZXEncoder {
    private static var VERSION = "avx2";
    private static var ENVPATH = "assets/images/tools/astcenc";
    private static var SUPPORT = true;

    private static var staticReadBuffer:Bytes = Bytes.alloc(65536);
    private static var staticWriteBuffer:Bytes = Bytes.alloc(65536);
    private static var staticHeader:Bytes = Bytes.alloc(64);
    private static var staticSizeBytes:Bytes = Bytes.alloc(4);

    public static function checkAstcSupport(gl:PeoteGL):Bool {
        #if js
        return gl.getExtension("WEBGL_compressed_texture_astc") != null;
        #else
        var exts = gl.getSupportedExtensions();
        if (exts == null) return false;
        for (ext in exts) {
            if (ext == "KHR_texture_compression_astc_ldr") return true;
        }
        return false;
        #end
    }

    static function run(img:String):String {
        var img_ktx = img.replace('.png', '.fvlzas');
        #if android
        if (FileSystem.exists(img_ktx)) return img_ktx;
        else if (FileSystem.exists(img)) return img;
        else throw 'No image called $img found.';
        #else
        SUPPORT = checkAstcSupport(Main.current.peoteView.gl);
        if (!SUPPORT) return img;

        var encoded = FVLZXHashCode.hashEncode(img);

        if (FVLZXHashCode.matches(img, encoded) && FileSystem.exists(img_ktx))
            return img_ktx;
        else
            File.saveContent(FVLZXHashCode.file(img), encoded);

        if (FileSystem.exists(img_ktx)) return img_ktx;

        var args = buildArgs(img);
        var processName = ENVPATH + '-' + VERSION;
        #if linux
        Sys.command("chmod", ["+x", processName]);
        #end
        #if windows
        processName += ".exe";
        #end
        
        var proc = new Process(processName, args);
        var exitCode = proc.exitCode(true);
        proc.close();
        
        if (exitCode != 0) {
            if (VERSION == "avx2") {
                trace("AVX2 not supported, falling back to sse4.1");
                VERSION = "sse4.1";
                return run(img);
            }
            if (VERSION == "sse4.1") {
                trace("SSE4.1 not supported, falling back to sse2");
                VERSION = "sse2";
                return run(img);
            }
            if (VERSION == "sse2") {
                trace("CPU does not support required SIMD instructions for ASTC encoding.");
                SUPPORT = false;
            }
        } else {
            var img_ktxRaw = img.replace('.png', '.ktx');
            if (FileSystem.exists(img_ktxRaw)) {
                MemoryTracker.start("FVLZXEncoder.run (Compress)");
                try {
                    var fin = File.read(img_ktxRaw);
                    var bin = new haxe.io.BufferInput(fin, staticReadBuffer);
                    
                    bin.readFullBytes(staticHeader, 0, 64);
                    
                    var kvdSize = readInt32(staticHeader, 60);
                    var payloadOffset = 64 + kvdSize;
                    
                    bin.readFullBytes(staticSizeBytes, 0, 4);
                    var originalImageSize = readInt32(staticSizeBytes, 0);
                    
                    //trace("Compressing ASTC payload with LZ4...");
                    var pngSize = FileSystem.stat(img).size;
                    
                    var fout = File.write(img_ktxRaw + ".tmp", true);
                    var bout = new BufferOutput(fout, staticWriteBuffer);
                    
                    bout.writeBytes(staticHeader, 0, 64);
                    if (kvdSize > 0) {
                        var kvd = Bytes.alloc(kvdSize);
                        bin.readFullBytes(kvd, 0, kvdSize);
                        bout.writeBytes(kvd, 0, kvdSize);
                        kvd = null;
                    }

                    bout.writeByte(0); bout.writeByte(0); bout.writeByte(0); bout.writeByte(0);
                    
                    var compressedLen = LZ4.compressStream(bin, originalImageSize, bout);
                    //trace("LZ4 compressed: " + originalImageSize + " -> " + compressedLen + " bytes (PNG: " + pngSize + " bytes)");
                    
                    bin.close();
                    fin.close();
                    bout.close();
                    fout.close();
                    
                    var fpatch = File.update(img_ktxRaw + ".tmp");
                    fpatch.seek(payloadOffset, SeekBegin);
                    fpatch.writeByte(compressedLen & 0xFF);
                    fpatch.writeByte((compressedLen >> 8) & 0xFF);
                    fpatch.writeByte((compressedLen >> 16) & 0xFF);
                    fpatch.writeByte((compressedLen >> 24) & 0xFF);
                    fpatch.close();
                    
                    FileSystem.deleteFile(img_ktxRaw);
                    FileSystem.rename(img_ktxRaw + ".tmp", img_ktx);
                } catch (e:Dynamic) {
                    MemoryTracker.end();
                    throw e;
                }
                MemoryTracker.end();
            } else {
                trace("Warning: astcenc succeeded, but KTX file not found at: " + img_ktxRaw);
            }
            return img_ktx;
        }
        return img;
        #end
    }

    static function buildArgs(img:String):Array<String> {
        var img_str = Sys.getCwd() + img;
        var img_ktx = img_str.replace('.png', '.ktx');
        return ['-cl', img_str, img_ktx, '4x4', '-fast', '-pp-premultiply', '-thread_count', '1'];
    }

    public static function loadTextureData(ktxPath:String):TextureData {
        if (!FileSystem.exists(ktxPath)) return null;

        var fin = File.read(ktxPath);
        var bin = new haxe.io.BufferInput(fin, staticReadBuffer);

        try {
            bin.readFullBytes(staticHeader, 0, 64);
            
            if (staticHeader.get(0) != 0xAB || staticHeader.get(1) != 0x4B || staticHeader.get(2) != 0x54 || staticHeader.get(3) != 0x58) {
                throw "Invalid KTX file magic bytes";
            }
            
            var imgWidth = readInt32(staticHeader, 36);
            var imgHeight = readInt32(staticHeader, 40);
            var kvdSize = readInt32(staticHeader, 60);
            var payloadOffset = 64 + kvdSize;
            
            if (kvdSize > 0) {
                var dummyKvd = Bytes.alloc(kvdSize);
                bin.readFullBytes(dummyKvd, 0, kvdSize);
                dummyKvd = null;
            }
            
            bin.readFullBytes(staticSizeBytes, 0, 4);
            var storedSize = readInt32(staticSizeBytes, 0);
            
            var blocksX = Math.ceil(imgWidth / 4);
            var blocksY = Math.ceil(imgHeight / 4);
            var expectedRawSize = Std.int(blocksX * blocksY * 16);

            // Start tracking. This allocation is the absolute minimum required 
            // to hand the data to the OpenGL driver.
            MemoryTracker.start("FVLZXEncoder.loadTextureData");
            
            // Allocate the final buffer directly. No scratchpad, no sub() copy!
            var astcBytes = Bytes.alloc(expectedRawSize);

            if (storedSize == expectedRawSize) {
                bin.readFullBytes(astcBytes, 0, expectedRawSize);
            } else {
                var written = LZ4.decompressFromInput(bin, astcBytes, expectedRawSize);
                if (written != expectedRawSize) {
                    MemoryTracker.end();
                    throw "Decompressed size mismatch! Expected " + expectedRawSize + " but got " + written;
                }
            }
            
            bin.close();
            fin.close();
            
            var result = new TextureData(imgWidth, imgHeight, TextureFormat.ASTC_44, 0, astcBytes);
            
            MemoryTracker.end();
			//Sys.println('[MemoryTracker] Texture size was $imgWidth x $imgHeight');
            return result;
        } catch(e:Dynamic) {
            bin.close();
            fin.close();
            try { MemoryTracker.end(); } catch(e:Dynamic) {}
            throw "Failed to parse KTX at " + ktxPath + ": " + e;
        }
    }

    private static inline function readInt32(b:Bytes, pos:Int):Int {
        return b.get(pos) | (b.get(pos + 1) << 8) | (b.get(pos + 2) << 16) | (b.get(pos + 3) << 24);
    }
}

private class BufferOutput extends haxe.io.Output {
    var out: haxe.io.Output;
    var buf: Bytes;
    var pos: Int = 0;

    public function new(out: haxe.io.Output, buf: Bytes) {
        this.out = out;
        this.buf = buf;
    }

    override function writeByte(b: Int): Void {
        if (pos == buf.length) flush();
        buf.set(pos++, b);
    }

    override function writeBytes(s: Bytes, pos: Int, len: Int): Int {
        var written = 0;
        while (len > 0) {
            if (this.pos == buf.length) flush();
            var chunk = len < (buf.length - this.pos) ? len : (buf.length - this.pos);
            buf.blit(this.pos, s, pos, chunk);
            this.pos += chunk;
            pos += chunk;
            len -= chunk;
            written += chunk;
        }
        return written;
    }

    public override function flush(): Void {
        if (pos > 0) {
            out.writeBytes(buf, 0, pos);
            pos = 0;
        }
    }

    override function close(): Void {
        flush();
        out.close();
    }
}

@:publicFields
private class FVLZXHashCode {
    inline static function file(img:String):String {
        return img.replace(".png", "_hash.txt");
    }

    static function matches(img:String, realPngHash:String):Bool {
        var hash = file(img);
        if (!FileSystem.exists(hash)) return false;
        var pngHash = File.getContent(hash);
        return pngHash == realPngHash;
    }

    static function hashEncode(img:String):String {
        var fin = File.read(img);
        var pngSize = FileSystem.stat(img).size;
        var hashBytes = Sha256.makeFromInput(fin, pngSize);
        fin.close();
        return hashBytes.toHex();
    }
}