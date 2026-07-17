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

    @posX @formula("uDisplayRotateX(aPos)") @set("properties") public var x:Int;
    @posY @formula("uDisplayRotateY(aPos)") @set("properties") public var y:Int;

    @varying @sizeX @formula("w * speed") @set("properties") public var w:Int;
    @varying @sizeY @formula("h * scale") @set("properties") public var h:Int;

    @rotation @formula("uDisplayRotation(r)") @set("properties") public var r:Float;
    @pivotY @const @formula("h * 0.5") public var py:Int;

    @color public var c:Color = 0xFFFFFFFF;

    @varying @custom @set("properties") public var speed:Float = 1.0;
    @varying @custom @set("properties") public var scale:Float = 1.0;

    /**
        Multi-texture slot selectors (same as Note). `texUnit` is this
        sustain's skin's index into `NoteskinManager.textureCache`;
        `texSlot` is always 0.

        Updated by `setHandle(handle)` so the sustain starts sampling
        from the new skin's sheet the moment the strumline switches
        handles — no shader re-injection needed.
    **/
    @texUnit public var texUnit:Int = 0;
    @texSlot public var texSlot:Int = 0;

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

    var handle:NoteskinHandle; // new

    static public function init(program:CustomProgram)
    {
    }

    // ========================================================================
    // Construction & ID
    // ========================================================================

    inline public function new(x:Int, y:Int, w:Int, h:Int, handle:NoteskinHandle, r:Float, s:Float, sc:Float, tile:Int) {
        this.handle = handle;
        setProperties(x, y, w, h, r, s, sc, 0, 36, 20, 36, 40, 36, 20, 36, 0);
        setHandle(handle);
    }

    /**
        Propagate `texUnit` / `texSlot` from a noteskin handle to this
        sustain. Called from the constructor and from
        `Strumline.set_noteskinHandle` whenever the active skin changes.

        After this call, the sustain's `@texUnit` / `@texSlot`
        attributes point at the new skin's slot in
        `NoteskinManager.textureCache`, so the shader will sample from
        that skin's sheet on the next draw.

        If `handle` is null, this is a no-op.
    **/
    inline public function setHandle(handle:NoteskinHandle) {
        if (handle == null) return;
        this.handle = handle;
        texUnit = handle.texUnit;
        texSlot = handle.texSlot;
    }

    /**
        Set the body/tail coords and rotation from the helper for this lane.
    **/
    inline public function changeID(id:Int) {
        var bodyClip = NoteskinRuntimeHelper.getHoldBodyClip(handle, id);
        var tailClip = NoteskinRuntimeHelper.getHoldTailClip(handle, id);

        bodyX = bodyClip.clipX;
        bodyY = bodyClip.clipY;
        bodyW = bodyClip.clipW;
        bodyH = bodyClip.clipH;

        tailX = tailClip.clipX;
        tailY = tailClip.clipY;
        tailW = tailClip.clipW;
        tailH = tailClip.clipH;

        texRotation = bodyClip.rotation.toDegrees();
    }
}
