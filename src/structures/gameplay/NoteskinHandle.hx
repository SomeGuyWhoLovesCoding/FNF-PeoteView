package structures.gameplay;

import haxe.Json;
import sys.io.File;

/**
    Noteskin handle class.
    Barely documented because idk if this will ever make it as necessity into funkin' view or not so apparently I just have this class for no reason
**/
@:publicFields
class NoteskinHandle {
    public static var texture:TextureData;

    var data:NoteskinData;
    var folder:String = "assets/images/noteskin/default";

    function new(skin:String) {
        // hmmmmmmm
        folder = 'assets/images/noteskins/$skin';
        var path = Paths.asset('$folder/data.json');
        var content = File.getContent(path);
        var rawData = Json.parse(content);

        // Parse configMania properly
        var rawConfigMania:Array<Dynamic> = rawData.configMania;
        var configs:Array<NoteskinConfig> = [];
            
        // Parse clips
        var rawClips:Array<Dynamic> = rawData.clip;
        var clips:Array<NoteskinReceptorProperties> = [];
        
        // Only parse clips if they exist
        if (rawClips != null) {
            for (rawClip in rawClips) {
                clips.push({
                    idle: {
                        clipX: rawClip.idle.clipX,
                        clipY: rawClip.idle.clipY,
                        clipW: rawClip.idle.clipW,
                        clipH: rawClip.idle.clipH,
                        offsX: rawClip.idle.offsX,
                        offsY: rawClip.idle.offsY
                    },
                    press: {
                        clipX: rawClip.press.clipX,
                        clipY: rawClip.press.clipY,
                        clipW: rawClip.press.clipW,
                        clipH: rawClip.press.clipH,
                        offsX: rawClip.press.offsX,
                        offsY: rawClip.press.offsY
                    },
                    color: {
                        clipX: rawClip.color.clipX,
                        clipY: rawClip.color.clipY,
                        clipW: rawClip.color.clipW,
                        clipH: rawClip.color.clipH,
                        offsX: rawClip.color.offsX,
                        offsY: rawClip.color.offsY
                    },
                    confirm: {
                        clipX: rawClip.confirm.clipX,
                        clipY: rawClip.confirm.clipY,
                        clipW: rawClip.confirm.clipW,
                        clipH: rawClip.confirm.clipH,
                        offsX: rawClip.confirm.offsX,
                        offsY: rawClip.confirm.offsY
                    },
                    holdBody: {
                        clipX: rawClip.holdBody.clipX,
                        clipY: rawClip.holdBody.clipY,
                        clipW: rawClip.holdBody.clipW,
                        clipH: rawClip.holdBody.clipH,
                        offsX: rawClip.holdBody.offsX,
                        offsY: rawClip.holdBody.offsY
                    },
                    holdTail: {
                        clipX: rawClip.holdTail.clipX,
                        clipY: rawClip.holdTail.clipY,
                        clipW: rawClip.holdTail.clipW,
                        clipH: rawClip.holdTail.clipH,
                        offsX: rawClip.holdTail.offsX,
                        offsY: rawClip.holdTail.offsY
                    }
                });
            }
        }
        
        // Parse configs
        if (rawConfigMania != null) {
            for (rawConfig in rawConfigMania) {
                configs.push({
                    offsetX: rawConfig.offsetX,
                    offsetY: rawConfig.offsetY,
                    gap: rawConfig.gap,
                    scale: rawConfig.scale,
                    indexes: rawConfig.indexes != null ? rawConfig.indexes : []
                });
            }
        }

        data = {
            name: rawData.name != null ? rawData.name : "default",
            sparrowImg: rawData.sparrowImg != null ? rawData.sparrowImg : "notes.png",
            configMania: configs,
            clip: clips
        };
    }
}

@:publicFields
@:structInit
class NoteskinData {
    var name:String;
    var sparrowImg:String;
    var configMania:Array<NoteskinConfig>;
    var clip:Array<NoteskinReceptorProperties>; // this is reserved for index-to-clipping, not mania!
}

@:publicFields
@:structInit
class NoteskinConfig {
    var offsetX:Int;
    var offsetY:Int;
    var gap:Int;
    var scale:Float;
    var indexes:Array<Int>;
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
    var offsX:Int;
    var offsY:Int;
}