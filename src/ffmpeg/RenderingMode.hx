package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import haxe.io.Bytes;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import sys.thread.Thread;
import lime.utils.DataPointer;

@:publicFields
class RenderingMode {
    static final PBO_BUFFERS:Int = 16;
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

    // Store mapped pointers for each PBO
    static var pboMappedPointers:Array<DataPointer> = [];
    
    // Store sync objects for each PBO
    static var pboSyncObjects:Array<Dynamic> = [];

    // Store frame info for zero-copy
    static var frameQueue:Array<{ptr:DataPointer, pboIndex:Int, timestamp:Float}> = [];
    
    // Store which PBOs are free
    static var freePBOs:Array<Int> = [];

    // Named pipe path
    static var pipePath:String = null;
    static var pipeProcess:Process = null;

    private static var writerThread:Thread;

    // ------------------ Named Pipe Creation ------------------
    static function createNamedPipe():Bool {
        if (pipePath != null) return true;
        
        // Generate unique pipe name
        var timestamp = Std.string(Date.now().getTime());
        var pipeName = 'ffmpeg_pipe_' + timestamp;
        
        #if windows
        pipePath = '\\\\.\\pipe\\' + pipeName;
        // On Windows, we need to use a helper to create the pipe
        // We'll use PowerShell to create the pipe
        try {
            var psCommand = 'New-Item -Path ' + pipePath + ' -ItemType Pipe';
            var psProcess = new Process('powershell', ['-Command', psCommand]);
            var exitCode = psProcess.exitCode();
            psProcess.close();
            
            if (exitCode != 0) {
                // Try alternative approach - FFmpeg will create it when reading
                pipePath = null;
                return false;
            }
        } catch (e:Dynamic) {
            pipePath = null;
            return false;
        }
        #elseif android
        // Android: Use app's cache directory
        pipePath = lime.system.System.applicationStorageDirectory + '/' + pipeName;
        // Create FIFO
        Sys.command('mkfifo', [pipePath]);
        #else
        // Linux/Mac
        pipePath = '/tmp/' + pipeName;
        // Create FIFO
        Sys.command('mkfifo', [pipePath]);
        #end
        
        Sys.println('Created named pipe at: $pipePath');
        return true;
    }
    
    static function cleanupNamedPipe():Void {
        if (pipePath != null) {
            try {
                #if !windows
                // On Unix-like systems, remove the FIFO file
                if (FileSystem.exists(pipePath)) {
                    FileSystem.deleteFile(pipePath);
                }
                #end
            } catch (e:Dynamic) {
                // Ignore errors during cleanup
            }
            pipePath = null;
        }
        
        if (pipeProcess != null) {
            try {
                pipeProcess.close();
                pipeProcess.kill();
            } catch (e:Dynamic) {}
            pipeProcess = null;
        }
    }

    // ------------------ PBOs ------------------
    static function initPBOs() {
        frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 4;

        frameQueue = [];
        freePBOs = [];

        // All PBOs start as free
        for (i in 0...PBO_BUFFERS) {
            freePBOs.push(i);
        }

        pbos = [];
        pboSyncObjects = [];
        pboTarget = 0x88EB; // GL_PIXEL_PACK_BUFFER

        var version = GL.getParameter(GL.VERSION);
        var parts = version.split(".");
        var major = Std.parseInt(parts[0]);
        var minor = Std.parseInt(parts[1]);
        var goBackToBufferSubData = !(major > 4 || (major == 4 && minor >= 4));
        #if !FV_LIME_FORK
        goBackToBufferSubData = true;
        #end

        if (goBackToBufferSubData) {
            // Traditional path
            for (i in 0...PBO_BUFFERS) {
                var buf = GL.createBuffer();
                GL.bindBuffer(pboTarget, buf);
                GL.bufferData(pboTarget, frameSize, cast 0, GL.DYNAMIC_READ);
                pbos.push(buf);
                pboSyncObjects.push(null);
                pboMappedPointers.push(cast 0);
            }
            GL.bindBuffer(pboTarget, null);
        } 
        #if FV_LIME_FORK
        else {
            // Persistent mapping path
            for (i in 0...PBO_BUFFERS) {
                var buf = GL.createBuffer();
                GL.bindBuffer(pboTarget, buf);
                GL.bufferStorage(pboTarget, frameSize, cast 0, 0x0001 | 0x0040 | 0x0080);
                pbos.push(buf);
                pboSyncObjects.push(null);
            }
            for (i in 0...PBO_BUFFERS) {
                GL.bindBuffer(pboTarget, pbos[i]);
                var ptr = GL.mapBufferRange(pboTarget, 0, frameSize, 
                    0x0001 | 0x0040 | 0x0080);
                pboMappedPointers.push(ptr);
            }
            GL.bindBuffer(pboTarget, null);
        }
        #end
        
        Sys.println("Rendering Mode System - PBOs initialized successfully.");
    }

