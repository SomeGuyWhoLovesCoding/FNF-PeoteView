package structures.notes;

import structures.notes.NoteVB.VirtualNote;
import structures.notes.NoteVB.VirtualSustain;

@:publicFields
class NoteMovementSystem {
	function new(parent:NoteSystem) {
	}

	function run(parent:NoteSystem, noteSpr:VirtualNote, sustainSpr:VirtualSustain, receptor:Receptor, index:Int, type:Float, isHit:Bool) {
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
			var returnValue = lua.callNoteFormula(noteSpr.diff, parent.parent.scrollSpeed, receptor.note.x, receptor.note.y, index, type);
			if (returnValue != null) {
				if (noteSpr != null) {
					noteSpr.Sx = Math.round(returnValue.x);
					noteSpr.Sy = Math.round(returnValue.y);
					noteSpr.scale = returnValue.scale;
					if (returnValue.scrollMultiplier != 1) noteSpr.diff = Math.round(noteSpr.diff * returnValue.scrollMultiplier);
				}
				if (sustainSpr != null) {
					sustainSpr.r = returnValue.sustainRot;
					if (returnValue.scrollMultiplier != 1) sustainSpr.w = Math.round(sustainSpr.w * returnValue.scrollMultiplier);
					sustainSpr.followNote((isHit ? receptor.note.x : noteSpr.Sx) + receptor.sustainPivotX, (isHit ? receptor.note.y : noteSpr.Sy) + receptor.sustainPivotY, index);
				}
			}
		}
		#end
	}

	function dispose() {

	}
}