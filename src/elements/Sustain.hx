package elements;

/**
    The sustain note of the note sprite.

    Rewritten to accept two separate texture coordinates | `bodyCoord` (the
    "hold piece" region that tiles along the sustain length) and `tailCoord`
    (the "hold end" region drawn at the tip) | plus a texture rotation value
    (0 / 90 / 180 / 270) so any sustain texture can be rendered regardless
    of the angle it was exported at.

    ## Texture coordinates

    Each rect is passed as four float varyings (x, y, w, h in texture pixels)
    and assembled into a `vec4` in the shader.

    ## Rotation

    The rotation rotates the **texture sampling** (not the quad), so a
    horizontally-exported hold piece (wider than tall) can be tiled along a
    vertical sustain by passing `texRotation = 90`.

    ## Coordinate system

    - `vTexCoord.x` runs along the sustain **length** (0 = start, 1 = tail end).
    - `vTexCoord.y` runs across the sustain **thickness** (0 = one edge, 1 = other).
    - The body tiles via `fract()` along the length; the tail occupies the
      final portion at its native aspect ratio.

    ## Tail aspect ratio

    The tail uses its **own** scale (`drawThick / tailThick`), independent of
    the body's scale. This ensures the tail never distorts when the sustain's
    thickness differs from the body's or tail's native thickness. When the
    tail doesn't fit in the sustain length, it is **cropped** at native scale
    rather than stretched.

    @since Development
**/
class Sustain implements Element
{
    // ========================================================================
    // Position & Size
    // ========================================================================

    @posX @formula("uDisplayRotateX(aPos + vec2(0.0, py)) - uDisplayRotateX(vec2(0.0, py))") @set("properties") public var x:Int;
    @posY @formula("uDisplayRotateY(aPos + vec2(0.0, py)) - uDisplayRotateY(vec2(0.0, py))") @set("properties") public var y:Int;

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

    // Per-clip lookup tables, populated externally.
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
        this clip ID.
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