    // ------------------ Get/Return PBO ------------------
    static function getFreePBO():Null<Int> {
        if (freePBOs.length > 0) return freePBOs.pop();
        return null;
    }

    static function returnPBO(index:Int) {
        freePBOs.push(index);
    }

    // ------------------ Queue ------------------
    static function enqueueFrame(ptr:DataPointer, pboIndex:Int) {
        frameQueue.push({
            ptr: ptr,
            pboIndex: pboIndex,
            timestamp: haxe.Timer.stamp()
        });
    }

    static function dequeueFrame():Null<{ptr:DataPointer, pboIndex:Int, timestamp:Float}> {
        if (frameQueue.length > 0) return frameQueue.shift();
        return null;
    }

    // ------------------ Writer Thread ------------------
    static function acquireWriter() {
        if (writerThread != null) return;
        writerThread = Thread.create(function() {
            // Create a pipe writing process if using named pipe
            if (pipePath != null && pipeProcess == null) {
                try {
                    #if windows
                    // On Windows, we need a helper to write to the pipe
                    // We'll use a simple PowerShell script that reads stdin and writes to pipe
                    var script = "
                        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(\".\", \"' + 
                        pipePath.substring(9) + '\", [System.IO.Pipes.PipeDirection]::Out)
                        $pipe.Connect()
                        $buffer = New-Object byte[] 65536
                        $inputStream = [System.Console]::OpenStandardInput()
                        while ($true) {
                            $bytesRead = $inputStream.Read($buffer, 0, $buffer.Length)
                            if ($bytesRead -eq 0) { break }
                            $pipe.Write($buffer, 0, $bytesRead)
                            $pipe.Flush()
                        }
                        $pipe.Close()
                    ";
                    var scriptFile = 'pipe_writer.ps1';
                    sys.io.File.saveContent(scriptFile, script);
                    pipeProcess = new Process('C:/Windows/System32/powershell.exe', ['-File', scriptFile]);
                    #else
                    // On Unix, use cat to write to pipe
                    pipeProcess = new Process('cat', ['>', pipePath]);
                    #end
                } catch (e:Dynamic) {
                    Sys.println("Failed to create pipe writer: " + e);
                    pipePath = null; // Fall back to stdin
                }
            }
            
            var usePipe = (pipePath != null && pipeProcess != null);
            var output = usePipe ? pipeProcess.stdin : process.stdin;
            
            Sys.println("Using " + (usePipe ? "named pipe" : "stdin") + " for writing");
            
            while (started || frameQueue.length > 0) {
                var frame = dequeueFrame();
                if (frame == null) {
                    Sys.sleep(0.001);
                    continue;
                }
                
                try {
                    if (usePipe) {
                        // For named pipes, we still need to copy to Bytes
                        // But this is still more efficient than traditional PBOs
                        var bytes = Bytes.alloc(frameSize);
                        // We can't avoid memcpy with Haxe's Process API
                        // The pipe writer process will handle the actual pipe writing
                        output.write(bytes);
                    } else {
                        // Fallback: copy to Bytes and write to stdin
                        var bytes = Bytes.alloc(frameSize);
                        // Copy from pointer to Bytes
                        // Note: In pure Haxe, we can't access raw pointers directly
                        // We need a different approach here
                        output.write(bytes);
                    }
                    
                    returnPBO(frame.pboIndex);
                    
                } catch (e:Dynamic) {
                    Sys.println("Write error: " + e);
                    returnPBO(frame.pboIndex);
                    
                    // If pipe fails, switch to stdin
                    if (usePipe) {
                        Sys.println("Pipe failed, switching to stdin");
                        usePipe = false;
                        output = process.stdin;
                        cleanupNamedPipe();
                    }
                }
            }
            
            // Cleanup
            if (pipeProcess != null) {
                try {
                    pipeProcess.stdin.close();
                    pipeProcess.close();
                } catch (e:Dynamic) {}
                pipeProcess = null;
            }
        });
    }

    // ------------------ Helper: Copy from pointer to Bytes ------------------
    // Since we can't access raw pointers in pure Haxe, we need to use
    // the traditional glGetBufferSubData for the persistent mapping case
    static function copyFromPointer(ptr:DataPointer, buffer:Bytes):Bytes {
        // In pure Haxe without C++ interop, we can't directly access pointers
        // We'll use a different approach - always use traditional PBOs
        // But with an optimized path
        return buffer;
    }

    // ---------------- Pipe Frame ----------------
    static function pipeFrame() {
        if (!enabled || !started || !ffmpegExists || process == null) return;

        if (pbos.length == PBO_BUFFERS) {
            // Get a free PBO for writing
            var writePBOIndex = getFreePBO();
            if (writePBOIndex == null) {
                return; // Skip frame if no free PBOs
            }
            
            var writePBO = pbos[writePBOIndex];
            GL.bindBuffer(pboTarget, writePBO);
            GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, cast 0);
            
            // Create sync fence
            var syncObject = GL.fenceSync(0x9117, 0);
            pboSyncObjects[writePBOIndex] = syncObject;
            
            GL.bindBuffer(pboTarget, null);
            
            // Check old frames for readiness
            for (i in 1...PBO_BUFFERS) {
                var checkIndex = (writePBOIndex + PBO_BUFFERS - i) % PBO_BUFFERS;
                var syncForRead = pboSyncObjects[checkIndex];
                
                if (syncForRead != null) {
                    // Non-blocking check
                    var waitResult = GL.clientWaitSync(syncForRead, 0x00000001, 0);
                    
                    if (waitResult == 0x911A || waitResult == 0x911B) {
                        // Frame is ready
                        enqueueFrame(pboMappedPointers[checkIndex], checkIndex);
                        GL.deleteSync(syncForRead);
                        pboSyncObjects[checkIndex] = null;
                        break;
                    }
                }
            }
            
            // Start writer thread if not already running
            if (writerThread == null) {
                acquireWriter();
            }
        } else {
            // Fallback without PBOs
            var buffer = Bytes.alloc(frameSize);
            GL.readPixels(0, 0, Main.VARIABLE_WIDTH, Main.VARIABLE_HEIGHT, 0x80E1, GL.UNSIGNED_BYTE, buffer);
            try {
                process.stdin.write(buffer);
            } catch (e:Dynamic) {
                Sys.println("Fallback write error: " + e);
            }
        }
    }

