package elements;

import peote.view.PeoteGL.GLUniformLocation;
import peote.view.Program;

/**
	CustomProgram is a class that extends Program with added rotation support at the vertex level.
	But I have a warning though, inside the class's code is overriden code for a new feature called Uniform Vectors.
**/
@:publicFields
class CustomProgram extends Program
{
	private var hasVertexInserted(default, null):Bool;
	private static inline var DISPLAY_ROTATION_VERTEX_CODE = '
		float uDisplayRotateX(vec2 p) {
			vec2 r = p - uDisplayC;
			return uCos*r.x - uSin*r.y + uDisplayC.x;
		}

		float uDisplayRotateY(vec2 p) {
			vec2 r = p - uDisplayC;
			return uSin*r.x + uCos*r.y + uDisplayC.y;
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

	override public function addToDisplay(display:Display, ?atProgram:Program, addBefore:Bool=false)
	{
		if (!hasVertexInserted) {
			var rd = Std.downcast(display, RotatableDisplay);
			if (rd == null) throw "CustomProgram must be added to a RotatableDisplay";

			// no way
			rd.uAngle = rd.uAngle_map[this] = new UniformFloat("uDisplayAngle", 0.0);
			rd.uAngle.program = this;
			rd.uSin = rd.uSin_map[this] = new UniformFloat("uSin", 0.0);
			rd.uSin.program = this;
			rd.uCos = rd.uCos_map[this] = new UniformFloat("uCos", 1.0); // this has to be 1.0. cosine is just sine but inverted.
			rd.uCos.program = this;
			rd.uCenter = rd.uCenter_map[this] = new UniformVector("uDisplayC", [display.x + display.width * 0.5, display.y + display.height * 0.5]);
			rd.uCenter.program = this;

			injectIntoVertexShader(DISPLAY_ROTATION_VERTEX_CODE, false, [rd.uAngle, rd.uSin, rd.uCos], false, [rd.uCenter]);

			//setFormula("rotation", "uDisplayRotation(aRot.z)", false);

			update();
			hasVertexInserted = true;
		}

		super.addToDisplay(display, atProgram, addBefore);
	}
}