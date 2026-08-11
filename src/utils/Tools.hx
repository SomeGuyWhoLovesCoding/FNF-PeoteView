package utils;

import sys.io.File;
import sys.FileSystem;
import data.chart.Header;
import sys.io.Process;

using StringTools;

/**
 * Some helper shit. idc 
 * @since Development
**/
@:publicFields
class Tools {
	// a steal from https://github.com/ShadowMario/FNF-PsychEngine/blob/5c67ced49e5a98535298a6daa3f8f4ec79ac8399/.github/workflows/main.yml#L46 cuz why not
	public static function checkForUpdates() {
		var url = "https://raw.githubusercontent.com/SomeGuyWhoLovesCoding/FNF-PeoteView/refs/heads/official/.gitVersion";
		var version = Main.BUILD;
		var versionsDontMatch = false;
		trace('checking for updates...');
		var http = new haxe.Http(url);
		http.onData = function(data:String) {
			var newVersion = Std.parseInt(data);
			trace('build version online: $newVersion, your build version: $version');
			if (newVersion != version) {
				trace('versions arent matching! please update');
				versionsDontMatch;
				http.onData = null;
				http.onError = null;
				http = null;
			}
		}
		http.onError = function(error) {
			trace('error: $error');
		}
		http.request();
		return !versionsDontMatch; // we're in the clear
	}

	/**
		Returns true if the given song/chart directory is complete and playable:
		it needs a chart file (`chart.json` or `chart.fvc`), a `header.txt`,
		and every audio file referenced by the header must exist.
	**/
	public static function isChartComplete(path:String):Bool {
		if (path == null || path == "")
			return false;

		if (!FileSystem.exists('$path/chart.json') && !FileSystem.exists('$path/chart.fvc'))
			return false;
		if (!FileSystem.exists('$path/header.txt'))
			return false;

		try {
			var header = parseHeader(path);
			if (header.instDir == null || header.instDir == "" || !FileSystem.exists(Paths.asset(header.instDir)))
				return false;
			if (header.voicesDirs != null)
				for (voicesDir in header.voicesDirs)
					if (voicesDir != null && voicesDir != "" && !FileSystem.exists(Paths.asset(voicesDir)))
						return false;
		} catch (e) {
			return false;
		}

		return true;
	}

