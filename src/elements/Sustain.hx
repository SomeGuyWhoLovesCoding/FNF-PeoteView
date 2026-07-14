package elements;

import haxe.xml.Fast;

/**
    The sustain note of the note sprite.

    Rewritten to accept two separate texture coordinates — `bodyCoord` (the
    "hold piece" region that tiles along the sustain length) and `tailCoord`
    (the "hold end" region drawn at the tip) — plus a texture rotation value
    (0 / 90 / 180 / 270) so any sustain texture can be rendered regardless
    of the angle it was exported at.

    ## Texture coordinates

    Each rect is passed as four float varyings (x, y, w, h in texture pixels)
    and assembled into a `vec4` in the shader. The values are extracted from
    the TextureAtlas XML by matching the `"hold piece"` and `"hold end"`
    suffixes in the SubTexture names.

    ## Rotation

    The rotation rotates the **texture sampling** (not the quad), so a
    horizontally-exported hold piece (wider than tall) can be tiled along a
    vertical sustain by passing `texRotation = 90`.

    ## Coordinate system

    - `vTexCoord.x` runs along the sustain **length** (0 = start, 1 = tail end).
    - `vTexCoord.y` runs across the sustain **thickness** (0 = one edge, 1 = other).
    - The body tiles via `fract()` along the length; the tail occupies the
      final portion at its native aspect ratio.

    @since Development
**/
class Sustain implements Element
{
    // ========================================================================
    // Position & Size
    // ========================================================================

    @posX @formula("uDisplayRotateX(aPos + vec2(0.0, py))") @set("properties") public var x:Int;
    @posY @formula("uDisplayRotateY(aPos + vec2(0.0, py))") @set("properties") public var y:Int;

    @varying @sizeX @formula("w * speed") @set("properties") public var w:Int;
    @varying @sizeY @formula("h * scale") @set("properties") public var h:Int;

    @rotation @formula("uDisplayRotation(r)") @set("properties") public var r:Float;
    @pivotY @const @formula("h * 0.5") public var py:Int;

    @color public var c:Color = 0xFFFFFFFF;

    @varying @custom @set("properties") public var speed:Float = 1.0;
    @varying @custom @set("properties") public var scale:Float = 1.0;

    // ========================================================================
    // Texture Coordinates (body = "hold piece", tail = "hold end")
    // ========================================================================

    // Body texture rect in pixels: (x, y, w, h).
    @varying @custom @set("properties") public var bodyX:Float = 0.0;
    @varying @custom @set("properties") public var bodyY:Float = 0.0;
    @varying @custom @set("properties") public var bodyW:Float = 0.0;
    @varying @custom @set("properties") public var bodyH:Float = 0.0;

    // Tail texture rect in pixels: (x, y, w, h).
    @varying @custom @set("properties") public var tailX:Float = 0.0;
    @varying @custom @set("properties") public var tailY:Float = 0.0;
    @varying @custom @set("properties") public var tailW:Float = 0.0;
    @varying @custom @set("properties") public var tailH:Float = 0.0;

    // Texture rotation in degrees: 0, 90, 180, or 270.
    @varying @custom @set("properties") public var texRotation:Float = 0.0;

    // ========================================================================
    // State
    // ========================================================================

    static public var defaultAlpha:Float = 0.6;
    static public var defaultMissAlpha:Float = 0.3;

    public var length:Int;
    public var diff:Int = 0;
    public var scrollDirection:Int = 90;
    public var parent:Note;

    // Per-clip lookup tables, populated by `parseHoldCoordsFromXML`.
    // Each entry: [bodyX, bodyY, bodyW, bodyH, tailX, tailY, tailW, tailH].
    static public var holdCoords:Array<Array<Float>> = [];
    static public var rotations:Array<Int> = [];

    // ========================================================================
    // Shader Init
    // ========================================================================

