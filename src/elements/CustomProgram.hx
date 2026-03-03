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
	';

	override public function addToDisplay(display:Display, ?atProgram:Program, addBefore:Bool=false)
	{
		if (!hasVertexInserted) {
			var rd = Std.downcast(display, RotatableDisplay);
			if (rd == null) throw "CustomProgram must be added to a RotatableDisplay";

			injectIntoVertexShader(DISPLAY_ROTATION_VERTEX_CODE, false, [rd.uAngle, rd.uSin, rd.uCos], false, [rd.uCenter]);

			//setFormula("rotation", "uDisplayRotation(aRot.z)", false);

			update();
			hasVertexInserted = true;
		}

		super.addToDisplay(display, atProgram, addBefore);
	}
}