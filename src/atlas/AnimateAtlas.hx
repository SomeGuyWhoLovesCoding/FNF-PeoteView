// AnimateAtlas.hx
package atlas;

import haxe.Json;

/**
 * Resolved leaf: one concrete atlas sprite with its fully accumulated
 * world-space 2-D affine transform (parent chain multiplied in).
 */
typedef ResolvedLeaf = {
	var sprite:AnimateSprite;
	var symbolName:String;        // the immediate SI parent that owns this leaf
	var a:Float;                  // 2×2 rotation/scale matrix
	var b:Float;
	var c:Float;
	var d:Float;
	var tx:Float;                 // translation
	var ty:Float;
	var color:Null<AnimateColor>; // nearest ancestor tint, null if none
	var alpha:Float;              // accumulated opacity (multiplicative down hierarchy)
	var brightness:Float;         // additive brightness offset (CBRT, 0.0 = no change)
}

/**
 * One display frame = all visible leaves, back-to-front (layer order preserved).
 */
typedef ResolvedFrame = Array<ResolvedLeaf>;

/**
 * Handles Adobe Animate atlas format (spritemap1.json + Animation.json).
 * After construction, use getResolvedFrames() to get pre-baked per-frame
 * sprite lists with accumulated transforms ready for rendering.
 */
@:publicFields
class AnimateAtlas {
	// Raw parsed data
	var sprites:Map<String, AnimateSprite> = [];
	var animations:Map<String, AnimateAnimation> = [];
	var meta:AnimateMeta;

	// Pre-resolved: symbol name -> array of ResolvedFrame (one per display frame)
	var resolvedAnimations:Map<String, Array<ResolvedFrame>> = [];

	var imagePath:String;

	public function new(spritemapJson:String, animationJson:String, imagePath:String) {
		this.imagePath = imagePath;
		parseSpritemap(spritemapJson);
		parseAnimation(animationJson);
		resolveAllAnimations();
	}

	// -------------------------------------------------------------------------
	// Parsing
	// -------------------------------------------------------------------------

	function parseSpritemap(content:String) {
		var json = Json.parse(content);

		if (json.ATLAS != null && json.ATLAS.SPRITES != null) {
			var list:Array<Dynamic> = json.ATLAS.SPRITES;
			for (item in list) {
				if (item.SPRITE == null) continue;
				var s = item.SPRITE;
				var name:String = s.name;
				sprites.set(name, {
					name:        name,
					x:           s.x,
					y:           s.y,
					width:       s.w,
					height:      s.h,
					rotated:     s.rotated == true,
					frameX:      0,
					frameY:      0,
					frameWidth:  s.w,
					frameHeight: s.h
				});
			}
		}

		if (json.meta != null) {
			meta = {
				app:        json.meta.app,
				version:    json.meta.version,
				image:      json.meta.image,
				format:     json.meta.format,
				width:      json.meta.size != null ? json.meta.size.w : 0,
				height:     json.meta.size != null ? json.meta.size.h : 0,
				resolution: json.meta.resolution != null ? Std.parseFloat(json.meta.resolution) : 1.0
			};
		}
	}

	function parseAnimation(content:String) {
		var json = Json.parse(content);

		// Root timeline stored as "root"
		if (json.AN != null && json.AN.TL != null && json.AN.TL.L != null)
			parseTimeline(json.AN.TL.L, "root");

		// Symbol definitions
		if (json.SD != null && json.SD.S != null) {
			var symbols:Array<Dynamic> = json.SD.S;
			for (symbol in symbols) {
				if (symbol.SN != null && symbol.TL != null && symbol.TL.L != null)
					parseTimeline(symbol.TL.L, symbol.SN);
			}
		}
	}

