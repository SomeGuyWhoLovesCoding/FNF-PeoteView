package elements.actor;

import atlas.AnimateAtlas;
import atlas.AnimateAtlas.AnimateSprite;
import atlas.AnimateAtlas.ResolvedLeaf;
import atlas.AnimateAtlas.ResolvedFrame;
import elements.actor.*;

/**
	Actor backed by an Adobe Animate spritemap atlas.

	Maintains a dynamic pool of ActorElements — one per visible leaf sprite —
	so every part of a composite character carries its own accumulated
	world transform.  The fragment shader uses per-leaf matrix varyings to
	apply skew and non-uniform scale within each axis-aligned quad.

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

			if (Actor.buffers[tag] == null) Actor.buffers[tag] = new Buffer<ActorElement>(16, 16);
			buffer = Actor.buffers[tag];

			if (Actor.programs[tag] == null) {
				
				Actor.programs[tag] = new CustomProgram(buffer);
				program = Actor.programs[tag];

				var texName = name + "Char";
				var texPath = animateAtlas.imagePath;
				TextureSystem.createTexture(texName, texPath, false, true);
				TextureSystem.setTexture(program, texName, texName);

				// ── Matrix-based UV distortion shader ──────────────────────
				// Each leaf uploads its own a/b/c/d matrix components so the
				// fragment shader can invert the transform and sample the atlas
				// correctly even for skewed or non-uniformly scaled sprites.
				program.injectIntoFragmentShader('
					vec4 getColor(int texId, vec4 _m, float _rotated, float _originU, float _originV)
					{
						vec2 uv = vTexCoord;

						// mat2 in GLSL is column-major: mat2(col0, col1)
						// col0 = (a, b), col1 = (c, d)
						mat2 m = mat2(_m.x, _m.y, _m.z, _m.w);
						vec2 st = m * uv + vec2(_originU, _originV);

						st = mix(st, vec2(1.0 - st.y, st.x), _rotated);

						if (any(lessThan(st, vec2(0.0))) || any(greaterThan(st, vec2(1.0))))
							return vec4(0.0);

						return getTextureColor(texId, st);
					}
				');

				program.setColorFormula(
					'getColor(${texName}_ID, vec4(_ma, _mb, _mc, _md), _rotated, _originU, _originV)'
				);
			} else {
				program = Actor.programs[tag];
			}

			display.addProgram(program);
		}

		mirror = !data.flip;
		scale  = data.scale;
	}

	// ── Leaf pool management (used by AnimateActor) ──────────────────────────

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
			/*if (leafIndex == 0)
				trace(el._ma, el._mb, el._mc, el._md);*/

			var originLocalX = invA * (minX / s - tx) + invC * (minY / s - ty);
			var originLocalY = invB * (minX / s - tx) + invD * (minY / s - ty);
			el._originU = originLocalX / aw;
			el._originV = originLocalY / ah;
		}

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
}
