package structures.notes;

import structures.notes.NoteVB.VirtualNote;
import structures.notes.NoteVB.VirtualSustain;

/**
 * Note movement system — owns the NoteMovementInterp and coordinates
 * with NoteSystem's per-lane LUTs.
 *
 * When a custom noteFormula is set via setFormula(), the interp is
 * compiled and the LUTs are rebuilt with buildWithInterp(), baking
 * the entire formula (position, scale, sustainRot, scrollMultiplier)
 * into the LUT at every quantized diff step.
 *
 * Runtime flow (drawNote per-note):
 *   - LUT has hasExtendedLUT == true:
 *       drawNote() applies scale/sustainRot/scrollMul inline from LUT,
 *       then SKIPS this run() call entirely. Zero VM dispatch.
 *   - LUT has hasExtendedLUT == false:
 *       drawNote() calls this run(), which falls through to the
 *       LuaJIT callNoteFormula() path for runtime evaluation.
 *
 * The extended-LUT path is now fully handled inline in drawNote(),
 * making this run() method a LuaJIT-only fallback.
 */
@:publicFields
class NoteMovementSystem {
	/** Compiled bytecode interp. Null when no custom formula is active. */
	var interp:NoteMovementInterp = null;

	/** Whether a custom noteFormula interp is currently active. */
	var hasInterp:Bool = false;

	function new(parent:NoteSystem) {}

	/**
	 * Compile a noteFormula Lua source string into the bytecode interp
	 * and rebuild all per-lane LUTs via the parent NoteSystem.
	 *
	 * This is the replacement for FunkinViewLua.setNoteFormulaSource():
	 * instead of evaluating the formula per-note per-frame in LuaJIT,
	 * we compile it once and bake every possible output into the LUT.
	 *
	 * @param codeStr  Lua source containing "function noteFormula(diff, scrollSpeed, receptorX, receptorY, index, type)"
	 */
	function setFormula(parent:NoteSystem, codeStr:String) {
		if (codeStr == null || StringTools.trim(codeStr) == "") {
			clearFormula(parent);
			return;
		}
		try {
			interp = new NoteMovementInterp(codeStr);
			hasInterp = true;
		} catch (e:Dynamic) {
			// Compilation failed — keep previous state
			trace("NoteMovementInterp compilation failed: " + e);
			return;
		}
		// Rebuild LUTs with the interp baked in
		parent.rebuildMovementLUTs();
	}

	/**
	 * Clear the custom formula, revert to linear scroll LUTs.
	 */
	function clearFormula(parent:NoteSystem) {
		interp = null;
		hasInterp = false;
		parent.rebuildMovementLUTs();
	}

	/**
	 * Per-note movement override.
	 *
	 * If the LUT for this (strumline, lane) has hasExtendedLUT == true,
	 * the formula's scale, sustainRot, and scrollMultiplier are already
	 * baked into the LUT — apply them and return (no Lua call needed).
	 *
	 * Otherwise, fall through to the LuaJIT callNoteFormula() path
	 * for runtime evaluation.
	 */
	function run(parent:NoteSystem, noteSpr:VirtualNote, sustainSpr:VirtualSustain, receptor:Receptor, index:Int, type:Float, isHit:Bool) {
		/**
			1 = noteSprX
			2 = noteSprY
			3 = noteSprScale
			4 = sustainSprRotation
		**/

		// --- LUT-driven path (interp baked in) ---
		var lane = Std.int(type) % parent.strumlines.length;
		var lutArr = parent.movementLUTs[lane];
		if (lutArr != null && index < lutArr.length) {
			var lut = lutArr[index];
			if (lut != null && lut.valid && lut.hasExtendedLUT) {
				var d = noteSpr.diff;

				// Scale
				noteSpr.scale = lut.lookupScale(d, receptor.note.scale) * receptor.note.scale;

				// Sustain rotation + scroll multiplier
				if (sustainSpr != null) {
					sustainSpr.r = lut.lookupSustainRot(d);
					var scrollMul = lut.lookupScrollMul(d);
					if (scrollMul != 1.0)
						sustainSpr.w = Math.round(sustainSpr.w * scrollMul);
					sustainSpr.followNote((isHit ? receptor.note.x : noteSpr.Sx) + receptor.sustainPivotX,
						(isHit ? receptor.note.y : noteSpr.Sy) + receptor.sustainPivotY, index);
				}

				// Done — no Lua call needed
				return;
			}
		}

		// --- LuaJIT fallback (no interp / no extended LUT) ---
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

	function dispose() {
		interp = null;
		hasInterp = false;
	}
}
