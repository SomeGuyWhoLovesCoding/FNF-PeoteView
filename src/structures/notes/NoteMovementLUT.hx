package structures.notes;

import haxe.ds.Vector;

/**
 * Precomputed Look-Up Table for note movement positions.
 *
 * Maps quantized integer diff (pixel-distance from receptor) to
 * pre-rounded screen-space offsets, eliminating per-note
 * Math.cos / Math.sin calls at runtime.
 *
 * One LUT per strumline — scrollDirection is strumline-constant,
 * so the same offsets apply to every receptor in that strumline.
 *
 * Memory: ~32 KB per strumline at default range (4097 entries * 2 ints * 4 bytes)
 * With 2000 notes/frame, this replaces 4000 trig calls with 4000 L1-cache reads.
 *
 * Build paths:
 *   - build()              — linear scroll:  offset = round(d * cos/sin(dir))
 *   - buildWithInterp()    — custom noteFormula via NoteMovementInterp
 *
 * The LUT is rebuilt only on configuration changes (noteskin swap, scrollDirection
 * change, window resize) — never per-frame.
 */
@:publicFields
class NoteMovementLUT {
	// ------------------------------------------------------------------
	// Configurable range
	// ------------------------------------------------------------------
	// ±2048 covers scrollSpeed up to ~2x with default spawn/despawn distances.
	// Out-of-range diffs fall back to direct computation (rare).
	static var DEFAULT_MIN_DIFF:Int = -2048;
	static var DEFAULT_MAX_DIFF:Int = 2048;

	// ------------------------------------------------------------------
	// Precomputed direction components (kept for out-of-range fallback)
	// ------------------------------------------------------------------
	var cosDir:Float = 1.0;
	var sinDir:Float = 0.0;

	// ------------------------------------------------------------------
	// Core LUT storage — pre-rounded integer pixel offsets
	// ------------------------------------------------------------------
	// offsetX[i] = Math.round(d * cosDir)  where d = minDiff + i
	// offsetY[i] = Math.round(d * sinDir)
	var offsetX:Vector<Int>;
	var offsetY:Vector<Int>;

	// ------------------------------------------------------------------
	// Extended LUT storage (used only with NoteMovementInterp)
	// ------------------------------------------------------------------
	// When a custom noteFormula is baked in, scale and sustainRot may vary
	// per diff. These vectors store the interp's outputs.
	var scaleLUT:Vector<Float>;
	var sustainRotLUT:Vector<Float>;
	var scrollMulLUT:Vector<Float>;

	// ------------------------------------------------------------------
	// LUT range metadata
	// ------------------------------------------------------------------
	var minDiff:Int = 0;
	var maxDiff:Int = 0;
	var entries:Int = 0;

	// Whether this LUT is valid (built at least once)
	var valid:Bool = false;

	// Whether scaleLUT / sustainRotLUT / scrollMulLUT are populated
	var hasExtendedLUT:Bool = false;

	function new() {}

	// ==================================================================
	// Build: Linear scroll (default path — replaces per-note cos/sin)
	// ==================================================================

	/**
	 * Build LUT for standard linear scroll:
	 *   x_offset = round(d * cos(scrollDirection * DEG_TO_RAD))
	 *   y_offset = round(d * sin(scrollDirection * DEG_TO_RAD))
	 *
	 * @param scrollDirection  Scroll angle in degrees (e.g. -90 = upscroll)
	 * @param minDiff         Minimum integer d value to precompute (optional)
	 * @param maxDiff         Maximum integer d value to precompute (optional)
	 */
	function build(scrollDirection:Float, ?minDiff:Int, ?maxDiff:Int) {
		this.minDiff = minDiff != null ? minDiff : DEFAULT_MIN_DIFF;
		this.maxDiff = maxDiff != null ? maxDiff : DEFAULT_MAX_DIFF;
		this.entries = this.maxDiff - this.minDiff + 1;

		this.cosDir = Math.cos(scrollDirection * 0.01745329);
		this.sinDir = Math.sin(scrollDirection * 0.01745329);

		ensureCapacity();

		var c = cosDir;
		var s = sinDir;
		var base = this.minDiff;

		for (i in 0...entries) {
			var d:Float = base + i;
			offsetX[i] = Math.round(d * c);
			offsetY[i] = Math.round(d * s);
		}

		hasExtendedLUT = false;
		scaleLUT = null;
		sustainRotLUT = null;
		scrollMulLUT = null;
		valid = true;
	}

	// ==================================================================
	// Build: Custom noteFormula via NoteMovementInterp
	// ==================================================================

