package structures.gameplay;

/**
    Noteskin handle class.
    Barely documented because idk if this will ever make it as necessity into funkin' view or not so apparently I just have this class for no reason
**/
@:publicFields
class NoteskinHandle {
    private static var _texture:TextureData;
    var data:NoteskinData;
    var folder:String = "assets/images/noteskin/default";

    function new(skin:String) {
        // hmmmmmmm
        folder = 'assets/images/noteskins/$skin';
        var path = Path.asset('$folder/data.json');
        var content = sys.File.getContent(path);
        var rawData = Json.parse(content);

        data = {
            name: rawData.name,
            sparrowImg,
            rawData.sparrowImg,
            configMania: {
                offsetX: 0,
                offsetY: 0,
                gap: 112,
                clip: []
            }
        };

        var rawConfigMania:Array<Dynamic> = rawData.configMania;
        var i = 0;
        while (i < rawConfigMania.length - 1) {
            var configManiaPiece = data.configMania[i];

            data.configMania.offsetX = configManiaPiece.offsetX;
            data.configMania.offsetY = configManiaPiece.offsetY;
            data.configMania.gap = configManiaPiece.gap;

            var j = 0;
            while (j < rawConfigMania.clip.length - 1) {
                var clip = rawConfigMania.clip[i];
                // oh here we go with this
                data.configMania.clip.push({
                    idle: {
                        clipX: clip.idle.clipX,
                        clipY: clip.idle.clipY,
                        clipW: clip.idle.clipW,
                        clipH: clip.idle.clipH
                    },
                    press: {
                        clipX: clip.press.clipX,
                        clipY: clip.press.clipY,
                        clipW: clip.press.clipW,
                        clipH: clip.press.clipH
                    },
                    color: {
                        clipX: clip.color.clipX,
                        clipY: clip.color.clipY,
                        clipW: clip.color.clipW,
                        clipH: clip.color.clipH
                    },
                    confirm: {
                        clipX: clip.confirm.clipX,
                        clipY: clip.confirm.clipY,
                        clipW: clip.confirm.clipW,
                        clipH: clip.confirm.clipH
                    },
                    holdBody: {
                        clipX: clip.holdBody.clipX,
                        clipY: clip.holdBody.clipY,
                        clipW: clip.holdBody.clipW,
                        clipH: clip.holdBody.clipH
                    },
                    holdTail: {
                        clipX: clip.holdTail.clipX,
                        clipY: clip.holdTail.clipY,
                        clipW: clip.holdTail.clipW,
                        clipH: clip.holdTail.clipH
                    }
                });
            }
            i++;
        }
    }
}

@:publicFields
@:structInit
class NoteskinData {
    var name:String;
    var sparrowImg:String; //?
    var configMania:Array<NoteskinConfig>;
}

@:publicFields
@:structInit
class NoteskinConfig {
    var offsetX:Int;
    var offsetY:Int;
    var gap:Int; // default is usually 112
    var clip:Array<NoteskinReceptorProperties>;
}

@:publicFields
@:structInit
class NoteskinReceptorProperties {
    var idle:BasicNoteskinClip;
    var press:BasicNoteskinClip;
    var color:BasicNoteskinClip;
    var confirm:BasicNoteskinClip;
    var holdBody:BasicNoteskinClip;
    var holdTail:BasicNoteskinClip;
}

@:publicFields
@:structInit
class BasicNoteskinClip {
    var clipX:Int;
    var clipY:Int;
    var clipW:Int;
    var clipH:Int;
}