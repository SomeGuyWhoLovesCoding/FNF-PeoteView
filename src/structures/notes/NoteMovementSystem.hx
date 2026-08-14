package structures.notes;

import structures.notes.NoteVB.VirtualNote;
import structures.notes.NoteVB.VirtualSustain;

/**
 * Note movement system — handles custom position overrides (Lua noteFormula).
 *
 * With the LUT in place, the base positioning (cos/sin scroll) is handled
 * by NoteMovementLUT lookups in NoteSystem.drawNote(). This class now
 * only fires for Lua JIT overrides, which can further modify positions
 * after the LUT has set them.
 *
 * If you want the LUT to fully absorb a noteFormula (no Lua call needed),
 * use NoteMovementLUT.buildWithInterp() during setup — then the LUT's
 * hasExtendedLUT flag will be true, and this run() method becomes a
 * no-op for that strumline.
 */
@:publicFields
class NoteMovementSystem {
	function new(parent:NoteSystem) {}

	function run(parent:NoteSystem, noteSpr:VirtualNote, sustainSpr:VirtualSustain, receptor:Receptor, index:Int, type:Float, isHit:Bool) {
		/**
			1 = noteSprX
			2 = noteSprY
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
					noteSpr.scale = returnValue.scale * receptor.note.scale;
					if (returnValue.scrollMultiplier != 1)
						noteSpr.diff = Math.round(noteSpr.diff * returnValue.scrollMultiplier);
				}
				if (sustainSpr != null) {
					sustainSpr.r = returnValue.sustainRot;
					if (returnValue.scrollMultiplier != 1)
						sustainSpr.w = Math.round(sustainSpr.w * returnValue.scrollMultiplier);
					sustainSpr.followNote((isHit ? receptor.note.x : noteSpr.Sx) + receptor.sustainPivotX,
						(isHit ? receptor.note.y : noteSpr.Sy) + receptor.sustainPivotY, index);
				}
			}
		}
		#end
	}

	function dispose() {}
}
