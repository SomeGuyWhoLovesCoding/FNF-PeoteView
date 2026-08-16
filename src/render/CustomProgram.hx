package render;

import peote.view.PeoteGL.GLUniformLocation;
import peote.view.Program;

@:publicFields
class CustomProgram extends Program {
	private var hasVertexInserted(default, null):Bool;

	private static inline var DISPLAY_ROTATION_VERTEX_CODE = '
        float uDisplayRotateX(vec2 p) {
            vec2 r = p - uDisplayC;
            return uSin.x*r.x - uSin.y*r.y + uDisplayC.x;
        }

        float uDisplayRotateY(vec2 p) {
            vec2 r = p - uDisplayC;
            // FIX: uSin was invalid GLSL. Changed to uSin.x
            return uSin.y*r.x + uSin.x*r.y + uDisplayC.y;
        }

        float uDisplayRotation(float r) {
            return (r + uDisplayAngle) * 57.29577951;
        }

        float mixHelperF(float a1, float a2, float a3) {
            return mix(a1, a2, a3);
        }
    ';

	function new(buffer:BufferInterface) {
		super(buffer);

		blendEnabled = true;
		blendSrc = blendSrcAlpha = BlendFactor.ONE;
		blendDst = blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;
	}

	override public function addToDisplay(display:Display, ?atProgram:Program, addBefore:Bool = false) {
		if (!hasVertexInserted) {
			var rd = Std.downcast(display, RotatableDisplay);
			if (rd == null)
				throw "CustomProgram must be added to a RotatableDisplay";

			injectIntoVertexShader(DISPLAY_ROTATION_VERTEX_CODE, false, ["uDisplayAngle" => rd.uAngle, "uSin" => rd.uSin, "uDisplayC" => rd.uCenter], false);

			// setFormula("rotation", "uDisplayRotation(aRot.z)", false);

			update();
			hasVertexInserted = true;
		}

		super.addToDisplay(display, atProgram, addBefore);
	}
}
