package system;

import sys.io.File;
using StringTools;

#if !debug
@:noDebug
#end
@:publicFields
class ChartSystem
{
	inline static function parseHeader(path:String):Header {
		var input = File.read('$path/header.txt', false);

		var title = input.readLine().split(": ")[1].trim();
		var artist = input.readLine().split(": ")[1].trim();
		var genres:Array<Genre> = input.readLine().split(": ")[1].trim().split(", ");

		var speed = Std.parseFloat(input.readLine().split(": ")[1].trim());
		var bpm = Std.parseFloat(input.readLine().split(": ")[1].trim());
		var timeSigRaw = input.readLine().split(": ")[1].trim().split("/");
		var timeSig = [Std.parseInt(timeSigRaw[0]), Std.parseInt(timeSigRaw[1])];

		var stage = input.readLine().split(": ")[1].trim();
		var instDir = input.readLine().split(": ")[1].trim();
		var voicesDirs = input.readLine().split(": ")[1].trim().split(", ");

		var mania = Std.parseInt(input.readLine().split(": ")[1].trim());
		var difficulty:Difficulty = Std.parseInt(input.readLine().split(": #")[1].trim()) - 1;

		input.readLine();

		var gameOverTheme = input.readLine().split(": ")[1].trim();
		var gameOverBPM = Std.parseInt(input.readLine().split(": ")[1].trim());

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
			gameOver: {theme: gameOverTheme, bpm: gameOverBPM}
		};

		return result;
	}
}