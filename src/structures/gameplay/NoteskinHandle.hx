package structures.gameplay;

import haxe.Json;
import sys.io.File;

/**
    Noteskin handle class.
    Each mania config now carries per-clip-type indexes so that
    idle, press, color, confirm, holdBody and holdTail can each
    reference independent clip slots.
**/
@:publicFields
class NoteskinHandle {
    public static var texture:TextureData;

    var data:NoteskinData;
    var folder:String = "assets/images/noteskin/default";

    function new(skin:String) {
        folder = 'assets/images/noteskins/$skin';
        var path = Paths.asset('$folder/data.json');
        var content = File.getContent(path);
        var rawData = Json.parse(content);

        // --- Parse clips ---
        var rawClips:Array<Dynamic> = rawData.clip;
        var clips:Array<NoteskinReceptorProperties> = [];

        if (rawClips != null) {
            for (rawClip in rawClips) {
                clips.push({
                    idle:     parseClip(rawClip.idle),
                    press:    parseClip(rawClip.press),
                    color:    parseClip(rawClip.color),
                    confirm:  parseClip(rawClip.confirm),
                    holdBody: parseClip(rawClip.holdBody),
                    holdTail: parseClip(rawClip.holdTail)
                });
            }
        }

        // --- Parse configs ---
        var rawConfigMania:Array<Dynamic> = rawData.configMania;
        var configs:Array<NoteskinConfig> = [];

        if (rawConfigMania != null) {
            for (rawConfig in rawConfigMania) {
                configs.push(parseConfig(rawConfig));
            }
        }

        data = {
            name: rawData.name != null ? rawData.name : "default",
            sparrowImg: rawData.sparrowImg != null ? rawData.sparrowImg : "notes.png",
            configMania: configs,
            clip: clips
        };
    }

    static function parseClip(raw:Dynamic):BasicNoteskinClip {
        return {
            clipX: raw.clipX,
            clipY: raw.clipY,
            clipW: raw.clipW,
            clipH: raw.clipH,
            offsX: raw.offsX,
            offsY: raw.offsY,
            rotation: TextureRotation.parse(raw.rotation)
        };
    }

    static function parseConfig(raw:Dynamic):NoteskinConfig {
        // Support both old format (single "indexes") and new format (per-type indexes).
        var oldIndexes:Array<Int> = raw.indexes;
        var hasOld = oldIndexes != null && oldIndexes.length > 0;

        return {
            offsetX: raw.offsetX != null ? raw.offsetX : 0,
            offsetY: raw.offsetY != null ? raw.offsetY : 0,
            gap: raw.gap != null ? raw.gap : 112,
            scale: raw.scale != null ? raw.scale : 1.0,
            idleIndexes:     raw.idleIndexes != null     ? raw.idleIndexes     : (hasOld ? oldIndexes.copy() : []),
            pressIndexes:    raw.pressIndexes != null    ? raw.pressIndexes    : (hasOld ? oldIndexes.copy() : []),
            colorIndexes:    raw.colorIndexes != null    ? raw.colorIndexes    : (hasOld ? oldIndexes.copy() : []),
            confirmIndexes:  raw.confirmIndexes != null  ? raw.confirmIndexes  : (hasOld ? oldIndexes.copy() : []),
            holdBodyIndexes: raw.holdBodyIndexes != null ? raw.holdBodyIndexes : (hasOld ? oldIndexes.copy() : []),
            holdTailIndexes: raw.holdTailIndexes != null ? raw.holdTailIndexes : (hasOld ? oldIndexes.copy() : [])
        };
    }
}

// ============================================================================

enum abstract TextureRotation(Float) from Float to Float {
    /** 0° — no rotation. */
    var POS0   = 0.0;
    /** 90° clockwise. */
    var POS90  = 90.0;
    /** 180°. */
    var POS180 = 180.0;
    /** 90° counter-clockwise (270°). */
    var NEG90  = -90.0;

    /** Cycle to the next rotation value. */
    public inline function next():TextureRotation {
        var v:Float = this;
        if (v == 0.0)   return POS90;
        if (v == 90.0)  return POS180;
        if (v == 180.0) return NEG90;
        return POS0;
    }

    /** Cycle to the previous rotation value. */
    public inline function prev():TextureRotation {
        var v:Float = this;
        if (v == 0.0)   return NEG90;
        if (v == 90.0)  return POS0;
        if (v == 180.0) return POS90;
        return POS180;
    }

    /** To degrees. */
    public inline function toDegrees():Int {
        return Std.int(this);
    }

    /**
        Parse from JSON value — accepts numeric degrees or legacy
        string formats ("POS0", "POS90", "POS180", "NEG90").
        Defaults to POS0.
    **/
    public static function parse(val:Dynamic):TextureRotation {
        if (val == null) return POS0;

        if (Std.isOfType(val, Float)) {
            var f:Float = val;
            if (f == 0.0)   return POS0;
            if (f == 90.0)  return POS90;
            if (f == 180.0) return POS180;
            if (f == -90.0) return NEG90;
            return POS0;
        }

        var s:String = Std.string(val);
        return switch (s.toLowerCase()) {
            case "pos0":   POS0;
            case "pos90":  POS90;
            case "pos180": POS180;
            case "neg90":  NEG90;
            default:       POS0;
        }
    }
}

// ============================================================================

@:publicFields
@:structInit
class NoteskinData {
    var name:String;
    var sparrowImg:String;
    var configMania:Array<NoteskinConfig>;
    var clip:Array<NoteskinReceptorProperties>; // flat clip pool — index-to-clipping
}

// ============================================================================

@:publicFields
@:structInit
class NoteskinConfig {
    var offsetX:Int;
    var offsetY:Int;
    var gap:Int;
    var scale:Float;

    /** Per-mania-key clip index for the IDLE state. */
    var idleIndexes:Array<Int>;
    /** Per-mania-key clip index for the PRESS state. */
    var pressIndexes:Array<Int>;
    /** Per-mania-key clip index for the COLOR overlay. */
    var colorIndexes:Array<Int>;
    /** Per-mania-key clip index for the CONFIRM state. */
    var confirmIndexes:Array<Int>;
    /** Per-mania-key clip index for the HOLD_BODY state. */
    var holdBodyIndexes:Array<Int>;
    /** Per-mania-key clip index for the HOLD_TAIL state. */
    var holdTailIndexes:Array<Int>;
}

// ============================================================================

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

// ============================================================================

@:publicFields
@:structInit
class BasicNoteskinClip {
    var clipX:Int;
    var clipY:Int;
    var clipW:Int;
    var clipH:Int;
    var offsX:Int;
    var offsY:Int;
    var rotation:TextureRotation = POS0;
}