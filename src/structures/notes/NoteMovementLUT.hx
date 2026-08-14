package structures.notes;

import haxe.io.Bytes;
import haxe.io.Float32Array;

import peote.view.Texture;
import peote.view.TextureData;
import peote.view.TextureFormat;
import peote.view.Uniform.UniformFloat;
import peote.view.PeoteGL;

import peote.view.intern.Util;

import structures.gameplay.Strumline;

/**
	Bakes the output of the note movement formula (or the linear fallback)
	into a per-(type,index) lookup table.

	The bake happens on the CPU ONCE (when the formula loads, the scroll
	speed changes, the strumlines move, downscroll toggles, or a new
	(type,index) pair becomes visible). After that, per-frame note
	processing is reduced to a handful of array reads instead of running
	the bytecode interpreter for every note every frame.

	Two representations are kept in sync:

	- `data` (CPU, stride 5): x, y, scale, sustainRot, scrollMultiplier.
	  Used by the CPU logic (ambient occlusion scale compares, sustain `w`
	  via the scrollMultiplier channel) and as the source for the GPU LUT.
	- `textureData` / `texture` (GPU, RGBA float): x, y, scale, sustainRot.
	  Added to the notes + sustain programs as the FIRST custom texture
	  layer (`lutLayer`), so it is always `uTexture0` in the vertex shader.
	  The vertex shader samples it to compute note/sustain positions on the
	  GPU, eliminating per-frame element rewrites.

	The GPU path is only used when float texture support is available
	(`PeoteGL.Version.isES3`). Otherwise an RGBA8 dummy texture is still
	created so the shaders compile, and `aLutMode` stays 0 (the CPU path,
	which still reads the baked table and is itself much faster than the
	interpreter).

	The table is keyed by `note.type * MAX_INDEX + note.index`. Rows are
	allocated lazily for (type,index) pairs that actually appear.
**/
@:publicFields
class NoteMovementLUT {
	// ------------------------------------------------------------------
	// Geometry of the table
	// ------------------------------------------------------------------

	/** Texels per row; one texel per pixel of scroll distance. */
	public static var WIDTH:Int = 2048;

	/** Smallest scroll offset (px) covered. Spawn is at +1600px of `diff`. */
	public static var AXIS_MIN:Float = -1600.0;

	/** Largest scroll offset (px) covered: AXIS_MIN + WIDTH. */
	public static var AXIS_MAX:Float = AXIS_MIN + WIDTH;

	/** uv per scroll pixel. */
	public static var UV_SCALE:Float = 1.0 / WIDTH;

	/** Maximum number of allocated (type,index) rows. */
	public static var MAX_ROWS:Int = 128;

	/** Index values above this are clamped (mania is well below 16). */
	public static var MAX_INDEX:Int = 16;

	/** Number of possible `note.type` values. */
	public static var MAX_TYPE:Int = 256;

	public static var ROW_STRIDE:Int = 5;

	// ------------------------------------------------------------------
	// Shared uniforms (uploaded once per frame by the render loop)
	// ------------------------------------------------------------------

	/** Current song position in ms (including latency), float. */
	public static var uScroll:UniformFloat = new UniformFloat(0.0);

	/** Current scroll speed in px/ms. */
	public static var uSpeed:UniformFloat = new UniformFloat(1.0);

	// ------------------------------------------------------------------
	// GLSL injected into every note/sustain vertex shader
	// ------------------------------------------------------------------

