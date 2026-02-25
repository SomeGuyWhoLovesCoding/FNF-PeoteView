package elements.actor;

import peote.view.Program;
import peote.view.Buffer;

/**
    ActorProgram extends peote-view's Program to inject a full 2×2 affine
    matrix transform for Animate atlas leaf sprites.

    When _useMatrix == 1.0, the vertex shader ignores peote-view's normal
    pos + aPosition*size*mat2(rotation) pipeline and instead computes:

        localPos  = aPosition * vec2(_vw, _vh)
        worldPos  = mat2(_ma, _mb, _mc, _md) * localPos + vec2(_tx, _ty)

    GLSL mat2 is column-major:  mat2(col0, col1)
        col0 = (_ma, _mb)   col1 = (_mc, _md)
    So the multiply is:
        worldPos.x = _ma * local.x + _mc * local.y + _tx
        worldPos.y = _mb * local.x + _md * local.y + _ty

    For atlas-rotated sprites (_rotated == 1.0), the texture coordinate is
    swapped so that the 90° CW-packed region samples correctly:
        texU = (1.0 - aPosition.y) * clipW + clipX
        texV = aPosition.x         * clipH + clipY

    Adobe Animate packs sprites +90 CW, so the unpack rule is:
        visual top-left  (0,0) → atlas top-right  → texU = clipX + clipW, texV = clipY
        visual top-right (1,0) → atlas bottom-right → texU = clipX + clipW, texV = clipY + clipH
    ... giving: texU = clipX + (1 - v) * clipW,  texV = clipY + u * clipH
    where u = aPosition.x (visual horizontal 0..1), v = aPosition.y (visual vertical 0..1).
**/
class ActorProgram extends Program<ActorElement> {

    public function new(buffer:Buffer<ActorElement>) {
        super(buffer);
    }

    /**
     * Returns the vertex shader source with the matrix-transform injection.
     * We keep peote-view's full CALC_POS result intact for Sparrow sprites
     * (_useMatrix == 0.0) and replace it for Animate leaves (_useMatrix == 1.0).
     *
     * The injection is done by appending to CALC_POS after peote-view builds it.
     * We achieve this by overriding vertexShader and post-processing the string
     * to insert our branch after the "vec2 pos = ..." line.
     *
     * Specifically we replace:
     *     ::CALC_POS::
     * with:
     *     ::CALC_POS::
     *     // --- Animate matrix override ---
     *     if (_useMatrix > 0.5) {
     *         vec2 lp = aPosition * vec2(vPack_vw, vPack_vh);
     *         pos = mat2(vPack_ma, vPack_mb, vPack_mc, vPack_md) * lp + vec2(vPack_tx, vPack_ty);
     *     }
     *
     * But because peote-view's template has already resolved varying names to packed
     * attrib vectors before we get here, the cleanest approach is to override the
     * vertexShader property directly. peote-view exposes vertexShader as a String on
     * the Program class — we replace a sentinel token in it.
     *
     * Since we can't run the template at override time, we instead use a different
     * strategy: store the matrix components in CUSTOM attribs (which become aShort/aFloat
     * packed attribs in the shader) and inject GLSL using Program.addVertexInjection()
     * if that API exists, or by overriding the vertexShader string post-init.
     *
     * PRACTICAL APPROACH used here:
     * The peote-view Program class exposes `vertexShader` as a public static inline String
     * on the Element class. We can override it per-Program by calling
     * `program.vertexShader = myString` before the program is added to the display.
     *
     * We generate the replacement vertex shader by taking the template and appending
     * the matrix branch as a post-CALC_POS block.
     */
    override public function init(peoteView:peote.view.PeoteView, display:peote.view.Display) {
        super.init(peoteView, display);
        injectMatrixShaderCode();
    }

