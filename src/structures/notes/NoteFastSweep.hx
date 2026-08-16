package structures.notes;

import haxe.ds.Vector;

/**
 * Fast linear evaluator used while baking extended movement LUTs.
 *
 * The packed SWAR `run()` calls Math.sin/Math.cos at every quantized diff row,
 * which is the dominant cost of NoteMovementLUT.buildWithInterp() (thousands
 * of trig calls per lane per rebuild). This class instead evaluates the
 * bytecode sequentially and classifies each SIN/COS site using the first three
 * probe rows:
 *
 *   - FOLD  : operand is constant across rows -> evaluate once.
 *   - RECUR : operand is affine in `diff` -> advance sin/cos via the rotation
 *             recurrence  sin(x+h) = sin(x)cos(h) + cos(x)sin(h), collapsing
 *             ~4097 trig calls per site to 4.
 *   - DIRECT: anything else -> per-row Math.sin/Math.cos (rare).
 *
 * Used only during LUT building (config changes). Per-frame rendering and the
 * LuaJIT fallback still use NoteMovementInterp.run() untouched.
 */
@:publicFields
class NoteFastSweep {
	static inline var M_DIRECT = 0;
	static inline var M_FOLD = 1;
	static inline var M_RECUR = 2;

	var interp:NoteMovementInterp;
	var ops:Array<Int>;
	var args:Array<Int>;
	var constants:Array<Float>;
	var locals:Vector<Float>;
	var stack:Vector<Float>;

	/** diff value at row 0 (LUT minDiff). */
	var base:Float;

	// --- per-opcode classification state ---
	var modes:Vector<Int>;
	var seen:Vector<Int>; // bit0/1/2 = probe row 0/1/2 executed this site
	var probe0:Vector<Float>;
	var probe1:Vector<Float>;
	var probe2:Vector<Float>;
	var siteCos:Vector<Bool>;
	var classified:Bool;

	// --- FOLD state ---
	var foldVal:Vector<Float>;

	// --- RECUR state ---
	var recA:Vector<Float>;
	var recB:Vector<Float>;
	var recSH:Vector<Float>;
	var recCH:Vector<Float>;
	var recSin:Vector<Float>;
	var recCosVal:Vector<Float>;
	var recLastRow:Vector<Int>;
	var recInit:Vector<Bool>;

	public function new(interp:NoteMovementInterp, base:Float) {
		this.interp = interp;
		this.ops = interp.ops;
		this.args = interp.args;
		this.constants = interp.constants;
		this.locals = interp.locals;
		this.stack = interp.stack;
		this.base = base;

		var n = ops.length;
		modes = new Vector<Int>(n);
		seen = new Vector<Int>(n);
		probe0 = new Vector<Float>(n);
		probe1 = new Vector<Float>(n);
		probe2 = new Vector<Float>(n);
		siteCos = new Vector<Bool>(n);
		foldVal = new Vector<Float>(n);
		recA = new Vector<Float>(n);
		recB = new Vector<Float>(n);
		recSH = new Vector<Float>(n);
		recCH = new Vector<Float>(n);
		recSin = new Vector<Float>(n);
		recCosVal = new Vector<Float>(n);
		recLastRow = new Vector<Int>(n);
		recInit = new Vector<Bool>(n);
		for (i in 0...n) {
			modes[i] = M_DIRECT;
			seen[i] = 0;
			siteCos[i] = false;
			recInit[i] = false;
		}
	}