	/**
		Vertex shader code that samples the LUT. Always injected (even in
		CPU fallback mode) because the `@posX` / `@posY` formulas of `Note`
		and `Sustain` reference these functions at compile time.
	**/
	public static function vertexShaderCode():String {
		var sample = PeoteGL.Version.isES3 ? "texture" : "texture2D";
		return '
			uniform sampler2D uTexture0;
			const float uLutAxisMin = ${Util.toFloatString(AXIS_MIN)};
			const float uLutUVScale = ${Util.toFloatString(UV_SCALE)};
			const float uLutVScale = ${Util.toFloatString(1.0 / MAX_ROWS)};
			vec4 uLutSample(float scrollBase, float lane) {
				float d = (uScroll - scrollBase) * uSpeed;
				float u = clamp((d - uLutAxisMin) * uLutUVScale, 0.0, 1.0);
				float v = (lane + 0.5) * uLutVScale;
				return $sample(uTexture0, vec2(u, v));
			}
			vec2 uLutPos(float scrollBase, float lane, float mode, vec2 cpuPos, vec2 recPos) {
				vec2 lut = uLutSample(scrollBase, lane).xy;
				if (mode >= 1.5) return recPos;
				return mix(cpuPos, lut, clamp(mode, 0.0, 1.0));
			}
		';
	}

	// ------------------------------------------------------------------
	// State
	// ------------------------------------------------------------------

	var texture:Texture;
	var textureData:TextureData;
	var lutDataBytes:Bytes;

	/** true when the GPU float LUT is usable (ES3 float textures). */
	public var gpuEnabled(default, null):Bool = false;

	/** true when the lutLayer has been attached to the note programs. */
	public var attached(default, null):Bool = false;

	/** key -> row; -1 when not allocated. size MAX_TYPE * MAX_INDEX. */
	var rowFor:Array<Int>;

	/** row -> key. */
	var rowKeys:Array<Int>;

	/** Number of allocated rows. */
	public var rowCount(default, null):Int = 0;

	/** CPU table, stride ROW_STRIDE: x, y, scale, sustainRot, scrollMultiplier. */
	var data:Float32Array;

	/** Number of strumlines (derives `lane = type % strumlineCount`). */
	var strumlineCount:Int = 2;

	/** Pending (type,index) pairs discovered while processing notes. */
	var pendingKeys:Array<Int> = [];

	// Cached bake inputs for change detection / re-bake.
	var bakeSpeed:Float = -1.0;
	var bakeDownScroll:Bool = false;
	var bakeFormulaVersion:Int = -1;
	var bakeStrumX:Array<Float> = [];
	var bakeStrumY:Array<Float> = [];
	var bakeStrumDir:Array<Int> = [];
	var bakeStrumScale:Array<Float> = [];

	public function new(strumlineCount:Int) {
		this.strumlineCount = strumlineCount;
		rowFor = [for (_ in 0...(MAX_TYPE * MAX_INDEX)) -1];
		rowKeys = [for (_ in 0...MAX_ROWS) -1];
		data = new Float32Array(MAX_ROWS * WIDTH * ROW_STRIDE);
	}

	inline function keyOf(type:Int, index:Int):Int {
		var t = type % MAX_TYPE;
		if (t < 0) t = 0;
		var i = index % MAX_INDEX;
		if (i < 0) i = 0;
		return t * MAX_INDEX + i;
	}

	inline public function rowOf(type:Int, index:Int):Int {
		return rowFor[keyOf(type, index)];
	}

	/** Marks a (type,index) pair as needing a row; processed before render. */
	public function scheduleRow(type:Int, index:Int):Void {
		var key = keyOf(type, index);
		if (rowFor[key] != -1) return;
		if (pendingKeys.indexOf(key) == -1)
			pendingKeys.push(key);
	}

	/** Allocates rows for all scheduled pairs. Returns true if anything changed. */
	public function ensureRows():Bool {
		if (pendingKeys.length == 0) return false;
		var changed = false;
		for (key in pendingKeys) {
			if (rowFor[key] != -1) continue;
			if (rowCount >= MAX_ROWS) break;
			rowFor[key] = rowCount;
			rowKeys[rowCount] = key;
			rowCount++;
			changed = true;
		}
		pendingKeys.resize(0);
		return changed;
	}

	// ------------------------------------------------------------------
	// Baking
	// ------------------------------------------------------------------

