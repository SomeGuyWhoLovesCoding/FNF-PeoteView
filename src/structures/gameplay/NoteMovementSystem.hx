package structures.gameplay;

import structures.gameplay.NoteVB.VirtualNote;
import structures.gameplay.NoteVB.VirtualSustain;

@:publicFields
class NoteMovementSystem {
	function new(parent:NoteSystem) {
	}

	function run(parent:NoteSystem, noteSpr:VirtualNote, sustainSpr:VirtualSustain, receptor:Note, index:Int, type:Float, isHit:Bool) {
		/**
			1 = noteSprX
			2 = noteSprX
			3 = noteSprScale
			4 = sustainSprRotation
		**/
		#if linc_luajit_funkinview
		var playField = parent.parent;
		if (playField != null) {
			var lua = playField.funkinviewlua;
			var returnValue = lua.callNoteFormula(noteSpr.diff, parent.parent.scrollSpeed, receptor.x, receptor.y, index, type);
			if (returnValue == null) return;

			if (noteSpr != null) {
				noteSpr.Sx = Std.int(returnValue.x);
				noteSpr.Sy = Std.int(returnValue.y);
				noteSpr.scale = returnValue.scale;
				if (returnValue.scrollMultiplier != 1) noteSpr.diff = Std.int(noteSpr.diff * returnValue.scrollMultiplier);
			}
			if (sustainSpr != null) {
				sustainSpr.r = returnValue.sustainRot;
				if (returnValue.scrollMultiplier != 1) sustainSpr.w = Std.int(sustainSpr.w * returnValue.scrollMultiplier);
				sustainSpr.followNote(isHit ? receptor.x : noteSpr.Sx, isHit ? receptor.y : noteSpr.Sy, index);
			}
		}
		#end
	}

	function dispose() {

	}
}