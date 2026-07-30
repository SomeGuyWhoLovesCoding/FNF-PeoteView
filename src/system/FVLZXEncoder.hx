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
	supports multiple instruction sets, like SSE2, and all the
	way up to AVX2. It also utilizes a custom multithreaded 
	scalar BC7 encoder with atomic work stealing for optimal 
	CPU load balancing and minimal tail latency.

	Info: ASTC texture compression is natively supported on android
	whilst on desktop it's reserved for OpenGL extensions that
	have first been introduced since around 2014. Meanwhile,
    a secondary PC-primary BC7 texture compression is used as
    the primary format, processed synchronously to prevent race 
    conditions and CPU oversubscription.
    
    Output extensions:
    - ASTC: .fvlzas
    - BC7:  .fvlzbs
    
    Returns:
    - The path to the compressed texture (.fvlzbs or .fvlzas) on success.
    - null if compression is unsuccessful, unsupported, or falls back to uncompressed.
**/
@:final
@:publicFields
class FVLZXEncoder {
    private static var VERSION = "avx2";
    private static var ENVPATH = "assets/images/tools/astcenc";
    private static var BC7_ENVPATH = "assets/images/tools/bc7";
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

    /**
     * Main entry point. Prioritizes BC7 first (guarded behind !android), 
     * then falls back to ASTC second.
     * Returns the compressed path on success, or null if it must fall back to the original PNG.
     */
    public static function run(img:String):Null<String> {
        #if !android
        // Priority 1: BC7 (PC-primary, multithreaded scalar with atomic work stealing)
        var bc7Result = runBC7(img);
        if (bc7Result != null) return bc7Result;
        #end

        // Priority 2: ASTC (Primary for Android, fallback for PC if BC7 fails)
        return runASTC(img);
    }