	/**
		Returns true when the bake inputs differ from the last bake, i.e.
		the table contents are stale.
	**/
	public function needsRebake(interpAvailable:Bool, formulaVersion:Int, speed:Float, downScroll:Bool, strumlines:Array<Strumline>):Bool {
		if (bakeFormulaVersion != formulaVersion) return true;
		if (bakeSpeed != speed) return true;
		if (bakeDownScroll != downScroll) return true;
		if (strumlines == null || strumlines.length != bakeStrumX.length) return true;
		for (i in 0...strumlines.length) {
			var s = strumlines[i];
			if (bakeStrumX[i] != s.x || bakeStrumY[i] != s.y || bakeStrumDir[i] != s.scrollDirection) return true;
			if (bakeStrumScale[i] != s.scale) return true;
		}
		return false;
	}

	/** Records the current inputs as the baked state (call after rebake). */
	public function commitBake(interpAvailable:Bool, formulaVersion:Int, speed:Float, downScroll:Bool, strumlines:Array<Strumline>):Void {
		bakeFormulaVersion = formulaVersion;
		bakeSpeed = speed;
		bakeDownScroll = downScroll;
		bakeStrumX = [for (s in strumlines) s.x];
		bakeStrumY = [for (s in strumlines) s.y];
		bakeStrumDir = [for (s in strumlines) s.scrollDirection];
		bakeStrumScale = [for (s in strumlines) s.scale];
	}

	/**
		Rebakes every allocated row against the current formula / strumlines
		and re-uploads the GPU texture.
	**/
	public function rebake(interp:Null<NoteMovementInterp>, scrollSpeed:Float, downScroll:Bool, strumlines:Array<Strumline>):Void {
		if (strumlines == null) return;
		var base = new NoteFormulaResult();
		var strumCount = strumlines.length;

		// Precompute lane constants for the scroll direction cos/sin.
		var cosDir:Array<Float> = [for (s in strumlines) Math.cos(s.scrollDirection * 0.01745329)];
		var sinDir:Array<Float> = [for (s in strumlines) Math.sin(s.scrollDirection * 0.01745329)];

		var i = 0;
		while (i < rowCount) {
			var key = rowKeys[i];
			var type = Std.int(key / MAX_INDEX);
			var index = key - type * MAX_INDEX;
			var lane = type % strumCount;
			var strumline = strumlines[lane];
			if (strumline == null) { i++; continue; }
			if (index >= strumline.receptors.length) { i++; continue; }
			var rec = strumline.receptors[index];
			var recX = rec.note.x;
			var recY = rec.note.y;
			var recScale = rec.note.scale;
			var dir = strumline.scrollDirection;
			var baseRot = dir;
			if (downScroll) baseRot += 180;

			var rowOff = i * WIDTH * ROW_STRIDE;
			var px = 0;
			while (px < WIDTH) {
				var dPx = AXIS_MIN + px;
				var d = Math.round(dPx);
				if (downScroll) d = -d;

				var x = 0.0;
				var y = 0.0;
				var scale = 1.0;
				var rot = 0.0;
				var mult = 1.0;

				if (interp != null) {
					var res = interp.run(d, scrollSpeed, recX, recY, index, type, base);
					if (res != null) {
						x = Math.round(res.x);
						y = Math.round(res.y);
						scale = res.scale * recScale;
						rot = res.sustainRot;
						mult = res.scrollMultiplier;
					} else {
						// ABORT: fall back to the linear scroll, matching
						// the CPU behaviour when the formula returns nil.
						x = Math.round(recX + d * cosDir[lane]);
						y = Math.round(recY + d * sinDir[lane]);
						scale = recScale;
						rot = baseRot;
					}
				} else {
					x = Math.round(recX + d * cosDir[lane]);
					y = Math.round(recY + d * sinDir[lane]);
					scale = recScale;
					rot = baseRot;
				}

				var o = rowOff + px * ROW_STRIDE;
				data[o] = x;
				data[o + 1] = y;
				data[o + 2] = scale;
				data[o + 3] = rot;
				data[o + 4] = mult;
				px++;
			}
			i++;
		}

		uploadTexture();
	}

