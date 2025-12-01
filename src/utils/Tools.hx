package utils;

import sys.io.File;
import sys.FileSystem;
import data.chart.Header;
using StringTools;

@:publicFields
class Tools {
	static var iconGridMap:Map<String, Array<Int>> = [];

	static function parseNoteskinData(path:String) {
		while (Note.offsetAndSizeFrames.length != 0) Note.offsetAndSizeFrames.pop();
		while (Note.offsetAndSizeFramesGM.length != 0) Note.offsetAndSizeFramesGM.pop();
		while (Sustain.offsets.length != 0) Sustain.offsets.pop();
		while (Sustain.tailPoints.length != 0) Sustain.tailPoints.pop();

		var contents = File.getContent('$path/noteData.xml');
		var xml = Xml.parse(contents);
		var root = xml.firstElement();

		for (element in root.elementsNamed("SubTexture")) {
			var name = element.get("name");
			var x = Std.parseInt(element.get("x"));
			var y = Std.parseInt(element.get("y"));
			var width = Std.parseInt(element.get("width"));
			var height = Std.parseInt(element.get("height"));
			var frameX = element.exists("frameX") ? Std.parseInt(element.get("frameX")) : 0;
			var frameY = element.exists("frameY") ? Std.parseInt(element.get("frameY")) : 0;

			Note.offsetAndSizeFrames.push(x);
			Note.offsetAndSizeFrames.push(y);
			Note.offsetAndSizeFrames.push(width);
			Note.offsetAndSizeFrames.push(height);
			Note.offsetAndSizeFrames.push(frameX);
			Note.offsetAndSizeFrames.push(frameY);
		}

		var floatKeys = Math.ffloor(Note.offsetAndSizeFrames.length / 4) / 6;
		if (floatKeys != Std.int(floatKeys)) throw "Noteskin not supported! KEYS is not integral!";
		Note.KEYS = Std.int(floatKeys);

		Note.enableGM = FileSystem.exists('$path/noteData_gm.xml');

		if (Note.enableGM) {
			var contents = File.getContent('$path/noteData_gm.xml');
			var xml = Xml.parse(contents);
			var root = xml.firstElement();

			for (element in root.elementsNamed("SubTexture")) {
				var name = element.get("name");
				var x = Std.parseInt(element.get("x"));
				var y = Std.parseInt(element.get("y"));
				var width = Std.parseInt(element.get("width"));
				var height = Std.parseInt(element.get("height"));
				var frameX = element.exists("frameX") ? Std.parseInt(element.get("frameX")) : 0;
				var frameY = element.exists("frameY") ? Std.parseInt(element.get("frameY")) : 0;

				Note.offsetAndSizeFramesGM.push(x);
				Note.offsetAndSizeFramesGM.push(y);
				Note.offsetAndSizeFramesGM.push(width);
				Note.offsetAndSizeFramesGM.push(height);
				Note.offsetAndSizeFramesGM.push(frameX);
				Note.offsetAndSizeFramesGM.push(frameY);
				//trace(x,y,width,height,frameX,frameY);
			}
		}

		var data = File.read('$path/sustainProperties.txt');

		TextureSystem.disposeTexture("sustainTex");
		TextureSystem.createTiledTexture("sustainTex", '$path/sustainSheet.png', 1, Std.parseInt(data.readLine()), false, true);

		var w = TextureSystem.getTexture("sustainTex").width;

		while (!data.eof()) {
			var line = data.readLine();
			var split = line.split(", ");
			if (split.length != 3) throw "ARGUMENTS ARE NOT EQUAL TO THREE!";

			var x = Std.parseInt(split[0]);
			var y = Std.parseInt(split[1]);
			var t = Std.parseInt(split[2]);

			Sustain.offsets.push([x, y]);
			Sustain.tailPoints.push(w - t);
		}
	}