	static function parseHealthBarConfig(path:String) {
		var finalData:Array<Float> = [];

		var line = File.getContent(Paths.asset('$path/healthBarConfig.txt'));

		var split = line.split(", ");
		if (split.length != 6)
			throw "ARGUMENTS ARE NOT EQUAL TO SIX!";

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

		var line = File.getContent(Paths.asset('$path/timeBarConfig.txt'));

		var split = line.split(", ");
		if (split.length != 6)
			throw "ARGUMENTS ARE NOT EQUAL TO SIX!";

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

	private static var _fontsCached(default, null):FakeStringMap<Array<TextCharData>> = new FakeStringMap<Array<TextCharData>>();

	static function parseFont(name:String):Array<TextCharData> {
		// Sys.println('QUERY GAME FONT: $name');
		if (_fontsCached.exists(name))
			return _fontsCached.get(name);

		var path = Paths.asset('assets/fonts/$name');
		var fontPathSub = '$path/$name';
		var fontPath = '$fontPathSub.fnt';
		var fontPNGPath = '${fontPathSub}_0.png';

		var condition = FileSystem.exists(fontPath) && FileSystem.exists(fontPNGPath);

		if (!condition) {
			FileSystem.createDirectory(path);

			var fontbmPath = "assets/fonts/fontbm";
			var fontFile = 'assets/fonts/ttfs/$name.ttf';
			var outputPath = 'assets/fonts/$name/$name';

			var args = [
				    '--font-file', fontFile,
				    '--font-size',     '40',
				  '--data-format',   'json',
				   '--padding-up',      '8',
				'--padding-right',      '8',
				 '--padding-down',      '8',
				 '--padding-left',      '8',
				       '--output', outputPath
			];

			#if (linux || android)
			// Ensure executable permissions on Linux
			var tempPath = "/tmp/fontbm_" + name; // Unique temp name
			sys.io.File.copy(fontbmPath, tempPath);
			Sys.command("/bin/chmod", ["+x", tempPath]);
			var exitCode = Sys.command(tempPath, args);
			if (exitCode != 0) {
				Sys.println('WARNING: fontbm exited with code $exitCode');
			}
			sys.FileSystem.deleteFile(tempPath);
			#else
			var exitCode = Sys.command(fontbmPath, args);
			if (exitCode != 0) {
				Sys.println('WARNING: fontbm exited with code $exitCode');
			}
			#end
		}

		var contents = File.getContent(fontPath);
		var data = haxe.Json.parse(contents);

		var parsedData:Array<elements.text.TextCharData> = [for (i in 0...257) [0, 0, 0, 0, 0, 0, 0]];
		var padding:Array<Int> = data.info.padding;
		var chars = data.chars;
		for (i in 0...chars.length) {
			var element = chars[i];
			var number:Int = element.id;
			parsedData[number][0] = element.x;
			parsedData[number][1] = element.y;
			parsedData[number][2] = element.width;
			parsedData[number][3] = element.height;
			parsedData[number][4] = element.xoffset;
			parsedData[number][5] = element.yoffset;
			parsedData[number][6] = element.xadvance;
		}
		parsedData[256][0] = padding[3]; // left  (used for horizontal)
		parsedData[256][1] = padding[0]; // up    (used for vertical)
		parsedData[256][2] = padding[1]; // right
		parsedData[256][3] = padding[2]; // down
		parsedData[256][4] = data.common.lineHeight; // down

		TextureSystem.createTexture(name + "Font", fontPNGPath, false, true);

		_fontsCached.set(name, parsedData);
		return parsedData;
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

	static function formatTime(ms:Float, showMS:Bool = false):String {
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
			if (hours > 0)
				time += '$hours$t';
			if (minutes < 10 && hours > 0)
				time += '0$minutes$t';
			else
				time += '$minutes$t';
			if (seconds < 10)
				time += '0';
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
		ratio = Math.max(0, Math.min(1, ratio)); // clamp to [0, 1]
		return a + (b - a) * ratio;
	}

	static var iconGridMap:Map<String, Array<Int>> = [];

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

	static function fromIconGridXMLCharacter(path:String):Array<Int> {
		return iconGridMap.get(path);
	}

	inline static function fixElementAlphaFromFadingLerp(v:Float) {
		return Math.max((v * 1.002) - 0.002, 0);
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
			gameOver: {
				theme: gameOverTheme,
				bpm: gameOverBPM
			},
			actors: actors
		};

		// trace('Parsed header: $result');

		return result;
	}

	static function convertToSixColors(col:Array<Null<Int>>) {
		if (col == null)
			return [for (i in 0...6) 0];
		var arr:Array<Int> = [for (i in 0...6) 0];
		for (i in 0...col.length) {
			if (col[i] == null)
				col.remove(i);
		}
		switch (col.length) {
			case 1:
				for (i in 0...6)
					arr[i] = col[0];
			case 2:
				for (i in 0...6)
					arr[i] = col[Std.int(i / 3)];
			case 3:
				for (i in 0...6)
					arr[i] = col[Std.int(i / 4)];
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
		if (col == null)
			return [for (i in 0...6) 0];
		var arr:Array<Int> = [];
		for (i in 0...col.length) {
			var str = col[i];
			var argbColor:Color = Std.parseInt('0x${str}ff');
			arr.push((argbColor : Int));
		}
		return arr;
	}

	static function forSync(func:Void->Void) {
		haxe.Timer.delay(func, 1);
	}
}