	function parseTimeline(layers:Array<Dynamic>, animName:String) {
		// First pass: find total display-frame count respecting DU (duration)
		var totalFrames = 0;
		for (layer in layers) {
			if (layer.FR == null) continue;
			for (fr in (layer.FR : Array<Dynamic>)) {
				var end:Int = (fr.I != null ? fr.I : 0) + (fr.DU != null ? fr.DU : 1);
				if (end > totalFrames) totalFrames = end;
			}
		}
		if (totalFrames == 0) return;

		// Build a display-frame array
		var displayFrames:Array<Array<AnimateFrameElement>> = [for (_ in 0...totalFrames) []];

		// Process layers in REVERSE order to get back-to-front rendering
		for (i in 0...layers.length) {
			var layer = layers[layers.length - 1 - i]; // Start from bottom-most layer

			if (layer.FR == null) continue;
			var frameList:Array<Dynamic> = layer.FR;

			for (keyframe in frameList) {
				var startI:Int = keyframe.I != null ? keyframe.I : 0;
				var du:Int     = keyframe.DU != null ? keyframe.DU : 1;
				var elems:Array<AnimateFrameElement> = [];
				var kfBrightness:Float = (keyframe.C != null && keyframe.C.M == "CBRT" && keyframe.C.BRT != null)
					? (keyframe.C.BRT : Float) : 0.0;
				if (keyframe.E != null) parseElements(keyframe.E, elems, kfBrightness);

				// Stamp this keyframe's elements into every display frame it covers
				for (di in startI...startI + du) {
					if (di >= totalFrames) break;

					for (e in elems) {
						displayFrames[di].push(e);
					}
				}
			}
		}

		var frames:Array<AnimateFrame> = [];
		for (di in 0...totalFrames) {
			frames.push({ index: di, duration: 1, elements: displayFrames[di] });
		}

		animations.set(animName, { name: animName, frames: frames });
	}

	function parseElements(elementsData:Dynamic, target:Array<AnimateFrameElement>, brightness:Float = 0.0) {
		if (elementsData == null) return;
		var list:Array<Dynamic> = Std.isOfType(elementsData, Array) ? elementsData : [elementsData];

		for (e in list) {
			if (e.SI != null) {
				var si = e.SI;
				var mat = si.M3D != null ? parseMatrix(si.M3D) : identityMatrix();
				target.push({
					instanceName: si.IN,
					symbolName:   si.SN,
					type:         si.ST != null ? si.ST : "SI",
					firstFrame:   si.FF != null ? si.FF : 0,
					loop:         si.LP,
					matrix:       mat,
					transform:    si.TRP != null ? { x: si.TRP.x != null ? (si.TRP.x : Float) : 0.0,
													 y: si.TRP.y != null ? (si.TRP.y : Float) : 0.0 } : null,
					color:        si.C != null ? parseColor(si.C) : null,
					alpha:        si.A != null ? (si.A : Float) : 1.0,
					brightness:   brightness
				});
			} else if (e.ASI != null) {
				var asi = e.ASI;
				var mat = asi.M3D != null ? parseMatrix(asi.M3D) : identityMatrix();
				target.push({
					instanceName: null,
					symbolName:   asi.N,
					type:         "ASI",
					firstFrame:   0,
					loop:         null,
					matrix:       mat,
					transform:    null,
					color:        null,
					alpha:        1.0,
					brightness:   brightness
				});
			}
		}
	}

	/**
	 * Parses a Flash color transform object.
	 * Mode "T" (tint): lerp from original pixel toward TC by TM.
	 *   TC is a CSS hex string like "#0000FF", TM is 0.0–1.0.
	 */
	function parseColor(c:Dynamic):Null<AnimateColor> {
		if (c == null || c.M == null) return null;
		var mode:String = c.M;

		if (mode == "T" && c.TC != null) {
			var hex:String = (c.TC : String);
			if (hex.charAt(0) == "#") hex = hex.substr(1);
			var rgb:Int = Std.parseInt("0x" + hex);
			return {
				mode:   "T",
				r:      ((rgb >> 16) & 0xFF) / 255.0,
				g:      ((rgb >> 8)  & 0xFF) / 255.0,
				b:      ( rgb        & 0xFF) / 255.0,
				amount: c.TM != null ? (c.TM : Float) : 1.0,
				rm: 1.0,
				gm: 1.0,
				bm: 1.0,
				am: 1.0,
				ro: 0.0,
				go: 0.0,
				bo: 0.0,
				ao: 0.0
			};
		}

		if (mode == "AD") {
			return {
				mode:   "AD",
				r: 0.0, g: 0.0, b: 0.0, amount: 0.0, // unused in AD mode
				rm: c.RM != null ? (c.RM : Float) : 1.0,
				gm: c.GM != null ? (c.GM : Float) : 1.0,
				bm: c.BM != null ? (c.BM : Float) : 1.0,
				am: c.AM != null ? (c.AM : Float) : 1.0,
				ro: c.RO != null ? (c.RO : Float) / 255.0 : 0.0,
				go: c.GO != null ? (c.GO : Float) / 255.0 : 0.0,
				bo: c.BO != null ? (c.BO : Float) / 255.0 : 0.0,
				ao: c.AO != null ? (c.AO : Float) / 255.0 : 0.0
			};
		}

		return null;
	}

