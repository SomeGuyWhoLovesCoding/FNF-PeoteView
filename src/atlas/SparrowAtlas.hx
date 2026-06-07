package atlas;

/**
 * Implementation of sparrow atlas in my own way, for the character system and note system.
 * @since Development
**/
@:publicFields
@:structInit
@:access(Xml)
class SparrowAtlas {
	var imagePath:String;
	var subTextures:Array<SubTexture>;
	var animMap:Map<String, Array<Int>>;

	static function parse(text:String):SparrowAtlas {
		var xml = Xml.parse(text);
		var root = xml.firstElement();
		var subTexs:Array<SubTexture> = [for (i in 0...root.children.length) null];
		var aMap:Map<String, Array<Int>> = [];
		var curName:String = "";

		aMap[curName] = [for (i in 0...2) 0];

		var index:Int = 0;
		var started:Bool = false;
		for (element in root.elementsNamed("SubTexture")) {
			var name = element.get("name");
			var x = Std.parseInt(element.get("x"));
			var y = Std.parseInt(element.get("y"));
			var width = Std.parseInt(element.get("width"));
			var height = Std.parseInt(element.get("height"));
			var frameX = Std.parseInt(element.get("frameX"));
			var frameY = Std.parseInt(element.get("frameY"));
			var frameWidth = element.exists("frameWidth") ? Std.parseInt(element.get("frameWidth")) : width;
			var frameHeight = element.exists("frameHeight") ? Std.parseInt(element.get("frameHeight")) : height;
			var flipX = element.exists("flipX") ? element.get("flipX") == "true" : null;
			var flipY = element.exists("flipY") ? element.get("flipY") == "true" : null;
			var rotated = element.exists("rotated") ? element.get("rotated") == "true" : null;

			var nameStripped = name.substring(0, name.length - 4);
			if (curName != nameStripped) {
				if (started) {
					aMap[curName][1] = index - 1;
				} else {
					started = true;
				}
				curName = nameStripped;
				aMap[curName] = [for (i in 0...2) index];
			}

			subTexs[index] = ({
				name: name,
				x: x,
				y: y,
				width: width,
				height: height,
				frameX: frameX,
				frameY: frameY,
				frameWidth: frameWidth,
				frameHeight: frameHeight,
				flipX: flipX,
				flipY: flipY,
				rotated: rotated
			}:SubTexture);

			index++;
		}

		aMap[curName][1] = index;

		return {
			imagePath: root.get("imagePath"),
			subTextures: subTexs,
			animMap: aMap
		}
	}
}

/**
 * @since Development
**/
@:publicFields
@:structInit
class SubTexture {
	var name:String;
	var x:Int;
	var y:Int;
	var width:Int;
	var height:Int;
	var frameX:Null<Int>;
	var frameY:Null<Int>;
	var frameWidth:Null<Int>;
	var frameHeight:Null<Int>;
	var flipX:Null<Bool>;
	var flipY:Null<Bool>;
	var rotated:Null<Bool>;
}