package utils;

import sys.io.File;
import haxe.Json;
import sys.FileSystem;

import sys.io.FileOutput;
import sys.io.FileInput;

/**
	The chart converter class.
**/
#if !debug
@:noDebug
#end
@:publicFields
class ChartConverter
{
	private static var multichartMode(default, null):Bool = false;
	private static var alreadywroteheader(default, null):Bool = false;
	private static var canClose(default, null):Bool = true;
	private static var chart(default, null):FileOutput;
	private static var events(default, null):FileOutput;
	private static var header(default, null):FileOutput;
	private static var fileContents(default, null):String = "";
	private static var multichartPath(default, null):String = "";
	private static var multichartCBINPath(default, null):String = "";
	private static var metaNotes(default, null):Array<MetaNote> = [];

	/**
		Converts a base-game chart file to Funkin' View's chart format.
		I don't recommend even using this as it's old and potentially unstable.
		@param path The specified path you want to convert your chart to.
	**/
	static function baseGame(path:String) {
		if (!multichartMode) {
			Sys.println("Welcome to the Funkin' View chart converter!");
			Sys.println("Converting base-game chart to CBIN...");
			Sys.println("No events from the chart will be converted since the Funkin' View chart format has its own dedicated event format.");
			Sys.println("Parsing json(s)...");
		}

		// Loop recursively
		if (FileSystem.isDirectory('$path/charts')) {
			multichartMode = true;
			multichartPath = path;
			multichartCBINPath = '$path/chart.cbin';
			var directoryList = FileSystem.readDirectory('$path/charts');
			for (i in 0...directoryList.length) {
				var subPath = '$path/charts/${i+1}.json';
				Sys.println(subPath);
				if (!FileSystem.exists(subPath)) continue;
				fileContents = File.getContent(subPath);
				Sys.println('$subPath contents success!');
				canClose = i != directoryList.length - 1;
				baseGame(subPath);
				alreadywroteheader = true;
				Sys.println('$subPath Done! (${i+1}/${directoryList.length})');
			}
			multichartPath = "";
			canClose = true;
			return;
		}

		if (header == null && !alreadywroteheader) header = File.write('${multichartMode ? multichartPath : path}/header.txt');

		chart = File.write(multichartMode ? multichartCBINPath : '$path/chart.cbin');

		if (!multichartMode) {
			metaNotes.resize(0);
			try {
				fileContents = File.getContent('$path/chart.json');
			} catch (e) {
				throw "There must be a single chart.json.";
			}
		}

		var json = Json.parse(fileContents);
		var song = json.song;

		var stage = song.stage;

		if (stage == null) {
			stage = "stage";
		}

		var gfVersion = song.gfVersion;

		if (gfVersion == null) {
			gfVersion = "gf";
		}

		Sys.println("Adding base notes before sorting new ones...");

		try {
			var notes:Array<Dynamic> = song.notes;
			var mania = 4;

			switch (song.mania) {
				case 1:
					mania = 6;
				case 2:
					mania = 7;
				case 3:
					mania = 9;
				default:
					mania = 4;
			}

			if (!alreadywroteheader) writeHeaderString(multichartMode ? multichartPath : path, song, stage, gfVersion, mania);

			var count = 0;
			for (section in notes) {
				var sectionNotes:Array<Dynamic> = section.sectionNotes;
				var mustHitSection:Bool = section.mustHitSection;
				for (i in 0...sectionNotes.length) {
					var note:VanillaChartNote = sectionNotes[i];

					var lane = 1 - Math.floor((mustHitSection ? note.index : ((note.index >= mania) ? note.index - mania : note.index + mania)) / mania);

					var newNote:MetaNote = new MetaNote(
						MetaNote.floatToMetaNotePosition(note.position),
						Std.int(note.duration * 0.25), // Equal to `note.duration / 4`.
						note.index % mania,
						lane
					);

					/*var position = newNote.position;
					var duration = newNote.duration;
					var index = newNote.index;
					var type = newNote.type;
					Sys.println('Raw position: ${note.position}, Duration: ${note.duration}, Index: ${note.index}, MetaNote Position: $position, Duration: $duration, Index: $index, Type: $type');*/

					metaNotes.push(newNote);
				}
			}
		} catch (e) {
			trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()), e);
			Sys.println("This may be an invalid base game chart format or there\'s an error in the file.");
		}

		if (!canClose) {
			Sys.println("The real fun.");

			// Now for the REAL fun.
			metaNotes.sort((a, b) -> a.position < b.position ? -1 : (a.position > b.position ? 1 : 0));

			for (metaNote in metaNotes) {
				/*var position = metaNote.position;
				var duration = metaNote.duration;
				var index = metaNote.index;
				var type = metaNote.type;
				trace('MetaNote Position: $position, Duration: $duration, Index: $index, Type: $type');*/
				var num = metaNote.toNumber();
				chart.writeInt32(num.low);
				chart.writeInt32(num.high);
			}
		}

		if (!multichartMode) {
			header.close();
			header = null;
		}

		if (canClose) {
			chart.close();
			chart = null;
		}
	}

	// just a lil helper function to write a header file
	private static function writeHeaderString(path:String, song:Dynamic, stage:String, gfVersion:String, mania:Int) {
		var instPath:String = '$path/Inst.flac';
		if (!FileSystem.exists(instPath)) throw 'No inst path! $instPath not found.';
		var voicesPath:String = '$path/Voices.flac';
		if (!FileSystem.exists(voicesPath)) voicesPath = '';
		header.writeString('Title: ${song.song}
Arist: N/A
Genre: N/A
Speed: ${song.speed * 0.45}
BPM: ${song.bpm}
Time Signature: 4/4
Stage: $stage
Instrumental: $path/Inst.flac
Voices: $path/Voices.flac
Mania: $mania
Difficulty: #8
Game Over:
Theme: vanilla
BPM: 100
Characters:
${song.player2}, enemy
pos -700 300
cam 0 45
$gfVersion, other
pos -100 300
cam 0 45
${song.player1}, player
pos 200 300
cam 0 45');
	}
}

/**
	The base-game chart note.
	The only way you can construct it is that if you input a float array.
**/
#if !debug
@:noDebug
#end
@:publicFields
abstract VanillaChartNote(Array<Float>) from Array<Float> {
	/**
		The note's position.
		Assigns the visual representation of a note at a specific time in the song.
	**/
	var position(get, never):Float;

	/**
		The note's index.
		Where the note should spawn at.
	**/
	var index(get, never):Int;

	/**
		The note's hold duration.
		Assigns the note's visual representation of the hold note with the length.
	**/
	var duration(get, never):Float;

	/**
		Get the note's position.
		Assigns the visual representation of a note at a specific time in the song.
	**/
	inline function get_position():Float {
		return this[0];
	}

	/**
		Get the note's index.
		Where the note should spawn at.
	**/
	inline function get_index():Int {
		return Math.floor(this[1]) & 0xF;
	}

	/**
		Get the note's hold duration.
		Assigns the note's visual representation of the hold note with the length.
	**/
	inline function get_duration():Float {
		return this[2];
	}
}