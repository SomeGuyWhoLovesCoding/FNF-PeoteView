package structures.gameplay;

import haxe.Json;
import sys.io.File;
import sys.FileSystem;
import lime.graphics.Image;
import lime.math.Rectangle;

/**
    Noteskin handle class.
    Each mania config now carries per-clip-type indexes so that
    idle, press, color, confirm, holdBody and holdTail can each
    reference independent clip slots.

    Each instance owns its own `texture` (instance variable, not static),
    which is loaded via `loadTexture()` and freed via `dispose()`.
**/
@:publicFields
class NoteskinHandle {
    /** Instance-owned noteskin texture. Loaded by loadTexture(), freed by dispose(). */
    var texture:Texture = null;

    /** Current mania key count. Used by NoteskinRuntimeHelper to pick the right
        configMania entry. Set by Strumline when the handle is assigned.
        Defaults to 1 (single key). */
    var mania:Int = 1;

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

    /**
        Load the spritesheet texture for this noteskin.
        Premultiplies alpha for correct compositing.
        Uses the sparrowImg filename from data.json (defaults to "sheet.png").
        If the skin's sheet doesn't exist, falls back to the default skin.
    **/
    function loadTexture():Texture {
        if (texture != null) return texture;

        var sheetPath = Paths.asset('$folder/${data.sparrowImg}');
        var sheetExists = FileSystem.exists(sheetPath);

        if (!sheetExists) {
            sheetPath = Paths.asset('assets/images/noteskins/default/${data.sparrowImg}');
            sheetExists = FileSystem.exists(sheetPath);
        }

        if (!sheetExists) {
            trace('NoteskinHandle: sheet texture not found for ${data.name}, returning null');
            return null;
        }

        var noteTexV2 = TextureSystem.getTexture("noteTexV2");

        if (noteTexV2 == null)
            TextureSystem.createTexture("noteTexV2", sheetPath, false, true);

        texture = noteTexV2;
        return texture;
    }

    function setProgramsTexture(program:CustomProgram) {
        program.setTexture(texture, "noteTexV2");
    }

