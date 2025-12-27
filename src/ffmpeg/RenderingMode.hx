package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import sys.thread.Thread;

@:publicFields
class RenderingMode {
    static final PBO_BUFFERS:Int = 32;
    static final QUEUE_SIZE:Int = 12;

    static var pbos:Array<GLBuffer> = [];
    static var pboIndex:Int = 0;
    static var pboTarget:Int = 0;
    static var frameSize:Int = 0;

    private static var ffmpegExists(default, null):Bool;
    static var process:Process;
    static var enabled:Bool = true;
    static var started:Bool = false;
    static var songName:String;
    static var renderTime(default, null):Float;
    static var frameRate:Float = 60;

    // ---------------- Frame Pool & Queue ----------------
    private static var freeList:Array<Bytes> = [];
    private static var frameQueue:Array<Bytes> = [];

    private static var writerThread:Thread;

    // ------------------ PBOs ------------------
    static function initPBOs() {
        frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;

        freeList = [];
        frameQueue = [];

        for (i in 0...QUEUE_SIZE) {
            var b = Bytes.alloc(frameSize);
            freeList.push(b);
        }

        pbos = [];
        pboTarget = 0x88EB; // GL_PIXEL_PACK_BUFFER
        for (i in 0...PBO_BUFFERS) {
            var buf = GL.createBuffer();
            GL.bindBuffer(pboTarget, buf);
            GL.bufferData(pboTarget, frameSize, cast null, GL.STREAM_COPY);
            pbos.push(buf);
        }
        GL.bindBuffer(pboTarget, null);
        Sys.println("Rendering Mode System - PBOs initialized successfully.");
    }

    // ---------------- Frame Pool ----------------
    static function getFreeFrame():Bytes {
        if (freeList.length > 0) return freeList.pop();
        return Bytes.alloc(frameSize); // fallback
    }

    static function returnFrame(frame:Bytes) {
        freeList.push(frame);
    }

    // ---------------- Queue ----------------
    static function enqueueFrame(frame:Bytes) {
        frameQueue.push(frame);
    }

    static function dequeueFrame():Bytes {
        if (frameQueue.length > 0) return frameQueue.shift();
        return null;
    }

    // ---------------- Writer Thread ----------------
    static function acquireWriter() {
		if (writerThread != null) return;
        writerThread = Thread.create(function() {
            while (started || frameQueue.length > 0) {
                var frame = dequeueFrame();
                if (frame == null) {
                    Sys.sleep(0);
                    continue;
                }
                try {
                    process.stdin.write(frame);
                } catch (e:Dynamic) {
                    Sys.println("Writer blocked, dropping frame: " + e);
                }
                returnFrame(frame);
            }
        });
    }

