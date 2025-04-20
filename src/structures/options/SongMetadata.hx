// This file was part of the freeplay menu songsAvailable shit but went unused due to it being too similar to data.chart.Header.
// This will be removed on the commit after this was made.

package structures.options;

@:structInit
@:publicFields
class SongMetadata {
	var name:String;
	var artist:String;
	var difficulty:Int;
	var length:Float;
	var difficulty:Difficulty;
	var preview:String;
	var previewLength:Int;

	// Constructor
	function new(name:String, artist:String, difficulty:Int, length:Float, difficulty:Difficulty, preview:String, previewLength:Int) {
		this.name = name;
		this.artist = artist;
		this.difficulty = difficulty;
		this.length = length;
		this.rating = rating;
		this.description = description;
		this.preview = preview;
		this.previewLength = previewLength;
	}

	static function fromData(data:String):SongMetadata {
		// Parse the data string and create a new SongMetadata object
		var header = ChartSystem.parseHeader('$path/header.txt');
		return new SongMetadata(header.title, header.artist, );
	}
}