    static public function init(program:CustomProgram, name:String, texture:Texture)
    {
        program.setTexture(texture, name);

        var tileW = Util.toFloatString(texture.width);
        var tileH = Util.toFloatString(texture.height);
        var invTileW = Util.toFloatString(1.0 / texture.width);
        var invTileH = Util.toFloatString(1.0 / texture.height);

        program.injectIntoFragmentShader('
            // --- Rotation helper ---
            // Rotates a [0,1] UV by 0 / 90 / 180 / 270 degrees.
            // The rotation is applied to the LOCAL coord within the body/tail
            // rect, before mapping to full-texture UV space.
            vec2 sustainRotateUV(vec2 uv, float rot) {
                if (rot == 90.0)  return vec2(uv.y, 1.0 - uv.x);
                if (rot == 180.0) return vec2(1.0 - uv.x, 1.0 - uv.y);
                if (rot == 270.0) return vec2(1.0 - uv.y, uv.x);
                return uv;
            }

            vec4 slice(int textureID, vec4 bodyCoord, vec4 tailCoord, float texRotation) {
                vec2 coord = vTexCoord;

                // Assemble the body and tail rects from individual varyings.
                // vec4 bodyCoord = vec4(bodyX, bodyY, bodyW, bodyH);
                // vec4 tailCoord = vec4(tailX, tailY, tailW, tailH);

                // After rotation, the body\'s length-axis and thickness-axis
                // may swap. For 0 / 180 the body\'s width (z) is along the
                // sustain length and height (w) is across the thickness.
                // For 90 / 270 they swap.
                bool swapped = (texRotation == 90.0 || texRotation == 270.0);

                float bodyLen   = swapped ? bodyCoord.w : bodyCoord.z;
                float bodyThick = swapped ? bodyCoord.z : bodyCoord.w;
                float tailLen   = swapped ? tailCoord.w : tailCoord.z;
                float tailThick = swapped ? tailCoord.z : tailCoord.w;

                float drawLen   = vSize.x;  // sustain length (drawn)
                float drawThick = vSize.y;  // sustain thickness (drawn)

                // Scale: drawn pixels per texture pixel, matched on thickness.
                float pxScale = drawThick / max(bodyThick, 0.001);

                // Tail\'s drawn length, preserving aspect ratio.
                float tailDrawLen = tailLen * pxScale;

                // Split point: where the tail begins (in [0,1] along length).
                float tailStart = 1.0 - (tailDrawLen / max(drawLen, 0.001));
                tailStart = clamp(tailStart, 0.0, 1.0);

                vec2 localCoord;
                vec4 rect;

                if (coord.x > tailStart) {
                    // --- Tail region ---
                    // Remap coord.x from [tailStart, 1] to [0, 1] so the tail
                    // texture spans its full height within this sub-region.
                    localCoord = vec2(
                        (coord.x - tailStart) / max(1.0 - tailStart, 0.001),
                        coord.y
                    );
                    rect = tailCoord;
                } else {
                    // --- Body region (tiled) ---
                    // Tile along the length using fract(). The tile period
                    // is the body\'s drawn length (bodyLen * pxScale).
                    float bodyDrawLen = bodyLen * pxScale;
                    float tiledX = fract(coord.x * drawLen / max(bodyDrawLen, 0.001));
                    localCoord = vec2(tiledX, coord.y);
                    rect = bodyCoord;
                }

                // Rotate the local coord within [0,1], then map to
                // full-texture UV space using the rect\'s pixel position+size.
                vec2 rotated = sustainRotateUV(localCoord, texRotation);
                vec2 uv = (rect.xy + rotated * rect.zw) * vec2($invTileW, $invTileH);

                return getTextureColor(textureID, uv);
            }
        ');

        program.setColorFormula('c * slice(${name}_ID, vec4(bodyX, bodyY, bodyW, bodyH), vec4(tailX, tailY, tailW, tailH), texRotation)');
    }

    // ========================================================================
    // Construction & ID
    // ========================================================================

    inline public function new(x:Int, y:Int, w:Int, h:Int, r:Float, s:Float, sc:Float, tile:Int) {
        setProperties(x, y, w, h, r, s, sc, 0, 36, 20, 36, 40, 36, 20, 36, 0);
    }

    /**
        Set the body/tail coords and rotation from the lookup tables for
        this clip ID. The tables are populated by `parseHoldCoordsFromXML`.
    **/
    inline public function changeID(id:Int) {
        var coords = holdCoords[id];
        if (coords != null && coords.length >= 8) {
            bodyX = coords[0]; bodyY = coords[1];
            bodyW = coords[2]; bodyH = coords[3];
            tailX = coords[4]; tailY = coords[5];
            tailW = coords[6]; tailH = coords[7];
        }
        texRotation = rotations[id];
    }
}