    private static function runASTC(img:String):Null<String> {
        var img_fvlzas = img.replace('.png', '.fvlzas');
        if (FileSystem.exists(img_fvlzas)) return img_fvlzas;

        SUPPORT = checkAstcSupport(Main.current.peoteView.gl);
        if (!SUPPORT) return null;

        var encoded = FVLZXHashCode.hashEncode(img);
        if (FVLZXHashCode.matches(img, encoded) && FileSystem.exists(img_fvlzas))
            return img_fvlzas;
        else
            File.saveContent(FVLZXHashCode.file(img), encoded);

        if (FileSystem.exists(img_fvlzas)) return img_fvlzas;

        var args = buildASTCArgs(img);
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
                return runASTC(img);
            }
            if (VERSION == "sse4.1") {
                trace("SSE4.1 not supported, falling back to sse2");
                VERSION = "sse2";
                return runASTC(img);
            }
            if (VERSION == "sse2") {
                trace("CPU does not support required SIMD instructions for ASTC encoding.");
                SUPPORT = false;
                return null;
            }
        } else {
            var img_ktxRaw = img.replace('.png', '.ktx');
            if (FileSystem.exists(img_ktxRaw)) {
                MemoryTracker.start("FVLZXEncoder.run (Compress ASTC)");
                try {
                    var fin = File.read(img_ktxRaw);
                    var bin = new haxe.io.BufferInput(fin, staticReadBuffer);
                    
                    bin.readFullBytes(staticHeader, 0, 64);
                    
                    var kvdSize = readInt32(staticHeader, 60);
                    var payloadOffset = 64 + kvdSize;
                    
                    bin.readFullBytes(staticSizeBytes, 0, 4);
                    var originalImageSize = readInt32(staticSizeBytes, 0);
                    
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
                    FileSystem.rename(img_ktxRaw + ".tmp", img_fvlzas);
                    return img_fvlzas;
                } catch (e:Dynamic) {
                    MemoryTracker.end();
                    throw e;
                }
                MemoryTracker.end();
            } else {
                trace("Warning: astcenc succeeded, but KTX file not found at: " + img_ktxRaw);
                return null;
            }
        }
        return null;
    }

    /**
     * Runs the custom multithreaded scalar BC7 encoder synchronously.
     * Outputs a BC7 compressed file with a .fvlzbs extension.
     * Returns the path to the .fvlzbs file on success, or null on failure.
     */
    public static function runBC7(img:String):Null<String> {
        var img_fvlzbs = img.replace('.png', '.fvlzbs');
        
        if (FileSystem.exists(img_fvlzbs)) return img_fvlzbs;

        var processName = BC7_ENVPATH;
        #if linux
        Sys.command("chmod", ["+x", processName]);
        #end
        #if windows
        processName += ".exe";
        #end

        var img_str = Sys.getCwd() + img;
        var img_fvlzbs_str = Sys.getCwd() + img_fvlzbs;
        var args = [img_str, img_fvlzbs_str, '-pmalpha'];

        try {
            var proc = new Process(processName, args);
            var exitCode = proc.exitCode(true);
            proc.close();

            if (exitCode != 0) {
                trace("BC7 encoding failed for " + img + " (exit code: " + exitCode + ")");
                return null; 
            }
            
            return img_fvlzbs;
        } catch (e:Dynamic) {
            trace("BC7 encoding exception for " + img + ": " + e);
            return null; 
        }
    }

    static function buildASTCArgs(img:String):Array<String> {
        var img_str = Sys.getCwd() + img;
        var img_ktx = img_str.replace('.png', '.ktx');
        return ['-cl', img_str, img_ktx, '4x4', '-fast', '-pp-premultiply', '-thread_count', '1'];
    }

    /**
     * Loads compressed texture data, automatically detecting whether it is 
     * a KTX (ASTC) or DDS (BC7/BPTC_44) file based on magic bytes.
     * 
     * FOOLPROOFING: If the original .png path is accidentally passed, 
     * it will automatically redirect to the .fvlzbs or .fvlzas equivalent.
     */
    public static function loadTextureData(texPath:String):TextureData {
        // Automatically resolve .png paths to their compressed counterparts
        var compPath = texPath;
        if (compPath.endsWith(".png")) {
            var fvlzbsPath = compPath.replace(".png", ".fvlzbs");
            if (FileSystem.exists(fvlzbsPath)) {
                compPath = fvlzbsPath;
            } else {
                var fvlzasPath = compPath.replace(".png", ".fvlzas");
                if (FileSystem.exists(fvlzasPath)) {
                    compPath = fvlzasPath;
                }
            }
        }

        if (!FileSystem.exists(compPath)) return null;

        var fin = File.read(compPath);
        var bin = new haxe.io.BufferInput(fin, staticReadBuffer);

        try {
            var header = Bytes.alloc(148); // Max needed for DDS (148), KTX only needs 64
            bin.readFullBytes(header, 0, 4);
            
            var isDDS = header.get(0) == 0x44 && header.get(1) == 0x44 && header.get(2) == 0x53 && header.get(3) == 0x20; // "DDS "
            var isKTX = header.get(0) == 0xAB && header.get(1) == 0x4B && header.get(2) == 0x54 && header.get(3) == 0x58; // "KTX "
            
            if (!isDDS && !isKTX) {
                var hex = [for (i in 0...4) StringTools.hex(header.get(i), 2)].join(" ");
                throw 'Invalid compressed texture file magic bytes (expected KTX or DDS, got: $hex)';
            }

            if (isKTX) {
                // --- ASTC / KTX Path ---
                bin.readFullBytes(header, 4, 60); // Read remaining 60 bytes of 64-byte KTX header
                
                var imgWidth = readInt32(header, 36);
                var imgHeight = readInt32(header, 40);
                var kvdSize = readInt32(header, 60);
                
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

                MemoryTracker.start("FVLZXEncoder.loadTextureData (ASTC)");
                
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
                return result;
            } else {
                // --- BC7 / DDS Path ---
                bin.readFullBytes(header, 4, 144); // Read remaining 144 bytes (total 148 bytes for DDS + DX10 header)
                
                var imgWidth = readInt32(header, 16); // width is at offset 16 (4 byte magic + 12)
                var imgHeight = readInt32(header, 12); // height is at offset 12 (4 byte magic + 8)
                var bc7Size = readInt32(header, 20); // pitchOrLinearSize is at offset 20 (4 byte magic + 16)
                
                var expectedRawSize = bc7Size;
                
                MemoryTracker.start("FVLZXEncoder.loadTextureData (BC7)");
                
                var bc7Bytes = Bytes.alloc(expectedRawSize);
                bin.readFullBytes(bc7Bytes, 0, expectedRawSize);
                
                bin.close();
                fin.close();
                
                var result = new TextureData(imgWidth, imgHeight, TextureFormat.BPTC_44, 0, bc7Bytes);
                MemoryTracker.end();
                return result;
            }
        } catch(e:Dynamic) {
            bin.close();
            fin.close();
            try { MemoryTracker.end(); } catch(e:Dynamic) {}
            throw "Failed to parse compressed texture at " + compPath + ": " + e;
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