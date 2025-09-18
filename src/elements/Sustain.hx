package elements;

/**
    The sustain note of the note sprite.
**/
class Sustain implements Element
{
    // ------------------------------------------------------------------------
    // Position (relative to upper-left corner of Display)
    // ------------------------------------------------------------------------
    @posX @formula("x") public var x:Int;
    @posY @formula("y + py") public var y:Int;

    @rotation public var r:Float;

    @pivotY @const @formula("h * 0.5") public var py:Int;

    // ------------------------------------------------------------------------
    // Size
    // ------------------------------------------------------------------------
    @varying @sizeX @formula("w * speed") public var w(default, set):Int;
    @varying @sizeY @formula("h * scale") public var h(default, set):Int;

    inline function set_w(value:Int) {
        updateSlicePosX(tailPoint, value, h);
        return value;
    }

    inline function set_h(value:Int) {
        updateSlicePosX(tailPoint, w, value);
        return value;
    }

    // ------------------------------------------------------------------------
    // Tail slicing
    // ------------------------------------------------------------------------
    @varying @custom public var tailPoint(default, set):Int = 43; // Slice position relative to the horizontal position of the texture, starting backwards

    inline function set_tailPoint(value:Int) {
        updateSlicePosX(value, w, h);
        return value;
    }

    @varying @custom public var slicePosX(default, set):Float;       // Left/right threshold
    @varying @custom public var invOneMinusSlice:Float;
    @varying @custom public var uAspectTail:Float;

    private inline function updateSlicePosX(tail:Int, width:Int, height:Int):Void {
        slicePosX = 1.0 - tail * invTileH * height / width;
        invOneMinusSlice = 1.0 / (1.0 - slicePosX);
        uAspectTail = aspectInvH - tail;
    }

    // ------------------------------------------------------------------------
    // Appearance
    // ------------------------------------------------------------------------
    @color public var c:Color = 0xFFFFFFFF;

    @varying @custom public var speed:Float = 1.0; // Sustain height multiplicator relative to song's scroll speed
    @varying @custom public var scale:Float = 1.0; 

    static public var defaultAlpha:Float = 0.6; // Default alpha for idle state
    static public var defaultMissAlpha:Float = 0.3; // Default alpha for missed state

    // ------------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------------
    public var length:Int;
    @texTile var tile:Int = 0;

    /**
        The parent of this note sprite.
    **/
    public var parent:Note;

    static public var offsets:Array<Array<Int>> = []; // offsets[sustainSpr.id] = [x, y]
    static public var tailPoints:Array<Int> = []; // tailPoints[sustainSpr.tile] = tailPoint

    static public var uniforms(default, null):Array<UniformFloat>; // Shared uniforms for shader

    // ------------------------------------------------------------------------
    // Initialization
    // ------------------------------------------------------------------------
    static public function init(program:Program, name:String, texture:Texture):Void {
        program.setTexture(texture, name);

        // Blend setup
        program.blendEnabled = true;
        program.blendSrc = program.blendSrcAlpha = BlendFactor.ONE;
        program.blendDst = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

        var tileW:Float = texture.width / texture.tilesX;
        var tileH:Float = texture.height / texture.tilesY;

        // Slice-related uniforms
        uniforms = [
            new UniformFloat("uInvTileW", 1.0 / tileW),
            new UniformFloat("uInvTileH", 1.0 / tileH),
            new UniformFloat("uAspectInvH", tileW / tileH),
            new UniformFloat("uCoordScale", invTileH / invTileW)
        ];

        // Inject slicing logic into fragment shader
        program.injectIntoFragmentShader('
            vec4 slice(int textureID, float tailPoint, float slicePosX, float invOneMinusSlice, float uAspectTail) {
                vec2 coord = vTexCoord;

                float tailW = tailPoint * uInvTileW;

                // Left side coordinate
                float leftFrac = fract(
                    (1.0 - coord.x / slicePosX) * uAspectTail * uCoordScale / (1.0 - tailPoint * uInvTileW)
                );
                float coordLeft = mix(1.0 - tailW, 0.0, leftFrac);

                // Right side coordinate
                float coordRight = mix(1.0 - tailW, 1.0,
                                       (coord.x - slicePosX) * invOneMinusSlice);

                // Branchless selection
                coord.x = mix(coordRight, coordLeft, step(coord.x, slicePosX));

                return getTextureColor(textureID, coord);
            }
        ', false, uniforms);

        program.setColorFormula('c * slice(${name}_ID, tailPoint, slicePosX, invOneMinusSlice, uAspectTail)');
    }

    // ------------------------------------------------------------------------
    // Constructors & methods
    // ------------------------------------------------------------------------
    public function new(x:Int, y:Int, w:Int, h:Int, id:Int = 0) {
        this.x = x;
        this.y = y;
        this.w = w;
        this.h = h;
    }

    public function changeID(id:Int):Void {
        tile = id;
        tailPoint = tailPoints[id];
    }

    public function followNote(note:Note):Void {
        var offset = offsets[note.id];
        x = note.x + (Math.floor(offset[0] * scale) >> 1);
        y = note.y + (Math.floor(offset[1] * scale) >> 1);
    }
}
