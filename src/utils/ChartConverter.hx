package utils;

import sys.io.File;
import haxe.Json;
import sys.FileSystem;
import sys.io.FileOutput;
import sys.io.FileInput;

#if !debug
@:noDebug
#end
@:publicFields
@:access(data.chart.MetaNote)
class ChartConverter
{
	private static var multichartMode(default, null):Bool = false;
	private static var alreadywroteheader(default, null):Bool = false;
	private static var chart(default, null):FileOutput;
	private static var header(default, null):FileOutput;
	private static var fileContents(default, null):String = "";
	private static var multichartPath(default, null):String = "";
	private static var multichartCBINPath(default, null):String = "";
	private static var metaNotes(default, null):Array<MetaNote> = [];

	/**
		Converts a base-game chart file to Funkin' View's chart format.
	**/
	static function baseGame(path:String) {
		MetaNote.CHART_EPOCH_DIFF_ENABLE(true);
		if (!multichartMode) {
			Sys.println("Welcome to the Funkin' View chart converter!");
			Sys.println("Converting base-game chart to CBIN...");
			Sys.println("Parsing json(s)...");
		}

		// Multichart directory
		if (FileSystem.isDirectory('$path/charts')) {
			multichartMode = true;
			multichartPath = path;
			multichartCBINPath = '$path/chart.cbin';

			Sys.println('Opening CBIN for multichart mode: $multichartCBINPath');
			chart = File.write(multichartCBINPath);

			var directoryList = FileSystem.readDirectory('$path/charts');
			Sys.println('Found ${directoryList.length} chart(s) in folder \'$path/charts\'');

			for (i in 0...directoryList.length) {
				var subPath = '$path/charts/${i+1}.json';
				if (!FileSystem.exists(subPath)) continue;

				Sys.println('Processing chart file ${i+1}/${directoryList.length}: $subPath');
				fileContents = File.getContent(subPath);
				processChart(fileContents, subPath);
			}

			// After all charts, sort and write notes
			Sys.println('All charts processed, sorting ${metaNotes.length} notes..');
			metaNotes.sort((a, b) -> a.position < b.position ? -1 : (a.position > b.position ? 1 : 0));

			for (i in 0...metaNotes.length) {
				var num = metaNotes[i].toNumber();
				chart.writeInt32(num.low);
				chart.writeInt32(num.high);

				if (i % 1000 == 0) { // progress log every 1000 notes
					Sys.println('  Wrote ${i+1}/${metaNotes.length} notes to CBIN');
				}
			}

			Sys.println("Finished writing chart.cbin for multichart mode.");
			chart.close();
			chart = null;
			metaNotes = [];
			multichartMode = false;
			alreadywroteheader = false;
			multichartPath = "";
			multichartCBINPath = "";

			MetaNote.RESET_CHART_EPOCH();
			MetaNote.CHART_EPOCH_DIFF_ENABLE(false);
			return;
		}

		var chartFileName = path;

		// Single chart fallback
		processChart(File.getContent('$chartFileName/chart.json'), chartFileName);

		if (!multichartMode) {
			Sys.println('Single chart: writing ${metaNotes.length} notes to CBIN...');
			chart = File.write('$path/chart.cbin');
			metaNotes.sort((a, b) -> a.position < b.position ? -1 : (a.position > b.position ? 1 : 0));
			for (i in 0...metaNotes.length) {
				var num = metaNotes[i].toNumber();
				chart.writeInt32(num.low);
				chart.writeInt32(num.high);

				if (i % 10000 == 0) {
					Sys.println('  Wrote ${i+1}/${metaNotes.length} notes to CBIN');
				}
			}
			chart.close();
			chart = null;
			metaNotes = [];
			alreadywroteheader = false;
		}

		MetaNote.RESET_CHART_EPOCH();
		MetaNote.CHART_EPOCH_DIFF_ENABLE(false);
	}

	/**
		Extracted logic to process a single chart JSON
	**/
	private static function processChart(content:String, path:String) {
		var json = Json.parse(content);
		var song = json.song;

		// Defaults
		var stage = song.stage != null ? song.stage : "stage";
		var gfVersion = song.gfVersion != null ? song.gfVersion : "gf";

		var headerPath = '${multichartMode ? multichartPath : path}/header.txt';
		alreadywroteheader = FileSystem.stat(headerPath).size != 0;

		// Write header if needed
		if (!alreadywroteheader) {
			//if (!FileSystem.exists(headerPath)) FileSystem.createFile
			header = File.append(headerPath);
			writeHeaderString(multichartMode ? multichartPath : path, song, stage, gfVersion, 4);
			header.close();
			header = null;
			alreadywroteheader = true;
		}

		// Mania handling
		var mania = switch(song.mania) {
			case 1: 6;
			case 2: 7;
			case 3: 9;
			default: 4;
		};

		// Process notes
		try {
			var notes:Array<Dynamic> = cast(song.notes, Array<Dynamic>);
			Sys.println('Processing ${notes.length} sections in chart \'$path\'');

			for (i in 0...notes.length) {
				var section:Dynamic = notes[i];
				var sectionNotes:Array<Dynamic> = cast(section.sectionNotes, Array<Dynamic>);
				var mustHitSection:Bool = section.mustHitSection;

				Sys.println('  Section ${i+1}/${notes.length}, mustHitSection: $mustHitSection, notes: ${sectionNotes.length}');

				for (j in 0...sectionNotes.length) {
					var note:VanillaChartNote = sectionNotes[j];
					var lane = mustHitSection ? 1 : 0;
					if (note.index % (mania * 2) > mania) lane = lane == 1 ? 0 : 1;
					var newNote = new MetaNote(
						MetaNote.floatToMetaNotePosition(note.position),
						MetaNote.floatDurationToInt(note.duration),
						note.index % mania,
						lane
					);
					metaNotes.push(newNote);

					if (j % 10000 == 0) {
						Sys.println('    Processed ${j+1}/${sectionNotes.length} notes in section ${i+1}');
					}
				}
			}

			Sys.println('Finished processing chart \'$path\', total notes so far: ${metaNotes.length}');
		} catch (e:Dynamic) {
			Sys.println('Error processing chart $path: $e');
		}
	}

	// Write header file
	private static function writeHeaderString(path:String, song:Dynamic, stage:String, gfVersion:String, mania:Int) {
		var instPath:String = '$path/Inst.flac';
		if (!FileSystem.exists(instPath)) throw 'No inst path! $instPath not found.';
		var voicesPath:String = '$path/Voices.flac';
		if (!FileSystem.exists(voicesPath)) voicesPath = '';

		header.writeString('Title: ${song.song}
Artist: N/A
Genre: N/A
Speed: ${song.speed * 0.45}
BPM: ${song.bpm}
Time Signature: 4/4
Stage: $stage
Instrumental: $instPath
Voices: $voicesPath
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

// VanillaChartNote abstract stays unchanged
#if !debug
@:noDebug
#end
@:publicFields
abstract VanillaChartNote(Array<Float>) from Array<Float> {
	var position(get, never):Float;
	var index(get, never):Int;
	var duration(get, never):Float;

	inline function get_position():Float { return this[0]; }
	inline function get_index():Int { return Math.floor(this[1]); }
	inline function get_duration():Float { return this[2]; }
}