    function setProgramsNoteShader(program:CustomProgram) {
        program.injectIntoFragmentShader(
        '
            vec4 why(int textureID, float initialAlpha, float addedAlpha)
            {
                vec4 tex = getTextureColor(textureID, vTexCoord);
                if (tex.a == 0.0) return tex;
                float newA = clamp(tex.a * initialAlpha + addedAlpha, 0.0, 1.0);
                return vec4(tex.rgb * (newA / tex.a), newA);
            }
        ');
        program.setColorFormula( 'c * why(noteTexV2_ID, initialAlpha, addedAlpha)' );
    }

    function setProgramsSustainShader(program:CustomProgram) {
        var tileW = Util.toFloatString(texture.width);
        var tileH = Util.toFloatString(texture.height);
        var invTileW = Util.toFloatString(1.0 / texture.width);
        var invTileH = Util.toFloatString(1.0 / texture.height);

        program.injectIntoFragmentShader('
            // --- Rotation helper ---
            // Rotates a [0,1] UV by 0 / 90 / 180 / 270 degrees.
            // Uses range checks instead of == because texRotation is a
            // @varying float | interpolation between vertices can introduce
            // tiny precision drift (e.g. 89.9998) that breaks exact compares.
            vec2 sustainRotateUV(vec2 uv, float rot) {
                rot = mod(rot + 360.0, 360.0);
                if (rot > 45.0 && rot < 135.0)       return vec2(uv.y, 1.0 - uv.x);
                if (rot >= 135.0 && rot < 225.0)     return vec2(1.0 - uv.x, 1.0 - uv.y);
                if (rot >= 225.0 && rot < 315.0)     return vec2(1.0 - uv.y, uv.x);
                return uv;
            }

            bool sustainIsSwapped(float rot) {
                rot = mod(rot + 360.0, 360.0);
                return (rot > 45.0 && rot < 135.0) || (rot >= 225.0 && rot < 315.0);
            }

            vec4 slice(int textureID, vec4 bodyCoord, vec4 tailCoord, float texRotation) {
                vec2 coord = vTexCoord;

                // After rotation, the length-axis and thickness-axis may swap.
                // For 0 / 180 the rect\'s width (z) is along the sustain length
                // and height (w) is across the thickness. For 90 / 270 they swap.
                bool swapped = sustainIsSwapped(texRotation);

                float bodyLen   = swapped ? bodyCoord.w : bodyCoord.z;
                float bodyThick = swapped ? bodyCoord.z : bodyCoord.w;
                float tailLen   = swapped ? tailCoord.w : tailCoord.z;
                float tailThick = swapped ? tailCoord.z : tailCoord.w;

                float drawLen   = vSize.x;  // sustain length (drawn)
                float drawThick = vSize.y;  // sustain thickness (drawn)

                // Body scale | used ONLY for body tiling.
                float bodyPxScale = drawThick / max(bodyThick, 0.001);
                float bodyDrawLen = bodyLen * bodyPxScale;

                // Tail scale | uses the TAIL\'s own thickness, NOT the body\'s.
                // This preserves the tail\'s native aspect ratio regardless of
                // how the body\'s thickness compares. Without this, when the
                // sustain\'s thickness drops below the tail\'s native thickness,
                // the tail\'s length and thickness scales diverge and the tail
                // appears stretched along its length.
                float tailPxScale = drawThick / max(tailThick, 0.001);
                float tailDrawLen = tailLen * tailPxScale;

                vec2 localCoord;
                vec4 rect;

                if (tailDrawLen >= drawLen) {
                    // --- Tail doesn\'t fit (or exactly fits) ---
                    // Render ONLY the tail, CROPPED to the sustain length.
                    // The tail texture is sampled at its NATIVE scale | we
                    // show only the fraction that fits, not stretched.
                    // This prevents the tail from disappearing when the
                    // sustain is too short (which happened because UVs were
                    // being compressed beyond the texture bounds).
                    float visibleFrac = drawLen / max(tailDrawLen, 0.001);
                    visibleFrac = min(visibleFrac, 1.0);
                    // Show the TIP of the tail (the end cap), which is the
                    // visible portion at the sustain\'s end.
                    localCoord = vec2(1.0 - visibleFrac + coord.x * visibleFrac, coord.y);
                    rect = tailCoord;
                } else {
                    // --- Normal: body fills [0, tailStart], tail fills [tailStart, 1] ---
                    float tailStart = 1.0 - (tailDrawLen / max(drawLen, 0.001));

                    if (coord.x > tailStart) {
                        // Tail region | remap coord.x from [tailStart, 1] to [0, 1]
                        // so the tail texture spans its full length within this region.
                        localCoord = vec2(
                            (coord.x - tailStart) / max(1.0 - tailStart, 0.001),
                            coord.y
                        );
                        rect = tailCoord;
                    } else {
                        // Body region - tile along the length using fract().
                        // Map [0, tailStart] -> [N, 0] so tailStart always
                        // lands on a tile boundary (fract = 0), matching the
                        // old shader\'s (1.0 - coord.x / tail.x) approach.
                        float numTiles = tailStart * drawLen / max(bodyDrawLen, 0.001);
                        float tiledX = fract((1.0 - coord.x / max(tailStart, 0.001)) * numTiles);
                        localCoord = vec2(tiledX, coord.y);
                        rect = bodyCoord;
                    }
                }

                // Rotate the local coord within [0,1], then map to
                // full-texture UV space using the rect\'s pixel position+size.
                vec2 rotated = sustainRotateUV(localCoord, texRotation);
                vec2 uv = (rect.xy + rotated * rect.zw) * vec2($invTileW, $invTileH);

                // Clamp to [0,1] to prevent out-of-bounds sampling when
                // coords are near texture edges (which made the tail disappear).
                uv = clamp(uv, vec2(0.0), vec2(1.0));

                return getTextureColor(textureID, uv);
            }
        ');

        program.setColorFormula('c * slice(noteTexV2_ID, vec4(bodyX, bodyY, bodyW, bodyH), vec4(tailX, tailY, tailW, tailH), texRotation)');
    }

    /**
        Dispose this handle's texture, freeing GPU memory.
        After calling this, `texture` will be null.
        Safe to call multiple times (no-op if already disposed).
    **/
    function dispose() {
        if (texture != null) {
            texture.dispose();
            texture = null;
        }
    }

    /** Premultiply alpha on pixel data and create a Texture from the given Image. */
    static function premultiplyAndCreateTexture(image:Image):Texture {
        var smooth = SaveData.state.graphics.antialiasing;
        var pixelData = image.getPixels(new Rectangle(0, 0, image.width, image.height), RGBA32);

        var premultipliedData = haxe.io.Bytes.alloc(pixelData.length);
        for (i in 0...pixelData.length >> 2) {
            var fullARGB = pixelData.getInt32(i << 2);

            var a = (fullARGB >>> 24) & 0xFF;
            var r = (fullARGB >>> 16) & 0xFF;
            var g = (fullARGB >>> 8)  & 0xFF;
            var b = (fullARGB)        & 0xFF;

            r = (r * a) >> 8;
            g = (g * a) >> 8;
            b = (b * a) >> 8;

            var premul = (a << 24) | (r << 16) | (g << 8) | b;
            premultipliedData.setInt32(i << 2, premul);
        }

        var textureData = new TextureData(image.width, image.height, TextureFormat.RGBA);
        textureData.bytes = premultipliedData;

        var tex = new Texture(textureData.width, textureData.height, null, {
            format: TextureFormat.RGBA,
            powerOfTwo: false,
            smoothExpand: smooth,
            smoothShrink: smooth
        });
        tex.setData(textureData);

        return tex;
    }

    // --- Getters for clip data by index ---

    /** Get the NoteskinReceptorProperties for a given clip index. */
    inline function getClip(index:Int):NoteskinReceptorProperties {
        if (data.clip != null && index >= 0 && index < data.clip.length) {
            return data.clip[index];
        }
        return defaultClip();
    }

    /** Get a specific clip type for a given clip index. */
    inline function getClipState(index:Int, state:Int):BasicNoteskinClip {
        var clip = getClip(index);
        return switch (state) {
            case 0: clip.idle;
            case 1: clip.color;
            case 2: clip.press;
            case 3: clip.confirm;
            case 4: clip.holdBody;
            case 5: clip.holdTail;
            default: clip.idle;
        };
    }

    /** Get the clip index array for a given edit state from a config. */
    static inline function getIndexesForState(config:NoteskinConfig, state:Int):Array<Int> {
        return switch (state) {
            case 0: config.idleIndexes;
            case 1: config.colorIndexes;
            case 2: config.pressIndexes;
            case 3: config.confirmIndexes;
            case 4: config.holdBodyIndexes;
            case 5: config.holdTailIndexes;
            default: config.idleIndexes;
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

    /** Shared default receptor properties. */
    static function defaultClip():NoteskinReceptorProperties {
        return {
            idle:     {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            press:    {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            color:    {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            confirm:  {clipX: 0, clipY: 0, clipW: 100, clipH: 100, offsX: 0, offsY: 0},
            holdBody: {clipX: 0, clipY: 0, clipW: 35,  clipH: 31,  offsX: 0, offsY: 0},
            holdTail: {clipX: 0, clipY: 0, clipW: 35,  clipH: 45,  offsX: 0, offsY: 0}
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