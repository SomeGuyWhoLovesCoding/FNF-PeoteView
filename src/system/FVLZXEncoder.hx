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
    a secondary PC-primary BC7 texture compression is used by
    default and a png is compressed to it synchronously.
    
    Output extensions:
    - ASTC: .fvlzas (LZ4 compressed KTX payload)
    - BC7:  .fvlzbs (LZ4 compressed DDS payload)
    
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

    public static function run(img:String):Null<String> {
        #if !android
        // 1. STRICT PRIORITY: Try BC7 first on desktop
        var bc7Result = runBC7(img);
        if (bc7Result != null) return bc7Result;
        #end

        // 2. FALLBACK: ASTC (Android primary, PC fallback)
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
                return null;
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
                    
                    bin.close();
                    fin.close();
                    bout.close();
                    
                    var fpatch = File.update(img_ktxRaw + ".tmp");
                    fpatch.seek(payloadOffset, SeekBegin);
                    fpatch.writeByte(compressedLen & 0xFF);
                    fpatch.writeByte((compressedLen >> 8) & 0xFF);
                    fpatch.writeByte((compressedLen >> 16) & 0xFF);
                    fpatch.writeByte((compressedLen >> 24) & 0xFF);
                    fpatch.close();
                    
                    FileSystem.deleteFile(img_ktxRaw);
                    FileSystem.rename(img_ktxRaw + ".tmp", img_fvlzas);
                } catch (e:Dynamic) {
                    MemoryTracker.end();
                    throw e;
                }
                MemoryTracker.end();
                return img_fvlzas;
            } else {
                trace("Warning: astcenc succeeded, but KTX file not found at: " + img_ktxRaw);
                return null;
            }
        }
        return null;
    }

    /**
     * Runs the custom multithreaded scalar BC7 encoder synchronously.
     * Mirrors the ASTC workflow exactly using memory-efficient streaming.
     */
    public static function runBC7(img:String):Null<String> {
        var img_fvlzbs = img.replace('.png', '.fvlzbs');
        if (FileSystem.exists(img_fvlzbs)) return img_fvlzbs;

        var img_ddsRaw = img.replace('.png', '.dds');
        var processName = BC7_ENVPATH;
        #if linux
        Sys.command("chmod", ["+x", processName]);
        #end
        #if windows
        processName += ".exe";
        #end
        
        var img_str = Sys.getCwd() + img;
        var img_ddsRaw_str = Sys.getCwd() + img_ddsRaw;
        var args = [img_str, img_ddsRaw_str, '-pmalpha'];
        
        var proc = new Process(processName, args);
        var exitCode = proc.exitCode(true);
        proc.close();
        
        if (exitCode != 0) {
            trace("BC7 encoding failed for " + img + " (exit code: " + exitCode + ")");
            return null;
        }
        
        if (!FileSystem.exists(img_ddsRaw)) {
            trace("Warning: bc7_encoder succeeded, but DDS file not found at: " + img_ddsRaw);
            return null;
        }

        MemoryTracker.start("FVLZXEncoder.runBC7 (Compress)");
        try {
            var fin = File.read(img_ddsRaw);
            var bin = new haxe.io.BufferInput(fin, staticReadBuffer);
            
            var ddsHeader = Bytes.alloc(148);
            bin.readFullBytes(ddsHeader, 0, 148);
            
            if (ddsHeader.get(0) != 0x44 || ddsHeader.get(1) != 0x44 || ddsHeader.get(2) != 0x53 || ddsHeader.get(3) != 0x20) {
                throw "Invalid DDS file magic bytes";
            }
            
            // CORRECTED DDS OFFSETS:
            // File layout: [4: "DDS "][144: DDS_HEADER]
            // Within DDS_HEADER: [0:size][4:flags][8:height][12:width][16:pitchOrLinearSize]
            // Therefore, in the full file buffer:
            // height = 4 + 8 = 12
            // width  = 4 + 12 = 16
            // pitchOrLinearSize = 4 + 16 = 20
            var height = readInt32(ddsHeader, 12);
            var width = readInt32(ddsHeader, 16);
            var bc7Size = readInt32(ddsHeader, 20);
            
            var fout = File.write(img_ddsRaw + ".tmp", true);
            var bout = new BufferOutput(fout, staticWriteBuffer);
            
            bout.writeByte(0x46); bout.writeByte(0x56); bout.writeByte(0x42); bout.writeByte(0x53); // "FVBS"
            writeInt32(bout, width);
            writeInt32(bout, height);
            writeInt32(bout, bc7Size);
            bout.writeByte(0); bout.writeByte(0); bout.writeByte(0); bout.writeByte(0);
            
            var compressedLen = LZ4.compressStream(bin, bc7Size, bout);
            
            bin.close();
            fin.close();
            bout.close();
            
            var fpatch = File.update(img_ddsRaw + ".tmp");
            fpatch.seek(16, SeekBegin);
            fpatch.writeByte(compressedLen & 0xFF);
            fpatch.writeByte((compressedLen >> 8) & 0xFF);
            fpatch.writeByte((compressedLen >> 16) & 0xFF);
            fpatch.writeByte((compressedLen >> 24) & 0xFF);
            fpatch.close();
            
            FileSystem.deleteFile(img_ddsRaw);
            FileSystem.rename(img_ddsRaw + ".tmp", img_fvlzbs);
        } catch (e:Dynamic) {
            MemoryTracker.end();
            if (FileSystem.exists(img_ddsRaw)) FileSystem.deleteFile(img_ddsRaw);
            if (FileSystem.exists(img_ddsRaw + ".tmp")) FileSystem.deleteFile(img_ddsRaw + ".tmp");
            throw e;
        }
        MemoryTracker.end();
        return img_fvlzbs;
    }

    static function buildArgs(img:String):Array<String> {
        var img_str = Sys.getCwd() + img;
        var img_ktx = img_str.replace('.png', '.ktx');
        return ['-cl', img_str, img_ktx, '4x4', '-fast', '-pp-premultiply', '-thread_count', '1'];
    }

    public static function loadTextureData(texPath:String):TextureData {
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
            var header = Bytes.alloc(148);
            bin.readFullBytes(header, 0, 4);
            
            var isDDS = header.get(0) == 0x44 && header.get(1) == 0x44 && header.get(2) == 0x53 && header.get(3) == 0x20;
            var isKTX = header.get(0) == 0xAB && header.get(1) == 0x4B && header.get(2) == 0x54 && header.get(3) == 0x58;
            var isFVBS = header.get(0) == 0x46 && header.get(1) == 0x56 && header.get(2) == 0x42 && header.get(3) == 0x53;
            
            if (!isDDS && !isKTX && !isFVBS) {
                var hex = [for (i in 0...4) StringTools.hex(header.get(i), 2)].join(" ");
                throw 'Invalid compressed texture file magic bytes (expected KTX, FVBS, or DDS, got: $hex)';
            }

            if (isKTX) {
                bin.readFullBytes(header, 4, 60);
                
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
            } else if (isFVBS) {
                // FVBS header after magic: width(4) + height(4) + uncompressedSize(4) + compressedLen(4) = 16 bytes
                var meta = Bytes.alloc(16);
                bin.readFullBytes(meta, 0, 16);
                
                var imgWidth = readInt32(meta, 0);
                var imgHeight = readInt32(meta, 4);
                var uncompressedSize = readInt32(meta, 8);
                
                MemoryTracker.start("FVLZXEncoder.loadTextureData (BC7)");
                
                var bc7Bytes = Bytes.alloc(uncompressedSize);
                var written = LZ4.decompressFromInput(bin, bc7Bytes, uncompressedSize);
                if (written != uncompressedSize) {
                    MemoryTracker.end();
                    throw "Decompressed size mismatch! Expected " + uncompressedSize + " but got " + written;
                }
                
                bin.close();
                fin.close();
                
                var result = new TextureData(imgWidth, imgHeight, TextureFormat.BPTC_44, 0, bc7Bytes);
                MemoryTracker.end();
                return result;
            } else {
                // Raw DDS fallback
                bin.readFullBytes(header, 4, 144);
                
                var imgHeight = readInt32(header, 12);
                var imgWidth = readInt32(header, 16);
                var bc7Size = readInt32(header, 20);
                
                MemoryTracker.start("FVLZXEncoder.loadTextureData (BC7 Raw)");
                
                var bc7Bytes = Bytes.alloc(bc7Size);
                bin.readFullBytes(bc7Bytes, 0, bc7Size);
                
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
        // This is correct for little-endian (DDS and FVBS are both little-endian)
        return b.get(pos) | (b.get(pos + 1) << 8) | (b.get(pos + 2) << 16) | (b.get(pos + 3) << 24);
    }

    private static inline function writeInt32(out:haxe.io.Output, value:Int):Void {
        out.writeByte(value & 0xFF);
        out.writeByte((value >> 8) & 0xFF);
        out.writeByte((value >> 16) & 0xFF);
        out.writeByte((value >> 24) & 0xFF);
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