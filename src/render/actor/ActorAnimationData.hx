package render.actor;

/**
	* This class is nothing special. Just a structure containing internal animation frame properties.
	* @since Development
**/
@:structInit
@:publicFields
class ActorAnimationData {
	var offsets:Array<Int>;
	var loop:Bool;
	var fps:Int;
	var anim:String;
	var indices:Array<Int>;
	var name:String;

	function toString() {
		return '{ offsets => $offsets, loop => $loop, fps => $fps, anim => $anim, indices => $indices, name => $name }';
	}
}