    function injectMatrixShaderCode() {
        // The generated vertexShader string (from peote-view's template) will contain
        // a block that computes `vec2 pos = ...` and then adds `aPosition * size * rotmat`.
        // We append a branch AFTER that block to override pos for Animate leaves.
        //
        // peote-view's VARYINGS system packs _ma,_mb,_mc,_md,_tx,_ty,_vw,_vh,_useMatrix
        // into vec4 vPack0, vPack1, etc. varyings (passed from vertex to fragment).
        // In the VERTEX shader we need the packed attrib names, not the varying names.
        //
        // The custom attribs are packed into aFloat0, aFloat1, aFloat2 etc.
        // The EXACT layout depends on declaration order in ActorElement.
        // We declare: _ma _mb _mc _md | _tx _ty _vw _vh | _rotated _useMatrix ...
        // So: aFloat0 = vec4(_ma, _mb, _mc, _md)
        //     aFloat1 = vec4(_tx, _ty, _vw, _vh)
        //     aFloat2.x = _rotated, aFloat2.y = _useMatrix
        //
        // BUT: peote-view resolves @formula fields differently from plain @custom.
        // Fields with @formula are NOT emitted as attribs — they're computed inline.
        // Only plain @varying @custom vars become packed attribs.
        //
        // Check ActorElement field declarations:
        // _ma, _mb, _mc, _md, _tx, _ty, _vw, _vh, _rotated, _useMatrix  -> 10 plain custom floats
        // _flipX, _flipY, _mirror, adjust_x, adjust_y, scale             ->  6 plain custom floats
        // off_x (formula), off_y (formula)                               ->  NOT attribs
        //
        // Total plain custom floats: 16 -> packs into aFloat0..aFloat3
        //
        // Order in ActorElement (by declaration order):
        // [0] _ma      [1] _mb      [2] _mc      [3] _md       -> aFloat0.xyzw
        // [4] _tx      [5] _ty      [6] _vw      [7] _vh       -> aFloat1.xyzw
        // [8] _rotated [9] _useMatrix [10] _flipX [11] _flipY  -> aFloat2.xyzw
        // [12] _mirror [13] adjust_x [14] adjust_y [15] scale  -> aFloat3.xyzw
        //
        // In the vertex shader, these attrib names are available as aFloat0..aFloat3.
        // The current vertexShader string will reference them after peote resolves formulas.

        var vs = vertexShader;

        // Find the CALC_POS block and append our matrix branch after it.
        // The exact string to find is: "pos = pos + aPosition * size"
        // (with or without " * rotmat" or pivot subtraction depending on configuration).
        // We look for the end of the pos = ... chain, after which gl_Position is set.
        //
        // Insert our branch just before gl_Position assignment:
        var inject = '
    // --- Animate atlas: full affine matrix override ---
    if (aFloat2.y > 0.5) {
        // aFloat0 = (ma, mb, mc, md)  aFloat1 = (tx, ty, vw, vh)
        vec2 lp = aPosition * vec2(aFloat1.z, aFloat1.w);
        pos = mat2(aFloat0.x, aFloat0.y, aFloat0.z, aFloat0.w) * lp
              + vec2(aFloat1.x, aFloat1.y);
    }
    // --- end Animate matrix override ---
';
        // Inject before "gl_Position"
        vs = vs.replace("gl_Position", inject + "    gl_Position");
        vertexShader = vs;

        // --- Fragment shader: fix texcoords for atlas-rotated sprites ---
        // The fragment shader uses vTexCoord to sample. vTexCoord is passed from vertex
        // as the raw aPosition (0..1 quad corner).
        // For rotated sprites we need to remap before the atlas clip is applied.
        //
        // peote-view computes in fragment:
        //   vec2(vTexCoord.x * w + x, vTexCoord.y * h + y)  where w,h,x,y are clip dims/pos
        //
        // For +90 CW packed sprites (Adobe Animate convention):
        //   sample texU = clipX + (1 - vTexCoord.y) * clipW
        //   sample texV = clipY + vTexCoord.x * clipH
        //
        // We swap vTexCoord.xy when _rotated == 1.0.
        // _rotated is aFloat2.x in the vertex shader, and is passed as a varying.
        // The fragment shader has access to varyings — we need to add vRotatedFlag.
        //
        // Simplest approach: patch the CALC_TEXCOORD line.
        // peote-view sets: vTexCoord = aPosition;  (vertex shader)
        // We replace it with:
        //   if (aFloat2.x > 0.5)
        //       vTexCoord = vec2(1.0 - aPosition.y, aPosition.x);
        //   else
        //       vTexCoord = aPosition;

        vs = vertexShader;
        vs = vs.replace(
            "vTexCoord = aPosition;",
            'if (aFloat2.x > 0.5) vTexCoord = vec2(1.0 - aPosition.y, aPosition.x); else vTexCoord = aPosition;'
        );
        vertexShader = vs;
    }
}