	/**
	 * Adobe Animate exports a column-major 4×4 matrix.
	 * 2-D affine components:
	 *   a  = m[0]   b  = m[1]
	 *   c  = m[4]   d  = m[5]
	 *   tx = m[12]  ty = m[13]
	 */
	function parseMatrix(m:Array<Dynamic>):AnimateMatrix {
		if (m == null || m.length < 16) return identityMatrix();
		return { a: m[0], b: m[1], c: m[4], d: m[5], tx: m[12], ty: m[13] };
	}

	inline function identityMatrix():AnimateMatrix {
		return { a: 1.0, b: 0.0, c: 0.0, d: 1.0, tx: 0.0, ty: 0.0 };
	}

	// -------------------------------------------------------------------------
	// Resolution pass — runs once after all parsing is done
	// -------------------------------------------------------------------------

	function resolveAllAnimations() {
		for (animName in animations.keys()) {
			var resolved = buildResolvedFrames(animName);
			if (resolved != null) resolvedAnimations.set(animName, resolved);
		}
	}

	/**
	 * Build the full ResolvedFrame array for a top-level symbol.
	 * Each display frame = all visible leaf sprites with accumulated world transforms.
	 */
	function buildResolvedFrames(symbolName:String):Array<ResolvedFrame> {
		var anim = animations.get(symbolName);
		if (anim == null) return null;

		var result:Array<ResolvedFrame> = [];
		for (frame in anim.frames) {
			var leaves:ResolvedFrame = [];
			for (elem in frame.elements) {
				collectLeaves(elem, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, leaves, [symbolName], symbolName, null, 1.0, 0.0);
			}
			result.push(leaves);
		}
		return result;
	}

	/**
	 * Recursively walks the element tree, accumulating the affine transform,
	 * and appends ResolvedLeaf entries for every ASI (atlas sprite) encountered.
	 *
	 * Matrix multiply (column-vector convention, same as Flash/Animate):
	 *   | a  c |   | ea ec |   | a*ea+c*eb   a*ec+c*ed |
	 *   | b  d | × | eb ed | = | b*ea+d*eb   b*ec+d*ed |
	 *
	 *   tx_out = a*etx + c*ety + tx
	 *   ty_out = b*etx + d*ety + ty
	 *
	 * `a,b,c,d,tx,ty`  = parent's accumulated transform.
	 * `visiting`        = cycle guard (symbol names currently on the call stack).
	 * `parentSymbol`    = the nearest SI ancestor's name, stamped onto each leaf.
	 * `inheritedColor`  = nearest ancestor color transform; overridden by this
	 *                     element's own color if present.
	 * `inheritedAlpha`  = accumulated opacity so far; multiplied by this element's
	 *                     own alpha so fades compound correctly down the hierarchy.
	 */
	function collectLeaves(
		elem:AnimateFrameElement,
		a:Float, b:Float, c:Float, d:Float, tx:Float, ty:Float,
		out:ResolvedFrame,
		visiting:Array<String>,
		parentSymbol:String,
		inheritedColor:Null<AnimateColor>,
		inheritedAlpha:Float,
		inheritedBrightness:Float
	) {
		var em = elem.matrix;

		// Multiply parent transform × this element's local matrix
		var na  = a  * em.a + c  * em.b;
		var nb  = b  * em.a + d  * em.b;
		var nc  = a  * em.c + c  * em.d;
		var nd  = b  * em.c + d  * em.d;
		var ntx = a  * em.tx + c  * em.ty + tx;
		var nty = b  * em.tx + d  * em.ty + ty;

		// Color: this element's own overrides the inherited one
		var activeColor:Null<AnimateColor> = elem.color != null ? elem.color : inheritedColor;

		// Alpha: compound multiplicatively so nested fades stack correctly
		var activeAlpha:Float = inheritedAlpha * elem.alpha;

		// Brightness: additive, so nested adjustments stack
		var activeBrightness:Float = inheritedBrightness + elem.brightness;

		if (elem.type == "ASI") {
			// Leaf: look up the actual atlas sprite, stamp nearest SI parent, color, alpha, and brightness
			var sprite = sprites.get(elem.symbolName);
			if (sprite != null) {
				out.push({
					sprite:     sprite,
					symbolName: parentSymbol,
					a: na, b: nb, c: nc, d: nd,
					tx: ntx, ty: nty,
					color:      activeColor,
					alpha:      activeAlpha,
					brightness: activeBrightness
				});
			}
		} else {
			// SI: recurse into the referenced symbol, passing this SI's name
			// down as the new parentSymbol so all its leaves are tagged with it
			var childName = elem.symbolName;
			if (visiting.indexOf(childName) >= 0) return; // cycle guard

			var childAnim = animations.get(childName);
			if (childAnim == null) return;

			// Which display frame of the child to show?
			var ff = elem.firstFrame;
			var childFrame:AnimateFrame = null;
			for (f in childAnim.frames) {
				if (f.index == ff) { childFrame = f; break; }
			}
			// Fallback: clamp to last frame
			if (childFrame == null && childAnim.frames.length > 0)
				childFrame = childAnim.frames[childAnim.frames.length - 1];
			if (childFrame == null) return;

			var nextVisiting = visiting.concat([childName]);
			for (childElem in childFrame.elements) {
				collectLeaves(childElem, na, nb, nc, nd, ntx, nty, out, nextVisiting, childName, activeColor, activeAlpha, activeBrightness);
			}
		}
	}

