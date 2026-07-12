package elements.actor;

/**
	* Contains animation data and all of what psych engine alreay offers for an easy port.
	* @since Development
**/
@:structInit
@:struct
@:publicFields
class ActorData {
	var flip:Bool;
	var colors:Array<Color>;
	var scale:Float;

	var healthIcon:String;

	var adjPos:Array<Float>;
	var camPos:Array<Float>;

	var data:FakeStringMap<ActorAnimationData>;

	var disableSingDur:Bool;
	var singDur:Float;

	/**
	 * Converts a psych engine character data json to an `ActorData`.
	 * @param path 
	 */
	static function parse(path:String) {
		var content = sys.io.File.getContent(path);
		var json = haxe.Json.parse(content);

		var _data:FakeStringMap<ActorAnimationData> = new FakeStringMap<ActorAnimationData>();

		var animations:Array<Dynamic> = json.animations;

		for (i in 0...animations.length) {
			var animData = animations[i];
			_data.set(animData.anim, {
				name: animData.name,
				anim: animData.anim,
				offsets: animData.offsets,
				indices: animData.indices,
				fps: animData.fps,
				loop: animData.loop,
				// startShakeFrame: 0,
				// endShakeFrame: 1
			});
		}

		var c:Array<Color> = json.healthbar_colors;
		var colors:Color = Color.RGB(c[0], c[1], c[2]);
		var result:ActorData = {
			flip: json.flip_x,
			colors: [for (i in 0...6) colors],
			scale: json.scale,
			healthIcon: json.healthicon,
			adjPos: json.position,
			camPos: json.camera_position,
			disableSingDur: json.disableSingDuration,
			singDur: json.singDuration ?? 4,
			data: _data
		}

		return result;
	}
}