package elements;

/**
	CustomProgram is a class that extends Program with added rotation support at the vertex level.
**/
@:publicFields
class CustomProgram extends Program
{
	private var hasVertexInserted(default, null):Bool;
	private static inline var ROTATION_VERTEX_CODE = '
		float uDisplayRotateX(float px, float py) {
			float rx = px - uDisplayCX;
			float ry = py - uDisplayCY;
			return uCos*rx - uSin*ry + uDisplayCX;
		}

		float uDisplayRotateY(float px, float py) {
			float rx = px - uDisplayCX;
			float ry = py - uDisplayCY;
			return uSin*rx + uCos*ry + uDisplayCY;
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

			injectIntoVertexShader(ROTATION_VERTEX_CODE, false, [rd.uAngle, rd.uSin, rd.uCos, rd.uCenterX, rd.uCenterY]);

			//setFormula("rotation", "uDisplayRotation(aRot.z)", false);

			update();
			hasVertexInserted = true;
		}

		super.addToDisplay(display, atProgram, addBefore);
	}
}