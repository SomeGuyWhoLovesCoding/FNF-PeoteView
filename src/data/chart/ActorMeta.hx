package data.chart;

/**
	The song's actor meta.
	This is a structure containing info related to the characters of the song.
**/
#if !debug
@:noDebug
#end
@:publicFields
@:structInit
class ActorMeta {
	/**
		The name of the character.
	**/
	var name:String;

	/**
		Determines whether the character is the player or not.
	**/
	var player:Bool;

	/**
		Determines whether the character is a copy or not.
	**/
	var copy:Bool;

	/**
		The position of the character.
	**/
	var position:Array<Int>;

	/**
		The camera offset of the character.
		This is here just in case a song needs adjustments to a specific character's camera offset.
	**/
	var camOffset:Array<Int>;

	/**
		Returns a string representation of the character.
	**/
	function toString() {
		return '{ name => $name, player => $player, copy => $copy }';
	}
}