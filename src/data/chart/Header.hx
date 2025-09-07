package data.chart;

/**
	The chart header.
	This is a structure containing metadata about the chart.
**/
#if !debug
@:noDebug
#end
@:publicFields
@:structInit
class Header {
	/**
		The song's directory (by the title).
		This property is optional because it is not always used.
	**/
	@:optional var dir:String;

	/**
		The song's title.
	**/
	var title:String;

	/**
		The song's artist.
	**/
	var artist:String;

	/**
		The song's genres throughout the song.
	**/
	var genres:Array<Genre>;

	/**
		The song's speed.
	**/
	var speed:Float;

	/**
		The song's beats per minute.
	**/
	var bpm:Float;

	/**
		The song's time signature.
	**/
	var timeSig:Array<Int>;

	/**
		The song's stage.
	**/
	var stage:String;

	/**
		The song's instrumental directory.
	**/
	var instDir:String;

	/**
		The song's voices directory array.
	**/
	var voicesDirs:Array<String>;

	/**
		The song's key count.
	**/
	var mania:Int;

	/**
		The song's difficulty level.
	**/
	var difficulty:Difficulty;

	/**
		The song's game over meta.
	**/
	var gameOver:GameOverMeta;

	/**
		The song's actor meta.
	**/
	var actors:Array<ActorMeta>;

	/**
		Returns a string representation of the chart header.
	**/
	function toString() {
		return '{ title => $title, artist => $artist, genres => $genres, speed => $speed, bpm => $bpm, timeSig => $timeSig, stage => $stage, instDir => $instDir, voicesDirs => $voicesDirs, mania => $mania, difficulty => $difficulty, gameOver => ${gameOver.toString()}, actors => ${[for (actor in actors) actor.toString()/* + ", "*/]} }';
	}
}