	/** Builds the RGBA texture bytes from `data` (dropping the 5th channel). */
	function uploadTexture():Void {
		if (textureData == null || lutDataBytes == null) return;
		var texOff = 0;
		var texels = rowCount * WIDTH;
		var src = 0;
		while (texOff < texels) {
			var rowSrc = src * ROW_STRIDE;
			lutDataBytes.setFloat(texOff * 16 + 0, data[rowSrc]);
			lutDataBytes.setFloat(texOff * 16 + 4, data[rowSrc + 1]);
			lutDataBytes.setFloat(texOff * 16 + 8, data[rowSrc + 2]);
			lutDataBytes.setFloat(texOff * 16 + 12, data[rowSrc + 3]);
			texOff++;
			src++;
		}
		if (texture != null)
			texture.setData(textureData, 0);
	}

	// ------------------------------------------------------------------
	// CPU lookups (used for scale compares, sustain `w`, and fallback)
	// ------------------------------------------------------------------

	inline public function bucketOf(dPx:Float):Int {
		var b = Std.int(Math.round(dPx - AXIS_MIN));
		if (b < 0) b = 0;
		if (b >= WIDTH) b = WIDTH - 1;
		return b;
	}

	inline function offset(row:Int, bucket:Int, channel:Int):Int {
		return (row * WIDTH + bucket) * ROW_STRIDE + channel;
	}

	/** x (already rounded, absolute screen px) at a scroll offset. */
	inline public function xAt(row:Int, dPx:Float):Float {
		if (row < 0) return 0.0;
		return data[offset(row, bucketOf(dPx), 0)];
	}

	inline public function yAt(row:Int, dPx:Float):Float {
		if (row < 0) return 0.0;
		return data[offset(row, bucketOf(dPx), 1)];
	}

	inline public function scaleAt(row:Int, dPx:Float):Float {
		if (row < 0) return 1.0;
		return data[offset(row, bucketOf(dPx), 2)];
	}

	inline public function rotAt(row:Int, dPx:Float):Float {
		if (row < 0) return 0.0;
		return data[offset(row, bucketOf(dPx), 3)];
	}

	inline public function multAt(row:Int, dPx:Float):Float {
		if (row < 0) return 1.0;
		return data[offset(row, bucketOf(dPx), 4)];
	}

	// ------------------------------------------------------------------
	// GPU texture
	// ------------------------------------------------------------------

	/**
		Creates the LUT texture (RGBA float when supported) and attaches it
		to both programs as the FIRST custom texture layer so it becomes
		`uTexture0`. Must be called before the programs are added to the
		display (so the first shader compile includes it).
	**/
	public function attach(notesProg:peote.view.Program, sustainProg:peote.view.Program):Void {
		if (attached) return;
		attached = true;

		gpuEnabled = PeoteGL.Version.isES3;

		// Row region for the texture. Only `rowCount` rows are used, but the
		// texture is allocated at full height so rows can be added lazily
		// without rebuilding the texture object.
		var format = gpuEnabled ? TextureFormat.FLOAT_RGBA : TextureFormat.RGBA;
		texture = new Texture(WIDTH, MAX_ROWS, 1, {format: format, smoothExpand: false, smoothShrink: false, mipmap: false});
		textureData = new TextureData(WIDTH, MAX_ROWS, format);
		lutDataBytes = textureData.bytes;
		texture.setData(textureData, 0);

		notesProg.addTexture(texture, "lutLayer");
		sustainProg.addTexture(texture, "lutLayer");
	}

	public function dispose():Void {
		texture = null;
		textureData = null;
		lutDataBytes = null;
		data = null;
		rowFor = null;
		rowKeys = null;
	}
}
