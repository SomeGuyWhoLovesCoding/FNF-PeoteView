package structures.gameplay;

@:publicFields
class NoteMovementSystem {
	function new(parent:NoteSystem) {
	}

	function run(parent:NoteSystem, noteSpr:VirtualNote, sustainSpr:VirtualSustain, receptor:Note, index:Int) {
		/**
			1 = noteSprX
			2 = noteSprX
			3 = noteSprScale
			4 = sustainSprRotation
		**/
		var returnValue:Array<Float> = [0.0, 0.0, 0.0, 0.0, 0.0];

		#if linc_luajit_funkinview
		var playField = parent.parent;
		if (playField != null) {
			returnValue = playField.funkinviewlua.callNoteFormula(noteSpr.diff, parent.parent.scrollSpeed, receptor.x, receptor.y, index);
			if (returnValue.length != 0) {
				noteSpr.Sx = Std.int(returnValue[0]);
				noteSpr.Sy = Std.int(returnValue[1]);
				noteSpr.scale = returnValue[2];
				sustainSpr.r = returnValue[3];
			}
		}
		#end

		return returnValue;
	}

	function dispose() {

	}
}