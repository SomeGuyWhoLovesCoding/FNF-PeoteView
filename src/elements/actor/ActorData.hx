package elements.actor;

@:structInit
@:publicFields
class ActorData {
	var flip:Bool;
	var colors:Vector<Color>;
	var scale:Float;

	var healthIcon:String;

	var adjPos:Vector<Float>;
	var camPos:Vector<Float>;

	var data:Map<String, ActorAnimationData>;

	/**
	 * Converts a psych engine character data json to an `ActorData`.
	 * @param path 
	 */
	static function parse(path:String) {
		var content = sys.io.File.getContent(path);
		var json = haxe.Json.parse(content);

		var _data:Map<String, ActorAnimationData> = [];

		var animations:Vector<Dynamic> = Vector.fromData(json.animations);

		for (i in 0...animations.length) {
			var animData = animations[i];
			_data.set(animData.anim, {
				name: animData.name,
				anim: animData.anim,
				offsets: animData.offsets,
				indices: animData.indices,
				fps: animData.fps,
				loop: animData.loop
			});
		}

		var c:Vector<Color> = Vector.fromData(json.healthbar_colors);
		var colors:Color = Color.RGB(c[0], c[1], c[2]);
		var result:ActorData = {
			flip: json.flip_x,
			colors: new Vector<Color>(6, colors),
			scale: json.scale,
			healthIcon: json.healthicon,
			adjPos: Vector.fromData(json.position),
			camPos: Vector.fromData(json.camera_position),
			data: _data
		}

		return result;
	}
}