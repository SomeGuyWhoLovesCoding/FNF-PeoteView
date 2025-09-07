package data.chart;

/**
	The song's game over meta.
	This is a structure containing info related to the game over screen.
**/
#if !debug
@:noDebug
#end
@:publicFields
@:structInit
class GameOverMeta {
	/**
		The music for the game over music fitting its style.
	**/
	var theme:String;

	/**
		How many beats per minute the game over song should have.
	**/
	var bpm:Float;

	/**
		Returns a string representation of the game over meta.
	**/
	function toString() {
		return '{ theme => $theme, bpm => $bpm }';
	}
}