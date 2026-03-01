package elements.actor;

import atlas.AnimateAtlas;
import atlas.AnimateAtlas.AnimateSprite;
import atlas.AnimateAtlas.AnimateColor;
import atlas.AnimateAtlas.ResolvedLeaf;
import atlas.AnimateAtlas.ResolvedFrame;
import elements.actor.*;

/**
	Actor backed by an Adobe Animate spritemap atlas.

	Maintains a dynamic pool of ActorElements — one per visible leaf sprite —
	so every part of a composite character carries its own accumulated
	world transform.  The fragment shader uses per-leaf matrix varyings to
	apply skew and non-uniform scale within each axis-aligned quad.

	Filter types applied via _filterType:
	  0.0 = none
	  1.0 = multiply tint  (manual setTint: col.rgb *= filterRGB, col.a *= filterA)
	  2.0 = lerp tint       (atlas "C" field: col.rgb = mix(col.rgb, filterRGB, filterA))

	Alpha from the atlas "A" field is baked into the element's color attribute (el.c)
	and compounds multiplicatively down the symbol hierarchy.

	Fully transparent fragments are discarded before blending to prevent
	visible AABB padding overlap between adjacent leaf quads.

	@since Development
**/
@:publicFields
class AnimateActor extends Actor
{
	var animateAtlas(default, null):AnimateAtlas;

	// ── Animate leaf pool ────────────────────────────────────────────────────

	/** Live pool of leaf ActorElements. Grows as needed, never shrinks. */
	var leafPool:Array<ActorElement> = [];
	/** How many leaves are active in the current frame. */
	var activeLeafCount:Int = 0;

	/** The resolved frames for the currently playing animation. */
	var currentResolvedFrames:Array<atlas.AnimateAtlas.ResolvedFrame> = [];

	// ── Construction ─────────────────────────────────────────────────────────