	/**
	 * Build LUT by evaluating a NoteMovementInterp at every quantized diff.
	 * Stores x-offset, y-offset, scale, sustainRot, and scrollMultiplier
	 * per diff step, fully replacing the per-note VM dispatch.
	 *
	 * @param interp          Compiled NoteMovementInterp instance
	 * @param scrollDirection Scroll angle in degrees (for fallback)
	 * @param scrollSpeed     Current scroll speed
	 * @param receptorX       Receptor X position
	 * @param receptorY       Receptor Y position
	 * @param receptorScale   Receptor scale
	 * @param index           Lane index
	 * @param type            Note type
	 * @param minDiff         Minimum d (optional)
	 * @param maxDiff         Maximum d (optional)
	 */
	function buildWithInterp(interp:NoteMovementInterp,
			scrollDirection:Float,
			scrollSpeed:Float,
			receptorX:Float, receptorY:Float,
			receptorScale:Float,
			index:Float, type:Float,
			?minDiff:Int, ?maxDiff:Int) {
		this.minDiff = minDiff != null ? minDiff : DEFAULT_MIN_DIFF;
		this.maxDiff = maxDiff != null ? maxDiff : DEFAULT_MAX_DIFF;
		this.entries = this.maxDiff - this.minDiff + 1;

		this.cosDir = Math.cos(scrollDirection * 0.01745329);
		this.sinDir = Math.sin(scrollDirection * 0.01745329);

		ensureCapacity();

		if (scaleLUT == null || scaleLUT.length < entries)
			scaleLUT = new Vector<Float>(entries);
		if (sustainRotLUT == null || sustainRotLUT.length < entries)
			sustainRotLUT = new Vector<Float>(entries);
		if (scrollMulLUT == null || scrollMulLUT.length < entries)
			scrollMulLUT = new Vector<Float>(entries);

		var baseResult = new NoteFormulaResult();
		var c = cosDir;
		var s = sinDir;
		var base = this.minDiff;

		for (i in 0...entries) {
			var diff:Float = base + i;

			// Seed the baseResult with receptor defaults.
			// scale is seeded as the identity multiplier (1.0), not receptorScale,
			// because drawNote() multiplies the LUT scale by rec.scale at runtime
			// (matching the LuaJIT path). Seeding the absolute receptorScale here
			// caused the scale to be applied twice on abort / unset-scale rows.
			baseResult.x = receptorX;
			baseResult.y = receptorY;
			baseResult.scale = 1.0;
			baseResult.sustainRot = 0.0;
			baseResult.scrollMultiplier = 1.0;

			var result = interp.run(diff, scrollSpeed, receptorX, receptorY, index, type, baseResult);
			if (result != null) {
				offsetX[i] = Math.round(result.x - receptorX);
				offsetY[i] = Math.round(result.y - receptorY);
				scaleLUT[i] = result.scale;
				sustainRotLUT[i] = result.sustainRot;
				scrollMulLUT[i] = result.scrollMultiplier;
			} else {
				// Formula aborted for this diff — linear fallback.
				// scale falls back to the identity multiplier (1.0), since
				// drawNote() multiplies by rec.scale at runtime.
				offsetX[i] = Math.round(diff * c);
				offsetY[i] = Math.round(diff * s);
				scaleLUT[i] = 1.0;
				sustainRotLUT[i] = 0.0;
				scrollMulLUT[i] = 1.0;
			}
		}

		hasExtendedLUT = true;
		valid = true;
	}

	// ==================================================================
	// Runtime Lookups
	// ==================================================================

	/**
	 * Fast X offset lookup.
	 * In-range: single Vector read (L1 cache hit for the working set).
	 * Out-of-range: direct computation (rare, only at extreme diffs).
	 */
	inline function lookupX(d:Int):Int {
		var idx = d - minDiff;
		if (idx >= 0 && idx < entries)
			return offsetX[idx];
		return Math.round(d * cosDir);
	}

	/**
	 * Fast Y offset lookup.
	 */
	inline function lookupY(d:Int):Int {
		var idx = d - minDiff;
		if (idx >= 0 && idx < entries)
			return offsetY[idx];
		return Math.round(d * sinDir);
	}

	/**
	 * Scale lookup. Returns defaultScale when the extended LUT is not active.
	 */
	inline function lookupScale(d:Int, defaultScale:Float):Float {
		if (!hasExtendedLUT)
			return defaultScale;
		var idx = d - minDiff;
		if (idx >= 0 && idx < entries)
			return scaleLUT[idx];
		// Out-of-range with an extended LUT: the LUT stores a relative
		// multiplier, so fall back to identity (1.0), not defaultScale —
		// the caller multiplies by the absolute scale at runtime.
		return 1.0;
	}

	/**
	 * Sustain rotation lookup. Returns 0.0 when the extended LUT is not active.
	 */
	inline function lookupSustainRot(d:Int):Float {
		if (!hasExtendedLUT)
			return 0.0;
		var idx = d - minDiff;
		if (idx >= 0 && idx < entries)
			return sustainRotLUT[idx];
		return 0.0;
	}

	/**
	 * Scroll multiplier lookup. Returns 1.0 when the extended LUT is not active.
	 */
	inline function lookupScrollMul(d:Int):Float {
		if (!hasExtendedLUT)
			return 1.0;
		var idx = d - minDiff;
		if (idx >= 0 && idx < entries)
			return scrollMulLUT[idx];
		return 1.0;
	}

	// ==================================================================
	// Internal
	// ==================================================================

	inline function ensureCapacity() {
		if (offsetX == null || offsetX.length < entries) {
			offsetX = new Vector<Int>(entries);
			offsetY = new Vector<Int>(entries);
		}
	}

	function dispose() {
		offsetX = null;
		offsetY = null;
		scaleLUT = null;
		sustainRotLUT = null;
		scrollMulLUT = null;
		valid = false;
		hasExtendedLUT = false;
	}
}
