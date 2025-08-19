package utils;

import sys.io.File;
import haxe.Json;

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
	/**
		Converts a base-game chart file to Funkin' View's chart format.
		I don't recommend even using this as it's old and potentially unstable.
		@param path The specified path you want to convert your chart to.
	**/
	static function baseGame(path:String) {
		var header:FileOutput = File.write('$path/header.txt');
		var events:FileOutput = File.write('$path/events.txt');
		var chart: FileOutput = File.write('$path/chart.cbin');

		trace("Welcome to the Funkin' View chart converter!");
		trace("Converting base-game chart to CBIN...");
		trace("No events from the chart will be converted since the Funkin' View chart format has its own dedicated event format.");
		trace("Parsing json...");

		var fileContents = "";
		try {
			fileContents = File.getContent('$path/chart.json');
		} catch (e) {
			throw "There must be a chart.json.";
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

		trace("Sorting and adding notes...");

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

			for (section in notes) {
				section.sectionNotes.sort((a, b) -> a[0] - b[0]);
				var sectionNotes:Array<Dynamic> = section.sectionNotes;
				var mustHitSection:Bool = section.mustHitSection;
				for (i in 0...sectionNotes.length) {
					var note:VanillaChartNote = sectionNotes[i];

					var lane = 1 - Math.floor((mustHitSection ? note.index : ((note.index >= mania) ? note.index - mania : note.index + mania)) / mania);

					var newNote:MetaNote = new MetaNote(
						Tools.betterInt64FromFloat(note.position * 100),
						Math.floor(note.duration * 0.2), // Equal to `note.duration / 5`.
						note.index % mania,
						0,
						lane
					);

					var num = newNote.toNumber();
					chart.writeInt32(num.low);
					chart.writeInt32(num.high);
					//trace('Position: ${newNote.position}, Duration: ${newNote.duration}, Id: ${newNote.index}, Type: ${newNote.type}, Lane: ${newNote.lane}');
				}
			}

			header.writeString('Title: ${song.song}
Arist: N/A
Genre: N/A
Speed: ${song.speed * 0.45}
BPM: ${song.bpm}
Time Signature: 4/4
Stage: $stage
Instrumental: $path/Inst.ogg
Voices: $path/Voices.ogg
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
		} catch (e) {
			trace(haxe.CallStack.toString(haxe.CallStack.exceptionStack()), e);
			trace("This may be an invalid base game chart format or there\'s an error in the file.");
		}

		chart.close();

		header.close();
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