	function new(display:CustomDisplay, tag:Null<String>, name:String,
				 x:Int = 0, y:Int = 0, fps:Int = 24,
				 folder:String = "images/characters/",
				 addBufferAndProgram:Bool = true)
	{
		super(display, tag, name, x, y, fps, folder, addBufferAndProgram);

		atlasType = ANIMATE;

		// ── Atlas loading ──────────────────────────────────────────────────

		var atlasKey = '$name/$folder';

		if (Actor.cachedAtlases[atlasKey] == null) {
			var spritemapPath = Actor.path(name, folder, SPRITEMAP);
			var animationPath = Actor.path(name, folder, ANIMATION);

			if (!Actor.pathExists(name, folder, SPRITEMAP) || !Actor.pathExists(name, folder, ANIMATION))
				throw "Animate atlas data doesn't exist for: " + name;

			var dataPath         = StringTools.replace(spritemapPath, "spritemap1.png", "spritemap1.json");
			var spritemapContent = sys.io.File.getContent(dataPath);
			var animationContent = sys.io.File.getContent(animationPath);

			animateAtlas = new AnimateAtlas(spritemapContent, animationContent, spritemapPath);
			Actor.cachedAtlases[atlasKey] = animateAtlas;
		} else {
			animateAtlas = Actor.cachedAtlases[atlasKey];
		}

		// ── Character data ─────────────────────────────────────────────────

		if (Actor.cachedActorDatas[atlasKey] == null && Actor.pathExists(name, folder, DATA)) {
			Actor.cachedActorDatas[atlasKey] = data = ActorData.parse(Actor.path(name, folder, DATA));
		} else if (Actor.cachedActorDatas[atlasKey] != null) {
			data = Actor.cachedActorDatas[atlasKey];
		}

		// ── Buffer & program ───────────────────────────────────────────────

		if (animateAtlas.imagePath != "" && addBufferAndProgram) {
			if (tag == null) throw "Tag cannot be null when addBufferAndProgram is true";

			if (Actor.buffers[tag] == null) Actor.buffers[tag] = new Buffer<ActorElement>(4, 4, true);
			buffer = Actor.buffers[tag];

			if (Actor.programs[tag] == null) {

				Actor.programs[tag] = new CustomProgram(buffer);
				program = Actor.programs[tag];
				program.blendEnabled = true;
				program.blendSrc     = program.blendSrcAlpha = BlendFactor.ONE;
				program.blendDst     = program.blendDstAlpha = BlendFactor.ONE_MINUS_SRC_ALPHA;

				var texName = name + "Char";
				var texPath = animateAtlas.imagePath;
				TextureSystem.createTexture(texName, texPath, false, true);
				TextureSystem.setTexture(program, texName, texName);

				// ── Fragment shader ────────────────────────────────────────
				//
				// Transparent fragments are discarded entirely so AABB padding
				// between leaf quads never contributes to blending.
				//
				// _filterType == 0.0  no filter
				// _filterType == 1.0  multiply tint  (manual setTint)
				//                       col.rgb *= _filterR/G/B
				//                       col.a   *= _filterA
				// _filterType == 2.0  lerp tint  (baked from atlas "C" field)
				//                       col.rgb  = mix(col.rgb, _filterR/G/B, _filterA)
				//                       alpha unchanged
				// _filterType == 3.0  advanced color transform  (atlas "AD" mode)
				//                       col = clamp(col * multipliers + offsets, 0, 1)
				//
				// _filterBrightness   additive brightness offset applied after all
				//                     other filters (atlas "CBRT" keyframe field)
				//
				// Atlas "A" alpha is baked into el.c and applied by the pipeline
				// automatically — no extra shader branch needed.
				program.injectIntoFragmentShader('
					vec4 getColor(int texId, float _ma, float _mb, float _mc, float _md,
								  float _rotated, float _originU, float _originV,
								  float _filterType, float _filterR, float _filterG, float _filterB, float _filterA,
								  float _adRM, float _adGM, float _adBM, float _adAM,
								  float _adRO, float _adGO, float _adBO, float _adAO,
								  float _filterBrightness)
					{
						vec2 uv = vTexCoord;
						float su = _ma * uv.x + _mc * uv.y + _originU;
						float sv = _mb * uv.x + _md * uv.y + _originV;

						if (_rotated == 1.0) { float tmp = su; su = 1.0 - sv; sv = tmp; }
						if (su < 0.0 || su > 1.0 || sv < 0.0 || sv > 1.0) return vec4(0.0);

						vec4 col = getTextureColor(texId, vec2(su, sv));

						if (col.a < 0.004) discard;

						if (_filterType > 0.5 && _filterType < 1.5) {
							col = vec4(col.rgb * vec3(_filterR, _filterG, _filterB), col.a * _filterA);
						} else if (_filterType > 1.5 && _filterType < 2.5) {
							col = vec4(mix(col.rgb, vec3(_filterR, _filterG, _filterB), _filterA), col.a);
						} else if (_filterType > 2.5) {
							col = clamp(vec4(
								col.r * _adRM + _adRO,
								col.g * _adGM + _adGO,
								col.b * _adBM + _adBO,
								col.a * _adAM + _adAO
							), 0.0, 1.0);
						}

						if (_filterBrightness != 0.0)
							col = vec4(clamp(col.rgb + _filterBrightness, 0.0, 1.0), col.a);

						return col;
					}
				');

				program.setColorFormula(
					'getColor(${texName}_ID, _ma, _mb, _mc, _md, _rotated, _originU, _originV, _filterType, _filterR, _filterG, _filterB, _filterA, _adRM, _adGM, _adBM, _adAM, _adRO, _adGO, _adBO, _adAO, _filterBrightness)'
				);
			} else {
				program = Actor.programs[tag];
			}

			display.addProgram(program);
		}

		mirror = !data.flip;
		scale  = data.scale;
	}

	// ── Leaf pool management ─────────────────────────────────────────────────

	function ensureLeafPool(count:Int) {
		while (leafPool.length < count) {
			var el    = new ActorElement(this.x, this.y);
			el.scale  = this.scale;
			if (buffer != null) buffer.addElement(el);
			leafPool.push(el);
		}
	}

	function hideExcessLeaves(count:Int) {
		for (i in count...activeLeafCount) {
			leafPool[i].w = 0;
			leafPool[i].h = 0;
			if (buffer != null) buffer.updateElement(leafPool[i]);
		}
		activeLeafCount = count;
	}

	// ── Atlas range resolution ────────────────────────────────────────────────

	override private function resolveAnimationRange(symbolName:String, _sparrowRange:Array<Int>) {
		var frames = indicesMode
			? animateAtlas.getResolvedFramesSubset(symbolName, indices)
			: animateAtlas.getResolvedFrames(symbolName);

		if (frames == null || frames.length == 0) return;
		currentResolvedFrames = frames;
		startingFrameIndex    = 0;
		endingFrameIndex      = frames.length;
	}

	// ── Frame rendering ───────────────────────────────────────────────────────

	override function changeFrame() {
		if (currentResolvedFrames == null || frameIndex >= currentResolvedFrames.length) return;
		applyResolvedFrame(currentResolvedFrames[frameIndex]);
	}

	override private function renderImpl() {
		for (i in 0...activeLeafCount) {
			if (buffer != null) buffer.updateElement(leafPool[i]);
		}
	}

	// ── Composite frame application ───────────────────────────────────────────

	/**
	 * Distribute a resolved frame's leaves across the leaf pool.
	 * Each leaf gets its own ActorElement configured with the sprite's clip
	 * rect and the decomposed world-space transform.
	 */
	function applyResolvedFrame(resolvedFrame:ResolvedFrame) {
		var count = resolvedFrame.length;
		ensureLeafPool(count);
		hideExcessLeaves(count);
		activeLeafCount = count;

		for (i in 0...count) {
			applyLeafTransform(leafPool[i], resolvedFrame[i], i);
		}
	}

	/**
	 * Configure clip rect, size, and full world transform for one leaf element.
	 *
	 * COORDINATE SPACE
	 * ────────────────
	 * In Adobe Animate a symbol instance matrix rotates the symbol content
	 * around its own registration point (0,0 = top-left for leaf sprites),
	 * then translates that origin to (tx, ty) in parent space.
	 *
	 * ActorElement rotates around its CENTER (px = w/2, py = h/2).
	 * To reconcile: compute where the CENTER of the rotated sprite lands
	 * and feed that to adjust_x/y:
	 *
	 *   center_world = ( tx + vw/2·cos(A) − vh/2·sin(A),
	 *                    ty + vw/2·sin(A) + vh/2·cos(A) )
	 *
	 *   adjust_x = center_world_x − vw/2   (vw/2 cancels with px in the formula)
	 *   adjust_y = center_world_y − vh/2
	 *
	 * MATRIX / UV DISTORTION
	 * ──────────────────────
	 * The quad is sized to the AABB of the transformed sprite corners (w/h).
	 * The fragment shader receives the raw a/b/c/d matrix components and
	 * applies the inverse transform to UV coordinates so skew and non-uniform
	 * scale are rendered correctly within the axis-aligned quad.
	 * clipWidth/clipHeight always hold raw atlas pixel dimensions so UV
	 * sampling is never broken by the visual transform.
	 *
	 * COLOR & ALPHA
	 * ─────────────
	 * Baked tint (atlas "C" field, mode "T") is applied as _filterType = 2.0.
	 * Manual setTint() overrides this with _filterType = 1.0 (multiply).
	 * clearTint() restores the baked value if one exists, or clears to 0.0.
	 *
	 * Baked alpha (atlas "A" field, compounded down the hierarchy) is written
	 * into el.c so the blend pipeline applies it for free without an extra
	 * shader branch.
	 */
	function applyLeafTransform(el:ActorElement, leaf:ResolvedLeaf, leafIndex:Int) {
		var sprite = leaf.sprite;
		var s      = this.scale;

		var a  = this.mirror ? -leaf.a  : leaf.a;
		var b  = leaf.b;
		var c  = this.mirror ? -leaf.c  : leaf.c;
		var d  = leaf.d;
		var tx = this.mirror ? -leaf.tx : leaf.tx;
		var ty = leaf.ty;

		el.mirror  = false;
		el.flipX   = false;
		el.flipY   = false;
		el._mirror = 0.0;

		var aw:Float = sprite.rotated ? sprite.height : sprite.width;
		var ah:Float = sprite.rotated ? sprite.width  : sprite.height;

		// ── AABB of the four transformed corners ───────────────────────────

		var minX =  Math.POSITIVE_INFINITY;
		var minY =  Math.POSITIVE_INFINITY;
		var maxX =  Math.NEGATIVE_INFINITY;
		var maxY =  Math.NEGATIVE_INFINITY;

		for (corner in [{x:0.0,y:0.0},{x:aw,y:0.0},{x:aw,y:ah},{x:0.0,y:ah}]) {
			var wx = (a * corner.x + c * corner.y + tx) * s;
			var wy = (b * corner.x + d * corner.y + ty) * s;
			if (wx < minX) minX = wx;
			if (wx > maxX) maxX = wx;
			if (wy < minY) minY = wy;
			if (wy > maxY) maxY = wy;
		}

		var vws     = maxX - minX;
		var vhs     = maxY - minY;
		var centerX = (minX + maxX) * 0.5;
		var centerY = (minY + maxY) * 0.5;

		el.w = vws;
		el.h = vhs;
		el.r = 0;

		el.adjust_x = this.adjust_x * s + centerX - vws * 0.5;
		el.adjust_y = this.adjust_y * s + centerY - vhs * 0.5;

		el.clipX      = sprite.x;
		el.clipY      = sprite.y;
		el.rotated    = sprite.rotated;
		el.clipWidth  = sprite.width;
		el.clipHeight = sprite.height;

		// ── Inverse matrix for UV distortion ──────────────────────────────

		var det = a * d - b * c;
		if (Math.abs(det) < 1e-8) {
			el._ma = 1.0; el._mb = 0.0; el._mc = 0.0; el._md = 1.0;
			el._originU = 0.0; el._originV = 0.0;
		} else {
			var invA =  d / det;
			var invB = -b / det;
			var invC = -c / det;
			var invD =  a / det;

			var vwsU = vws / s;
			var vhsU = vhs / s;

			el._ma = invA * vwsU / aw;
			el._mb = invB * vwsU / ah;
			el._mc = invC * vhsU / aw;
			el._md = invD * vhsU / ah;

			var originLocalX = invA * (minX / s - tx) + invC * (minY / s - ty);
			var originLocalY = invB * (minX / s - tx) + invD * (minY / s - ty);
			el._originU = originLocalX / aw;
			el._originV = originLocalY / ah;
		}

		// ── Baked atlas color (tint) ───────────────────────────────────────

		var col:Null<AnimateColor> = leaf.color;
		if (col != null && col.mode == "T") {
			el._filterType = 2.0;
			el._filterR    = col.r;
			el._filterG    = col.g;
			el._filterB    = col.b;
			el._filterA    = col.amount;
		} else if (col != null && col.mode == "AD") {
			el._filterType = 3.0;
			el._adRM = col.rm;
			el._adGM = col.gm;
			el._adBM = col.bm;
			el._adAM = col.am;
			el._adRO = col.ro;
			el._adGO = col.go;
			el._adBO = col.bo;
			el._adAO = col.ao;
		} else {
			el._filterType = 0.0;
			el._filterR    = 1.0;
			el._filterG    = 1.0;
			el._filterB    = 1.0;
			el._filterA    = 1.0;
		}

		// ── Baked atlas alpha ──────────────────────────────────────────────
		// Written into el.c so the blend pipeline multiplies it automatically.
		// Full white RGB preserves the sprite's original colors; only alpha varies.

		el.c.aF = leaf.alpha;
		el.c.luminanceF = leaf.alpha;

		// ── Baked brightness ───────────────────────────────────────────────

		el._filterBrightness = leaf.brightness;

		el.scale = 1.0;
		el.x = this.x;
		el.y = this.y;

		if (leafIndex == 0 && frameIndex == 0) firstFrameWidth = vws;
	}

	// ── Dispose ──────────────────────────────────────────────────────────────

	override function dispose() {
		for (el in leafPool) {
			el.w = 0;
			el.h = 0;
			if (buffer != null) buffer.updateElement(el);
		}
		leafPool        = [];
		activeLeafCount = 0;
		super.dispose();
	}

	// ── Filters ──────────────────────────────────────────────────────────────

	/**
	 * Apply a multiply tint to all leaves belonging to `symbolName`.
	 * Overwrites any baked atlas color for those leaves until clearTint() is called.
	 */
	function setTint(symbolName:String, r:Float, g:Float, b:Float, a:Float = 1.0) {
		var frame = currentResolvedFrames[frameIndex];
		for (i in 0...activeLeafCount) {
			if (frame[i].symbolName != symbolName) continue;
			leafPool[i]._filterType = 1.0;
			leafPool[i]._filterR    = r;
			leafPool[i]._filterG    = g;
			leafPool[i]._filterB    = b;
			leafPool[i]._filterA    = a;
		}
	}
}