	static function parseHealthBarConfig(path:String) {
		var finalData:Array<Float> = [];

		var line = File.getContent('$path/healthBarConfig.txt');

		var split = line.split(", ");
		if (split.length != 6) throw "ARGUMENTS ARE NOT EQUAL TO SIX!";

		var w = Std.parseFloat(split[0].split(" ")[1]);
		var h = Std.parseFloat(split[1].split(" ")[1]);
		var ws = Std.parseFloat(split[2].split(" ")[1]);
		var hs = Std.parseFloat(split[3].split(" ")[1]);
		var xa = Std.parseFloat(split[4].split(" ")[1]);
		var ya = Std.parseFloat(split[5].split(" ")[1]);

		finalData.push(w);
		finalData.push(h);
		finalData.push(ws);
		finalData.push(hs);
		finalData.push(xa);
		finalData.push(ya);

		return finalData;
	}

	static function parseTimeBarConfig(path:String) {
		var finalData:Array<Float> = [];

		var line = File.getContent('$path/timeBarConfig.txt');

		var split = line.split(", ");
		if (split.length != 6) throw "ARGUMENTS ARE NOT EQUAL TO SIX!";

		var w = Std.parseFloat(split[0].split(" ")[1]);
		var h = Std.parseFloat(split[1].split(" ")[1]);
		var ws = Std.parseFloat(split[2].split(" ")[1]);
		var hs = Std.parseFloat(split[3].split(" ")[1]);
		var xa = Std.parseFloat(split[4].split(" ")[1]);
		var ya = Std.parseFloat(split[5].split(" ")[1]);

		finalData.push(w);
		finalData.push(h);
		finalData.push(ws);
		finalData.push(hs);
		finalData.push(xa);
		finalData.push(ya);

		return finalData;
	}

	static function parseFont(name:String):Array<elements.text.TextCharData> {
		var path = 'assets/fonts/$name/data.json';
		var data = haxe.Json.parse(sys.io.File.getContent(path));
		TextureSystem.createTexture(name + "Font", path.replace('data.json', data.atlas.imagePath), false, true);
		return data.sprites;
	}

	/**
		An optimized version of `haxe.Int64.fromFloat`. Only works on certain targets such as cpp, js, or eval.
	**/
	inline static function betterInt64FromFloat(value:Float):Int64 {
		return haxe.Int64Helper.fromFloat(value);
	}

	/**
		Converts an Int64 to a float, since there's absolutely no `Int64.toFloat` function.
	**/
    inline static function int64ToFloat(value:Int64):Float {
        return (value.high * 4294967296.0) + value.low;
    }

	inline static function profileFrame() {
		#if FV_PROFILE
		cpp.vm.tracy.TracyProfiler.frameMark();
		#end
	}

	static function formatTime(ms:Float, showMS:Bool = false):String
	{
		var milliseconds:Int = Std.int(ms * 0.1) % 100;
		var seconds:Int = Std.int(ms * 0.001);
		var hours:Int = Std.int(seconds / 3600);
		seconds %= 3600;
		var minutes:Int = Std.int(seconds / 60);
		seconds %= 60;

		var t = ':';
		var c = '.';

		var time:String = '';

		if (!Math.isNaN(ms)) {
			if (hours > 0) time += '$hours$t';
			if (minutes < 10 && hours > 0) time += '0$minutes$t';
			else time += '$minutes$t';
			if (seconds < 10) time += '0';
			time += seconds;
		} else {
			time = 'null';
		}

		if (showMS) {
			if (milliseconds < 10) {
				time += '${c}0$milliseconds';
			} else {
				time += '${c}$milliseconds';
			}
		}

		return time;
	}

	inline static function lerp(a:Float, b:Float, ratio:Float):Float {
		return (1 - ratio) * a + ratio * b;
	}

	static function getIconGridMap(path:String) {
		var contents = File.getContent('$path/iconData.xml');
		var xml = Xml.parse(contents);
		var root = xml.firstElement();

		for (element in root.elementsNamed("SubTexture")) {
			var name:String = element.get("name");
			var x:Int = Std.parseInt(element.get("x"));
			var y:Int = Std.parseInt(element.get("y"));
			iconGridMap.set(name, [x, y]);
		}
	}

	inline static function fixElementAlphaFromFadingLerp(v:Float) {
		return Math.max((v * 1.002) - 0.002, 0);
	}