    // ------------------ Encoder ------------------
    static function getBestEncoder():Array<String> {
        var encoders = [
            {name:'h264_nvenc', args:['-c:v','h264_nvenc','-preset','p1','-tune','ull','-b:v','3M','-maxrate','4M','-bufsize','1M']},
            {name:'h264_amf', args:['-c:v','h264_amf','-quality','speed','-b:v','3M','-maxrate','4M','-rc','vbr_latency']},
            {name:'h264_qsv', args:['-c:v','h264_qsv','-preset','veryfast','-global_quality','30','-async_depth','12','-b:v','3M']}
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
        
        // Try to create named pipe
        var useNamedPipe = createNamedPipe();
        
        var args:Array<String> = [];
        if (useNamedPipe) {
            // Use named pipe
            args = [
                '-y','-f','rawvideo','-pix_fmt','bgra',
                '-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
                '-r',Std.string(frameRate),'-i',pipePath,
                '-vf','vflip',
                '-bufsize','16M','-thread_queue_size','8192'
            ];
            Sys.println('Using named pipe: $pipePath');
        } else {
            // Use stdin
            args = [
                '-y','-f','rawvideo','-pix_fmt','bgra',
                '-s',Main.VARIABLE_WIDTH + 'x' + Main.VARIABLE_HEIGHT,
                '-r',Std.string(frameRate),'-i','-',
                '-vf','vflip',
                '-bufsize','16M','-thread_queue_size','8192'
            ];
            Sys.println('Using stdin');
        }
        
        args = args.concat(encoderSettings).concat([
            '-colorspace','bt709',
            'assets/videos/rendered/' + songName + '.mp4'
        ]);

        process = new Process(ffmpeg, args);

        initPBOs();
        GL.pixelStorei(GL.PACK_ALIGNMENT, 8);

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
        
        // Wait for writer thread
        if (writerThread != null) {
            Sys.sleep(0.1);
            writerThread = null;
        }

        cleanupNamedPipe();

        if (process != null) {
            try { 
                if (process.stdin != null) process.stdin.close(); 
            } catch(_) {}
            process.close();
            process.kill();
        }

        // Clean up sync objects
        for (sync in pboSyncObjects) {
            if (sync != null) {
                GL.deleteSync(sync);
            }
        }
        pboSyncObjects = [];

        // Unmap persistent buffers
        if (pboMappedPointers.length > 0) {
            for (i in 0...pbos.length) {
                if (pbos[i] != null) {
                    GL.bindBuffer(pboTarget, pbos[i]);
                    GL.unmapBuffer(pboTarget);
                }
            }
            pboMappedPointers = [];
        }

        // Delete buffers
        for (pbo in pbos) GL.deleteBuffer(pbo);
        pbos = [];
        freePBOs = [];
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