	// -------------------------------------------------------------------------
	// Public API
	// -------------------------------------------------------------------------

	public function getSprite(name:String):Null<AnimateSprite> {
		return sprites.get(name);
	}

	public function getAnimation(name:String):Null<AnimateAnimation> {
		return animations.get(name);
	}

	/**
	 * Returns the pre-resolved frames for a symbol.
	 * Each entry is an array of ResolvedLeaf (one per visible sprite, back-to-front).
	 */
	public function getResolvedFrames(symbolName:String):Null<Array<ResolvedFrame>> {
		return resolvedAnimations.get(symbolName);
	}

	/**
	 * Returns a subset of resolved frames selected by `indices`
	 * (mirrors the charData "indices" field for Sparrow-style frame selection).
	 */
	public function getResolvedFramesSubset(symbolName:String, indices:Array<Int>):Array<ResolvedFrame> {
		var all = resolvedAnimations.get(symbolName);
		if (all == null) return [];
		if (indices == null || indices.length == 0) return all;
		var result:Array<ResolvedFrame> = [];
		for (idx in indices) {
			if (idx >= 0 && idx < all.length) result.push(all[idx]);
		}
		return result;
	}
}

// -------------------------------------------------------------------------
// Data structures
// -------------------------------------------------------------------------

typedef AnimateSprite = {
	public var name:String;
	public var x:Int;
	public var y:Int;
	public var width:Int;
	public var height:Int;
	public var rotated:Bool;
	public var frameX:Int;
	public var frameY:Int;
	public var frameWidth:Int;
	public var frameHeight:Int;
}

typedef AnimateAnimation = {
	public var name:String;
	public var frames:Array<AnimateFrame>;
}

typedef AnimateFrame = {
	public var index:Int;
	public var duration:Int;
	public var elements:Array<AnimateFrameElement>;
}

typedef AnimateFrameElement = {
	public var instanceName:String;
	public var symbolName:String;
	public var type:String;
	public var firstFrame:Int;
	public var loop:String;
	public var matrix:AnimateMatrix;
	public var transform:AnimateTransform;
	public var color:Null<AnimateColor>;
	public var alpha:Float;
	public var brightness:Float; // additive offset from keyframe "C": { "M": "CBRT", "BRT": n }
}

/**
 * Parsed color transform from an SI element's "C" field.
 * mode "T": lerp each channel from original toward (r,g,b) by `amount`.
 *   result = mix(original.rgb, vec3(r,g,b), amount)   (alpha unchanged)
 */
typedef AnimateColor = {
	public var mode:String;   // currently always "T"
	public var r:Float;
	public var g:Float;
	public var b:Float;
	public var amount:Float;  // 0.0–1.0 (TM field)

    // Advanced fields (mode "AD")
    public var rm:Float;
	public var gm:Float;
	public var bm:Float;
	public var am:Float;
    public var ro:Float;
	public var go:Float;
	public var bo:Float;
	public var ao:Float;
}

typedef AnimateMatrix = {
	public var a:Float;
	public var b:Float;
	public var c:Float;
	public var d:Float;
	public var tx:Float;
	public var ty:Float;
}

typedef AnimateTransform = {
	public var x:Float;
	public var y:Float;
}

typedef AnimateMeta = {
	public var app:String;
	public var version:String;
	public var image:String;
	public var format:String;
	public var width:Int;
	public var height:Int;
	public var resolution:Float;
}
