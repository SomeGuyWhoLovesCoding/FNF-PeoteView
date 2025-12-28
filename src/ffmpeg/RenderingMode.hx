package ffmpeg;

import sys.io.Process;
import sys.FileSystem;
import lime.graphics.opengl.GL;
import lime.graphics.opengl.GLBuffer;
import lime.app.Application;
import haxe.io.Bytes;

#if cpp
import cpp.NativeProcess;
#end

@:publicFields
class RenderingMode {

	// ---------- CONFIG ----------
	static final PBO_BUFFERS:Int = 3;

	// ---------- STATE ----------
	static var pbos:Array<GLBuffer> = [];
	static var pboIndex:Int = 0;
	static var pboTarget:Int = GL.PIXEL_PACK_BUFFER;
	static var frameSize:Int = 0;

	static var process:Process;
	static var started:Bool = false;
	static var enabled:Bool = true;

	static var renderTime:Float;
	static var frameRate:Float = 60;

	#if cpp
	static var nativeProcessHandle:Dynamic = null;
	#end

	// ---------- INIT PBO ----------
	static function initPBOs() {
		frameSize = Main.VARIABLE_WIDTH * Main.VARIABLE_HEIGHT * 3;

		#if !cpp
		buffer = Bytes.alloc(frameSize);
		#end

		pbos = [];

		for (i in 0...PBO_BUFFERS) {
			var pbo = GL.createBuffer();
			GL.bindBuffer(pboTarget, pbo);
			GL.bufferData(
				pboTarget,
				frameSize,
				cast null,
				GL.STREAM_READ
			);
			pbos.push(pbo);
		}

		GL.bindBuffer(pboTarget, null);
	}

	// ---------- PIPE FRAME ----------
	static var buffer:Bytes;
	static function pipeFrame() {
		if (!started || !enabled || process == null) return;

		var writePBO = pbos[pboIndex];
		var readPBO  = pbos[(pboIndex + 1) % PBO_BUFFERS];

		// Issue GPU read
		GL.bindBuffer(pboTarget, writePBO);
		GL.readPixels(
			0, 0,
			Main.VARIABLE_WIDTH,
			Main.VARIABLE_HEIGHT,
			GL.RGB,
			GL.UNSIGNED_BYTE,
			cast null
		);

		// Read previous frame
		GL.bindBuffer(pboTarget, readPBO);

		#if cpp
		var ptr = GL.mapBufferRange(
			pboTarget,
			0,
			frameSize,
			0x0001 | 0x0020
		);

		if (ptr != cast null) {
			var ptrInt:cpp.RawPointer<cpp.UInt8> = untyped __cpp__("(unsigned char*)(uintptr_t){0}", ptr);
			var arr:Array<cpp.UInt8> = cpp.Pointer.fromRaw(ptrInt).toUnmanagedArray(frameSize);
			NativeProcess.process_stdin_write(
				nativeProcessHandle,
				arr,
				0,
				frameSize
			);
			GL.unmapBuffer(pboTarget);
		}
		#else
		GL.getBufferSubData(pboTarget, 0, frameSize, buffer);
		process.stdin.write(buffer);
		#end

		GL.bindBuffer(pboTarget, null);
		pboIndex = (pboIndex + 1) % PBO_BUFFERS;
	}

	// ---------- ENCODER ----------
	static function getBestEncoder():Array<String> {
		var encoders = [
			{name:'h264_nvenc', args:[
				'-c:v','h264_nvenc',
				'-preset','p1',
				'-tune','ull',
				'-rc','constqp',
				'-qp','32',
				'-2pass','0',
				'-spatial-aq','0',
				'-temporal-aq','0',
				'-b_ref_mode','disabled',
				'-multipass','disabled'
			]},
			
			{name:'h264_amf', args:[
				'-c:v','h264_amf',
				'-quality','speed',
				'-rc','cqp',
				'-qp_i','32',
				'-qp_p','32',
				'-preanalysis','false'
			]},
			
			{name:'h264_qsv', args:[
				'-c:v','h264_qsv',
				'-preset','veryfast',
				'-global_quality','32',
				'-async_depth','4'
			]}
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
		return [
			'-c:v','libx264',
			'-preset','ultrafast',
			'-crf','28',
			'-tune','zerolatency',
			'-x264-params','rc-lookahead=0:ref=1:bframes=0:me=dia:subq=0:trellis=0:weightp=0'
		];
	}

	// ---------- START ----------
	static function initRender() {
		var ffmpeg = "ffmpeg";
		#if windows ffmpeg += ".exe"; #end

		if (!FileSystem.exists(ffmpeg))
			throw "ffmpeg not found";

		if (!FileSystem.exists("assets/videos/rendered"))
			FileSystem.createDirectory("assets/videos/rendered");

		var args = [
			'-y',
			'-f','rawvideo',
			'-pix_fmt','rgb24',
			'-s', Main.VARIABLE_WIDTH + "x" + Main.VARIABLE_HEIGHT,
			'-r', Std.string(frameRate),
			'-i','-',
			'-vf','vflip',
			'-fflags','nobuffer',
			'-flags','low_delay',
			'-an'
		].concat(getBestEncoder()).concat([
			'-colorspace', 'bt709',
			'assets/videos/rendered/${Chart.header.title}.mp4'
		]);

		process = new Process("ffmpeg", args);

		#if cpp
		nativeProcessHandle = untyped process.stdin.p;
		#end

		initPBOs();

		Application.current.window.resizable = false;
		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = true;
		#else
		Application.current.window.frameRate = 1000;
		#end

		started = true;
		renderTime = haxe.Timer.stamp();
	}

	// ---------- STOP ----------
	static function stopRender() {
		if (!started) return;

		started = false;

		if (process != null) {
			try process.stdin.close() catch (_){}
			process.close();
			process = null;
		}

		for (pbo in pbos) {
			try GL.deleteBuffer(pbo) catch (_){}
		}

		pbos = [];

		Application.current.window.resizable = true;
		#if FV_LIME_FORK
		Application.current.window.uncappedFrameRate = false;
		#else
		Application.current.window.frameRate = SaveData.state.graphics.frameRate;
		#end

		var total = haxe.Timer.stamp() - renderTime;
		Sys.println("Render finished in " + total + "s");
	}

}