    // ---------------- Pipe Frame (MAIN THREAD ONLY) ----------------
    static function pipeFrame() {
        if (!enabled || !started || !ffmpegExists || process == null) return;

        var buffer = getFreeFrame();

        if (pbos.length == PBO_BUFFERS) {
            var readIndex = (pboIndex + PBO_BUFFERS - 1) % PBO_BUFFERS; // read PBO written 1 frame ago
            var writePBO = pbos[pboIndex];

            // write pixels into current PBO
            GL.bindBuffer(pboTarget, writePBO);
            GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, cast 0);
            GL.bindBuffer(pboTarget, null);

            // read old PBO into CPU memory
            var readPBO = pbos[readIndex];
            GL.bindBuffer(pboTarget, readPBO);
            #if (cpp || hl)
            try {
                GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
            } catch (e:Dynamic) {
                Sys.println("Warning: getBufferSubData failed, disabling PBOs");
                pbos = [];
                pboTarget = 0;
            }
            #end
            GL.bindBuffer(pboTarget, null);

            enqueueFrame(buffer);
            pboIndex = (pboIndex + 1) % PBO_BUFFERS;

        } else {
            // fallback without PBO
            GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, buffer);
            enqueueFrame(buffer);
        }

        haxe.Timer.delay(acquireWriter, 500);
    }

    // ------------------ Encoder ------------------
    static function getBestEncoder():Array<String> {
        var encoders = [
            {name:'h264_nvenc', args:['-c:v','h264_nvenc','-preset','p1','-tune','ull','-b:v','3M','-maxrate','4M','-bufsize','1M']},
            {name:'h264_amf', args:['-c:v','h264_amf','-quality','speed','-b:v','3M','-maxrate','4M','-rc','vbr_latency']},
            {name:'h264_qsv', args:['-c:v','h264_qsv','-preset','veryfast','-global_quality','28','-look_ahead','0','-async_depth','7','-b:v','3M']}
        ];

        for (encoder in encoders) {
            var testProcess = new Process('ffmpeg', [
                '-f','lavfi','-v','quiet','-i','color=black:s=64x64:d=0.1',
                '-c:v',encoder.name,'-f','null','-'
            ]);
            var stderr = testProcess.stderr.readAll().toString();
            var exitCode = testProcess.exitCode();
            if (stderr.indexOf('Conversion failed!') == -1 && exitCode == 0) {
                Sys.println('Rendering Mode System - Using encoder: ${encoder.name}');
                return encoder.args;
            }
        }

        Sys.println('Rendering Mode System - Using encoder: libx264 (software fallback)');
        return ['-c:v','libx264','-preset','ultrafast','-crf','27','-tune','zerolatency','-x264-params','ref=1:bframes=0:me=dia:subq=1:trellis=0'];
    }

    // ------------------ Init Render ------------------
    static function initRender() {
        var ffmpeg = "ffmpeg";
        #if windows ffmpeg += ".exe"; #end
        if (!FileSystem.exists(ffmpeg)) throw '$ffmpeg not found!';
        if (!FileSystem.exists('assets/videos/rendered/')) FileSystem.createDirectory('assets/videos/rendered');

        ffmpegExists = true;
        songName = Chart.header.title;

        Application.current.window.resizable = false;
        #if FV_LIME_FORK
        Application.current.window.uncappedFrameRate = true;
        #else
        Application.current.window.frameRate = 1000;
        #end

        var encoderSettings = getBestEncoder();
        var args = [
            '-y','-f','rawvideo','-pix_fmt','bgra',
            '-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
            '-r',Std.string(frameRate),'-i','-',
            '-vf','vflip','-fflags','nobuffer','-flags','low_delay',
            '-bufsize','8M','-threads','0','-thread_queue_size','8192'
        ].concat(encoderSettings).concat([
            '-colorspace','bt709',
            'assets/videos/rendered/' + songName + '.mp4'
        ]);

        process = new Process('ffmpeg', args);

        initPBOs();
        GL.pixelStorei(GL.PACK_ALIGNMENT, 16);

        started = true;
        renderTime = haxe.Timer.stamp();
        Sys.println("Rendering Mode System - Started!");
    }

    // ------------------ Stop Render ------------------
    static function stopRender() {
        if (!started) return;
        started = false;

        renderTime = haxe.Timer.stamp() - renderTime;
        Sys.println('Rendering Mode System - Finished Rendering in ${Tools.formatTime(renderTime*1000,true)}.');

        while(frameQueue.length > 0) Sys.sleep(0.003);
        writerThread = null;

        if (process != null) {
            try { if(process.stdin != null) process.stdin.close(); } catch(_) {}
            process.close();
            process.kill();
        }

        for (pbo in pbos) GL.deleteBuffer(pbo);
        pbos = [];
        freeList = [];
        frameQueue = [];
        GL.pixelStorei(GL.PACK_ALIGNMENT,4);

        #if FV_LIME_FORK
        Application.current.window.uncappedFrameRate = false;
        #else
        Application.current.window.frameRate = SaveData.graphics.frameRate;
        #end
        Application.current.window.resizable = true;
    }
}