	static function fromIconGridXMLCharacter(path:String):Array<Int> {
		return iconGridMap.get(path);
	}

	static function parseHeader(path:String):Header {
		var input = File.read('$path/header.txt', false);

		var title:String = input.readLine().split(": ")[1].trim();
		var artist:String = input.readLine().split(": ")[1].trim();
		var genres:Array<Genre> = input.readLine().split(": ")[1].trim().split(", ");

		var speed:Float = Std.parseFloat(input.readLine().split(": ")[1].trim());
		var bpm:Float = Std.parseFloat(input.readLine().split(": ")[1].trim());
		var timeSigRaw = input.readLine().split(": ")[1].trim().split("/");
		var timeSig:Array<Int> = [Std.parseInt(timeSigRaw[0]), Std.parseInt(timeSigRaw[1])];

		var stage:String = input.readLine().split(": ")[1].trim();
		var instDir:String = input.readLine().split(": ")[1].trim();
		var voicesDirs:Array<String> = input.readLine().split(": ")[1].trim().split(", ");

		// Remove empty strings from voicesDirs
		var voicesDirsI = 0;
		while (voicesDirsI < voicesDirs.length) {
			var dir:String = voicesDirs[voicesDirsI];
			if (dir.trim() == "") {
				voicesDirs.remove(dir);
				continue;
			}
			++voicesDirsI;
		}

		var mania:Int = Std.parseInt(input.readLine().split(": ")[1].trim());
		var difficulty:Difficulty = Std.parseInt(input.readLine().split(": #")[1].trim()) - 1;

		input.readLine();

		var gameOverTheme:String = input.readLine().split(": ")[1].trim();
		var gameOverBPM:Float = Std.parseFloat(input.readLine().split(": ")[1].trim());

		input.readLine();

		var actors:Array<ActorMeta> = [];

		while (!input.eof()) {
			var actorInfo:Array<String> = input.readLine().split(", ");
			var actorPos:Array<String> = input.readLine().split("pos ")[1].split(" ");
			var actorCam:Array<String> = input.readLine().split("cam ")[1].split(" ");
			var meta:ActorMeta = {
				name: actorInfo[0].trim(),
				player: actorInfo[1].trim() == 'player',
				copy: actorInfo[2]?.trim() == 'true',
				position: [for (axis in actorPos) Std.parseInt(axis)],
				camOffset: [for (axis in actorCam) Std.parseInt(axis)]
			};
			actors.push(meta);
		}

		input.close();

		var result:Header = {
			dir: path,
			title: title,
			artist: artist,
			genres: genres,
			speed: speed,
			bpm: bpm,
			timeSig: timeSig,
			stage: stage,
			instDir: instDir,
			voicesDirs: voicesDirs,
			mania: mania,
			difficulty: difficulty,
			gameOver: {theme: gameOverTheme, bpm: gameOverBPM},
			actors: actors
		};

		trace('Parsed header: $result');

		return result;
	}

	static function convertToSixColors(col:Array<Int>) {
		if (col == null) return [for (i in 0...6) 0];
		var arr:Array<Int> = [for (i in 0...6) 0];
		switch (col.length) {
			case 1:
				for (i in 0...6) arr[i] = col[0];
			case 2:
				for (i in 0...6) arr[i] = col[Std.int(i/3)];
			case 3:
				for (i in 0...6) arr[i] = col[Std.int(i/4)];
			case 4:
				for (i in 0...6) {
					var iCustom = 0;
					switch (i) {
						case 0 | 1:
							iCustom = 0;
						case 2:
							iCustom = 2;
						case 3:
							iCustom = 3;
						case 4 | 5:
							iCustom = 4;
					}
					arr[i] = col[iCustom];
				}
			default:
				arr = col;
		}
		return arr;
	}

	static function hexesToOpaqueColor(col:Array<String>) {
		if (col == null) return [for (i in 0...6) 0];
		var arr:Array<Int> = [];
		for (i in 0...col.length) {
			var str = col[i];
			var argbColor:Color = Std.parseInt('0x${str}ff');
			arr.push((argbColor:Int));
		}
		return arr;
	}
}