	/**
	 * Evaluate the bytecode for one quantized diff row.
	 * Rows 0-2 double as probes; from row 3 on, classified sites use
	 * recurrence / constant-folding.
	 */
	public function run(row:Int, diff:Float, scrollSpeed:Float, receptorX:Float, receptorY:Float, index:Float, type:Float,
			baseResult:NoteFormulaResult):NoteFormulaResult {
		if (!classified && row == 3)
			classify();

		locals[0] = baseResult.x;
		locals[1] = baseResult.y;
		locals[2] = baseResult.scale;
		locals[3] = baseResult.sustainRot;
		locals[4] = baseResult.scrollMultiplier;
		locals[5] = diff;
		locals[6] = scrollSpeed;
		locals[7] = receptorX;
		locals[8] = receptorY;
		locals[9] = index;
		locals[10] = type;

		var sp = 0;
		var ap = 0;
		var n = ops.length;

		for (p in 0...n) {
			switch (ops[p]) {
				case 0x10:
					stack[sp++] = constants[args[ap++]];
				case 0x11:
					stack[sp++] = locals[args[ap++]];
				case 0x20:
					locals[args[ap++]] = stack[--sp];
				case 0x30:
					return null;
				case 0x31:
					var b = stack[--sp];
					var a = stack[--sp];
					if (a != b) return null;
				case 0x32:
					var b = stack[--sp];
					var a = stack[--sp];
					if (a == b) return null;
				case 0x00:
					var b = stack[--sp];
					var a = stack[--sp];
					stack[sp++] = a + b;
				case 0x01:
					var b = stack[--sp];
					var a = stack[--sp];
					stack[sp++] = a - b;
				case 0x02:
					var b = stack[--sp];
					var a = stack[--sp];
					stack[sp++] = a * b;
				case 0x03:
					var b = stack[--sp];
					var a = stack[--sp];
					stack[sp++] = b != 0 ? a / b : 0;
				case 0x04:
					var b = stack[--sp];
					var a = stack[--sp];
					stack[sp++] = b != 0 ? a % b : 0;
				case 0x05:
					stack[sp - 1] = evalTrig(p, row, diff, stack[sp - 1], false);
				case 0x06:
					stack[sp - 1] = evalTrig(p, row, diff, stack[sp - 1], true);
				case 0x07:
					var b = stack[--sp];
					if (b < stack[sp - 1]) stack[sp - 1] = b;
				case 0x08:
					var b = stack[--sp];
					if (b > stack[sp - 1]) stack[sp - 1] = b;
				case 0x09:
					stack[sp - 1] = Math.abs(stack[sp - 1]);
				case 0x0A:
					stack[sp - 1] = stack[sp - 1] == 0 ? 1.0 : 0.0;
				case 0x0B:
					var b = stack[--sp];
					var a = stack[sp - 1];
					stack[sp - 1] = a != 0 ? b : 0.0;
				case 0x0C:
					var b = stack[--sp];
					var a = stack[sp - 1];
					stack[sp - 1] = a != 0 ? a : b;
				case 0x33:
					{}
				default:
					{}
			}
		}

		baseResult.x = locals[0];
		baseResult.y = locals[1];
		baseResult.scale = locals[2];
		baseResult.sustainRot = locals[3];
		baseResult.scrollMultiplier = locals[4];
		return baseResult;
	}

	inline function evalTrig(p:Int, row:Int, diff:Float, v:Float, isCos:Bool):Float {
		if (!classified) {
			recordProbe(p, row, v, isCos);
			return isCos ? Math.cos(v) : Math.sin(v);
		}
		switch (modes[p]) {
			case M_FOLD:
				return foldVal[p];
			case M_RECUR:
				return evalRecur(p, row, diff, isCos);
			default:
				return isCos ? Math.cos(v) : Math.sin(v);
		}
	}

	inline function recordProbe(p:Int, row:Int, v:Float, isCos:Bool) {
		siteCos[p] = isCos;
		switch (row) {
			case 0:
				seen[p] |= 1;
				probe0[p] = v;
			case 1:
				seen[p] |= 2;
				probe1[p] = v;
			case 2:
				seen[p] |= 4;
				probe2[p] = v;
			default:
		}
	}

	function classify() {
		classified = true;
		var n = ops.length;
		for (p in 0...n) {
			if (seen[p] != 7)
				continue;
			var v0 = probe0[p];
			var v1 = probe1[p];
			var v2 = probe2[p];
			var spread = Math.abs(v0) + Math.abs(v1) + Math.abs(v2);

			// Constant operand -> evaluate once.
			if (Math.abs(v1 - v0) <= 1e-12 * (1 + spread) && Math.abs(v2 - v1) <= 1e-12 * (1 + spread)) {
				modes[p] = M_FOLD;
				foldVal[p] = siteCos[p] ? Math.cos(v0) : Math.sin(v0);
				continue;
			}

			// Operand affine in diff (second difference ~ 0) -> recurrence.
			var a = v1 - v0;
			var secondDiff = v2 - 2 * v1 + v0;
			if (Math.abs(secondDiff) <= 1e-9 * (1 + spread)) {
				modes[p] = M_RECUR;
				recA[p] = a;
				recB[p] = v0 - a * base;
				continue;
			}

			// Non-linear -> direct Math.sin/Math.cos per row.
			modes[p] = M_DIRECT;
		}
	}

	inline function evalRecur(p:Int, row:Int, diff:Float, isCos:Bool):Float {
		if (!recInit[p]) {
			var arg = recA[p] * diff + recB[p];
			recSin[p] = Math.sin(arg);
			recCosVal[p] = Math.cos(arg);
			recSH[p] = Math.sin(recA[p]);
			recCH[p] = Math.cos(recA[p]);
			recLastRow[p] = row;
			recInit[p] = true;
		} else {
			var steps = row - recLastRow[p];
			if (steps > 0) {
				var sh = recSH[p];
				var ch = recCH[p];
				var s = recSin[p];
				var c = recCosVal[p];
				for (k in 0...steps) {
					var ns = s * ch + c * sh;
					var nc = c * ch - s * sh;
					s = ns;
					c = nc;
				}
				recSin[p] = s;
				recCosVal[p] = c;
				recLastRow[p] = row;
			}
		}
		return isCos ? recCosVal[p] : recSin[p];
	}
}