package atlas;

@:structInit
@:publicFields
class AnimRange {
    var start:Int;
    var end:Int;
}

@:structInit
@:publicFields
class AnimationData {
    var range:AnimRange;
    var frames:Array<SubTexture>;
}

/**
 * Implementation of sparrow atlas in my own way, for the character system and note system.
**/
@:publicFields
@:structInit
@:access(Xml)
class SparrowAtlas {
    var imagePath:String;
    var subTextures:Array<SubTexture>;
    var animations:Map<String, AnimationData>;

    static function parse(text:String):SparrowAtlas {
        var xml = Xml.parse(text);
        var root = xml.firstElement();
        var subTexs:Array<SubTexture> = [];
        var anims:Map<String, AnimationData> = [];
        var curName:String = "";
        var index:Int = 0;

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

            var subTex:SubTexture = {
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
            };

            if (!anims.exists(nameStripped)) {
                anims[nameStripped] = {
                    range: { start: index, end: index },
                    frames: []
                };
            } else {
                anims[nameStripped].range.end = index;
            }

            anims[nameStripped].frames.push(subTex);
            subTexs.push(subTex);
            index++;
        }

        return {
            imagePath: root.get("imagePath"),
            subTextures: subTexs,
            animations: anims
        };
    }
}

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